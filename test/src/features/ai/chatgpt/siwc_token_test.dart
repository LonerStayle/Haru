import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_account.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_id_token.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_store.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_token_endpoint.dart';

import 'siwc_test_support.dart';

void main() {
  group('토큰 엔드포인트', () {
    late List<http.Request> sent;
    late http.Response Function(http.Request) reply;
    late SiwcTokenEndpoint endpoint;

    setUp(() {
      sent = [];
      reply = (_) => http.Response(
        jsonEncode({'access_token': 'a', 'expires_in': 3600}),
        200,
      );
      endpoint = SiwcTokenEndpoint(
        client: MockClient((r) async {
          sent.add(r);
          return reply(r);
        }),
        nowMs: () => 1000000,
      );
    });

    test('교환 폼 필드·순서', () async {
      await endpoint.exchangeCode(
        clientId: 'oaiapp_1',
        code: 'the code',
        codeVerifier: 'ver',
        redirectUri: 'http://127.0.0.1:1455/auth/callback',
      );
      final r = sent.single;
      expect(
        r.url.toString(),
        'https://auth.openai.com/api/accounts/oauth/token',
      );
      expect(
        r.headers['content-type'],
        contains('application/x-www-form-urlencoded'),
      );
      expect(r.headers['Accept'], 'application/json');
      expect(r.bodyFields.keys.toList(), [
        'grant_type',
        'client_id',
        'code',
        'code_verifier',
        'redirect_uri',
        'resource',
      ]);
      expect(r.bodyFields['grant_type'], 'authorization_code');
      expect(r.bodyFields['code'], 'the code');
      expect(r.bodyFields['resource'], 'https://api.openai.com/v1');
      expect(
        r.bodyFields['redirect_uri'],
        'http://127.0.0.1:1455/auth/callback',
      );
    });

    test('갱신은 scope 없이 resource 포함', () async {
      await endpoint.refresh(clientId: 'oaiapp_1', refreshToken: 'rt');
      final f = sent.single.bodyFields;
      expect(f.keys.toList(), [
        'grant_type',
        'client_id',
        'refresh_token',
        'resource',
      ]);
      expect(f.containsKey('scope'), isFalse);
    });

    test('revoke 폼 + 결과 분류', () async {
      expect(
        await endpoint.revoke(clientId: 'c', refreshToken: 'rt'),
        RevokeResult.ok,
      );
      expect(
        sent.single.url.toString(),
        'https://auth.openai.com/api/accounts/oauth/revoke',
      );
      expect(sent.single.bodyFields, {
        'token': 'rt',
        'token_type_hint': 'refresh_token',
        'client_id': 'c',
      });
      reply = (_) => http.Response('', 503);
      expect(
        await endpoint.revoke(clientId: 'c', refreshToken: 'rt'),
        RevokeResult.retryable,
      );
      reply = (_) => http.Response('', 400);
      expect(
        await endpoint.revoke(clientId: 'c', refreshToken: 'rt'),
        RevokeResult.rejected,
      );
      reply = (_) => throw http.ClientException('offline');
      expect(
        await endpoint.revoke(clientId: 'c', refreshToken: 'rt'),
        RevokeResult.retryable,
      );
    });

    test('응답 파싱 — expires_in 문자열/실수, 빈 refresh → null', () {
      final a = parseTokenResponse(
        jsonEncode({
          'access_token': 'a',
          'expires_in': '120',
          'refresh_token': '',
          'scope': 'openid  chatgpt.tokens.use.direct',
        }),
        receivedAtMs: 0,
      )!;
      expect(a.expiresInS, 120);
      expect(a.expiresAtMs, 120000);
      expect(a.refreshToken, isNull);
      expect(a.scopes, ['openid', 'chatgpt.tokens.use.direct']);
      final b = parseTokenResponse(
        jsonEncode({'access_token': 'a', 'expires_in': 99.7}),
        receivedAtMs: 0,
      )!;
      expect(b.expiresInS, 99);
      final c = parseTokenResponse(
        jsonEncode({'access_token': 'a'}),
        receivedAtMs: 0,
      )!;
      expect(c.expiresAtMs, 3600 * 1000);
      expect(
        parseTokenResponse('{"access_token":""}', receivedAtMs: 0),
        isNull,
      );
      expect(parseTokenResponse('nope', receivedAtMs: 0), isNull);
    });

    test('오류 code 세 모양 + 정규식 거름', () {
      expect(tokenErrorCode({'error': 'invalid_grant'}), 'invalid_grant');
      expect(
        tokenErrorCode({
          'error': {'code': 'refresh_token_reused'},
        }),
        'refresh_token_reused',
      );
      expect(
        tokenErrorCode({
          'error': {'type': 'invalid_client'},
        }),
        'invalid_client',
      );
      expect(tokenErrorCode({'code': 'token_expired'}), 'token_expired');
      expect(tokenErrorCode({'error': 'has space'}), isNull);
      expect(tokenErrorCode('x'), isNull);
    });

    test('실패 분류 — 5xx server, 4xx client(terminal), 네트워크, 200 깨짐', () async {
      reply = (_) => http.Response('{"error":"x"}', 502);
      var r = await endpoint.refresh(clientId: 'c', refreshToken: 'rt');
      expect((r as TokenFailure).kind, TokenFailureKind.server);

      reply = (_) => http.Response('{"error":"refresh_token_reused"}', 400);
      r = await endpoint.refresh(clientId: 'c', refreshToken: 'rt');
      expect((r as TokenFailure).kind, TokenFailureKind.client);
      expect(r.isTerminal, isTrue);

      reply = (_) => http.Response('{"error":"invalid_client"}', 401);
      r = await endpoint.refresh(clientId: 'c', refreshToken: 'rt');
      expect((r as TokenFailure).isInvalidClient, isTrue);
      expect(r.isTerminal, isFalse);

      reply = (_) => throw const SocketException('down');
      r = await endpoint.refresh(clientId: 'c', refreshToken: 'rt');
      expect((r as TokenFailure).kind, TokenFailureKind.network);

      reply = (_) => http.Response('<html>', 200);
      r = await endpoint.refresh(clientId: 'c', refreshToken: 'rt');
      expect((r as TokenFailure).kind, TokenFailureKind.malformed);
    });
  });

  group('TokenTiming', () {
    test('Date 헤더 보정', () {
      // 서버 시계가 10초 빠름: earliest = 서버 기준 +54분
      const received = 1000000;
      const serverNow = received + 10000;
      final earliest = TokenTiming.earliestRefreshAtMs(
        receivedAtMs: received,
        expiresAtMs: received + 3600000,
        earliestRefreshAtS: (serverNow + 54 * 60000) ~/ 1000,
        serverDateMs: serverNow,
      );
      expect(earliest, received + 54 * 60000);
    });

    test('iat 보정 (Date 없음)', () {
      const received = 2000000;
      final access = fakeJwt({'iat': (received - 5000) ~/ 1000});
      final earliest = TokenTiming.earliestRefreshAtMs(
        receivedAtMs: received,
        expiresAtMs: received + 3600000,
        earliestRefreshAtS: (received - 5000 + 60000) ~/ 1000,
        accessToken: access,
      );
      expect(earliest, received + 60000);
    });

    test('earliest > expires → expires − 5분, 없으면 0', () {
      expect(
        TokenTiming.earliestRefreshAtMs(
          receivedAtMs: 0,
          expiresAtMs: 3600000,
          earliestRefreshAtS: 999999,
        ),
        3600000 - 300000,
      );
      expect(
        TokenTiming.earliestRefreshAtMs(
          receivedAtMs: 0,
          expiresAtMs: 1,
          earliestRefreshAtS: 0,
        ),
        0,
      );
    });

    test('needsRefresh 경계 — 만료 5분 전', () {
      bool needs(int now) => TokenTiming.needsRefresh(
        accessToken: 'a',
        expiresAtMs: 3600000,
        earliestRefreshAtMs: 0,
        nowMs: now,
      );
      expect(needs(3600000 - 300001), isFalse);
      expect(needs(3600000 - 300000), isTrue);
      expect(
        TokenTiming.needsRefresh(
          accessToken: null,
          expiresAtMs: 9e15.toInt(),
          earliestRefreshAtMs: 0,
          nowMs: 0,
        ),
        isTrue,
      );
    });
  });

  group('id_token claims', () {
    const now = 1700000000000;
    Map<String, dynamic> good() => {
      'iss': 'https://auth.openai.com',
      'aud': testClientId,
      'exp': now ~/ 1000 + 600,
      'nonce': 'n1',
      'sub': testSubject,
      'email': 'me@example.com',
      'https://api.openai.com/auth': {'chatgpt_plan_type': 'plus'},
    };
    IdTokenClaims verify(
      Map<String, dynamic> c, {
      String alg = 'RS256',
      int at = now,
    }) => verifySiwcIdTokenClaims(
      fakeJwt(c, alg: alg),
      clientId: testClientId,
      nonce: 'n1',
      nowMs: at,
    );
    Matcher fails(String reason) => throwsA(
      isA<IdTokenException>().having((e) => e.reason, 'reason', reason),
    );

    test('정상', () {
      final c = verify(good());
      expect(c.subject, testSubject);
      expect(c.email, 'me@example.com');
      expect(c.planType, 'plus');
    });

    test('각 거부 사유', () {
      expect(() => verify(good(), alg: 'none'), fails('alg'));
      expect(() => verify(good(), alg: 'HS256'), fails('alg'));
      expect(() => verify({...good(), 'iss': 'https://evil'}), fails('iss'));
      expect(() => verify({...good(), 'aud': 'other'}), fails('aud'));
      expect(
        () => verify({
          ...good(),
          'aud': ['other'],
        }),
        fails('aud'),
      );
      expect(() => verify({...good(), 'azp': 'other'}), fails('azp'));
      expect(
        () => verify({
          ...good(),
          'aud': [testClientId, 'x'],
        }),
        fails('azp'),
      );
      expect(
        verify({
          ...good(),
          'aud': [testClientId, 'x'],
          'azp': testClientId,
        }).subject,
        testSubject,
      );
      expect(() => verify({...good()}..remove('exp')), fails('exp'));
      expect(() => verify({...good(), 'nonce': 'n2'}), fails('nonce'));
      expect(() => verify({...good()}..remove('nonce')), fails('nonce'));
      expect(() => verify({...good(), 'sub': ''}), fails('sub'));
      expect(
        () => verifySiwcIdTokenClaims(
          'a.b',
          clientId: testClientId,
          nonce: 'n1',
          nowMs: now,
        ),
        fails('malformed'),
      );
    });

    test('exp 60초 관용 경계', () {
      final exp = now ~/ 1000;
      final c = {...good(), 'exp': exp};
      expect(verify(c, at: (exp + 60) * 1000).subject, testSubject);
      expect(() => verify(c, at: (exp + 61) * 1000), fails('exp'));
    });
  });

  group('파일 저장', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('siwc_store_test');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('왕복 + tmp 파일 남지 않음', () async {
      final store = SiwcFileStore(directory: () async => dir);
      expect((await store.read()).account, isNull);
      await store.write(
        SiwcStoreData(hostId: 'urn:uuid:1', account: signedInRecord()),
      );
      final back = await store.read();
      expect(back.hostId, 'urn:uuid:1');
      expect(back.account!.accessToken, 'access-1');
      expect(back.account!.state, SiwcAccountState.signedIn);
      expect(
        File('${dir.path}/ai_chatgpt_accounts.json.tmp').existsSync(),
        isFalse,
      );
    });

    test('쓰기 중 실패 → 기존 파일 보존', () async {
      final store = SiwcFileStore(directory: () async => dir);
      await store.write(
        SiwcStoreData(hostId: 'urn:uuid:1', account: signedInRecord()),
      );
      // tmp 자리에 디렉터리를 두어 임시 파일 쓰기를 실패시킨다.
      Directory('${dir.path}/ai_chatgpt_accounts.json.tmp').createSync();
      await expectLater(
        store.write(const SiwcStoreData(hostId: 'urn:uuid:2')),
        throwsA(isA<FileSystemException>()),
      );
      final back = await store.read();
      expect(back.hostId, 'urn:uuid:1');
      expect(back.account!.refreshToken, 'refresh-1');
    });

    test('깨진 파일·다른 schema → 빈 값', () async {
      final f = File('${dir.path}/ai_chatgpt_accounts.json');
      f.writeAsStringSync('{broken');
      final store = SiwcFileStore(directory: () async => dir);
      expect((await store.read()).hostId, isNull);
      f.writeAsStringSync('{"schema":99,"hostId":"x"}');
      expect((await store.read()).hostId, isNull);
    });

    test('기록 toString 에 토큰이 없다', () {
      final s = signedInRecord().toString();
      expect(s, isNot(contains('access-1')));
      expect(s, isNot(contains('refresh-1')));
    });
  });
}
