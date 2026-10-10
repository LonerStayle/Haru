import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solo_todo/src/features/ai/chatgpt/chatgpt_errors.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_account.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_credentials.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_store.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_token_endpoint.dart';

import 'siwc_test_support.dart';

void main() {
  const hour = 3600 * 1000;
  late int now;
  late MemorySiwcStore store;
  late List<http.Request> refreshes;
  late List<http.Request> revokes;
  late Future<http.Response> Function(http.Request) tokenReply;
  late Future<http.Response> Function(http.Request) revokeReply;
  late List<Duration> sleeps;
  late SiwcCredentials creds;

  http.Response tokens({
    String access = 'access-2',
    String? refresh = 'refresh-2',
    String? scope,
  }) => http.Response(
    jsonEncode({
      'access_token': access,
      'refresh_token': ?refresh,
      'expires_in': 3600,
      'scope': ?scope,
    }),
    200,
  );

  SiwcCredentials make() => SiwcCredentials(
    store: store,
    endpoint: SiwcTokenEndpoint(
      client: MockClient((r) {
        if (r.url.path.endsWith('/revoke')) {
          revokes.add(r);
          return revokeReply(r);
        }
        refreshes.add(r);
        return tokenReply(r);
      }),
      nowMs: () => now,
    ),
    nowMs: () => now,
    sleep: (d) async => sleeps.add(d),
  );

  setUp(() {
    now = 10 * hour;
    refreshes = [];
    revokes = [];
    sleeps = [];
    tokenReply = (_) async => tokens();
    revokeReply = (_) async => http.Response('', 200);
    store = MemorySiwcStore(
      SiwcStoreData(
        hostId: 'urn:uuid:h',
        account: signedInRecord(expiresAtMs: now + hour),
      ),
    );
    creds = make();
  });

  Matcher authRequiredWith(ChatGptAuthReason reason) => throwsA(
    isA<ChatGptException>()
        .having((e) => e.kind, 'kind', ChatGptErrorKind.authRequired)
        .having((e) => e.authReason, 'reason', reason),
  );

  test('planUsage=false → 추론 금지 (planScopeMissing)', () async {
    store.data = SiwcStoreData(account: signedInRecord(planUsage: false));
    await expectLater(
      creds.current(),
      authRequiredWith(ChatGptAuthReason.planScopeMissing),
    );
  });

  test('로그아웃·없음 → signedOut', () async {
    store.data = const SiwcStoreData();
    await expectLater(
      creds.current(),
      authRequiredWith(ChatGptAuthReason.signedOut),
    );
  });

  test('유효한 토큰은 네트워크 없이', () async {
    final c = await creds.current();
    expect(c.bearer, 'access-1');
    expect(refreshes, isEmpty);
  });

  test('만료 5분 전 선갱신 → refresh 회전 저장', () async {
    now = 10 * hour + hour - 4 * 60000; // 만료 4분 전
    final c = await creds.current();
    expect(c.bearer, 'access-2');
    expect(refreshes.single.bodyFields['refresh_token'], 'refresh-1');
    final saved = store.data.account!;
    expect(saved.refreshToken, 'refresh-2');
    expect(saved.accessToken, 'access-2');
    expect(saved.idToken, 'id-token-1', reason: '응답에 없으면 이전 값 유지');
    expect(saved.expiresAtMs, now + hour);
  });

  test('동시 10호출 → 갱신 요청 1회 (single-flight)', () async {
    now = 10 * hour + hour + 1; // 만료됨
    final gate = Completer<void>();
    tokenReply = (_) async {
      await gate.future;
      return tokens();
    };
    final calls = List.generate(10, (_) => creds.current());
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    final results = await Future.wait(calls);
    expect(refreshes, hasLength(1));
    expect(results.map((c) => c.bearer).toSet(), {'access-2'});
  });

  for (final code in [
    'invalid_grant',
    'invalid_refresh_token',
    'token_expired',
    'refresh_token_expired',
    'refresh_token_invalidated',
    'refresh_token_reused',
  ]) {
    test(
      'terminal $code → access·refresh 삭제, idToken 보존, NEEDS_REAUTH',
      () async {
        now = 10 * hour + hour + 1;
        tokenReply = (_) async =>
            http.Response(jsonEncode({'error': code}), 400);
        await expectLater(
          creds.current(),
          authRequiredWith(ChatGptAuthReason.needsReauth),
        );
        final rec = store.data.account!;
        expect(rec.state, SiwcAccountState.needsReauth);
        expect(rec.needsReauthReason, code);
        expect(rec.accessToken, isNull);
        expect(rec.refreshToken, isNull);
        expect(rec.idToken, 'id-token-1');
      },
    );
  }

  test('invalid_client → NEEDS_REAUTH(invalid_client), 토큰 유지', () async {
    now = 10 * hour + hour + 1;
    tokenReply = (_) async =>
        http.Response(jsonEncode({'error': 'invalid_client'}), 401);
    await expectLater(
      creds.current(),
      authRequiredWith(ChatGptAuthReason.needsReauth),
    );
    final rec = store.data.account!;
    expect(rec.needsReauthReason, SiwcReauthReason.invalidClient);
    expect(rec.refreshToken, 'refresh-1');
  });

  test('선갱신 네트워크 실패인데 access 유효 → 기존 access + 30초 백오프', () async {
    now = 10 * hour + hour - 4 * 60000;
    tokenReply = (_) async => throw http.ClientException('offline');
    expect((await creds.current()).bearer, 'access-1');
    expect(refreshes, hasLength(1));
    now += 10000;
    expect((await creds.current()).bearer, 'access-1');
    expect(refreshes, hasLength(1), reason: '백오프 중엔 다시 시도하지 않는다');
    now += 21000;
    tokenReply = (_) async => tokens();
    expect((await creds.current()).bearer, 'access-2');
    expect(refreshes, hasLength(2));
  });

  test('만료됐고 갱신 5xx → 재시도 대상 server 오류', () async {
    now = 10 * hour + hour + 1;
    tokenReply = (_) async => http.Response('', 503);
    await expectLater(
      creds.current(),
      throwsA(
        isA<ChatGptException>()
            .having((e) => e.kind, 'kind', ChatGptErrorKind.server)
            .having((e) => e.retryable, 'retryable', true),
      ),
    );
  });

  test('갱신 중 그새 재로그인 → 옛 응답 저장 안 함', () async {
    now = 10 * hour + hour + 1;
    final gate = Completer<void>();
    tokenReply = (_) async {
      await gate.future;
      return tokens(access: 'stale', refresh: 'stale-r');
    };
    final pending = creds.current();
    await Future<void>.delayed(Duration.zero);
    await creds.setAccount(
      signedInRecord(
        access: 'fresh',
        refresh: 'fresh-r',
        expiresAtMs: now + hour,
      ),
    );
    gate.complete();
    expect((await pending).bearer, 'fresh');
    expect(store.data.account!.refreshToken, 'fresh-r');
  });

  test('디스크 쓰기 실패 → 메모리 유지', () async {
    now = 10 * hour + hour + 1;
    store.failWrites = true;
    expect((await creds.current()).bearer, 'access-2');
    expect(creds.account!.refreshToken, 'refresh-2');
    expect(store.data.account!.refreshToken, 'refresh-1');
    expect((await creds.current()).bearer, 'access-2');
    expect(refreshes, hasLength(1));
  });

  test('refresh 없음 + 만료 → NEEDS_REAUTH(missing_refresh_token)', () async {
    store.data = SiwcStoreData(
      account: signedInRecord(refresh: null, expiresAtMs: now - 1),
    );
    await expectLater(
      creds.current(),
      authRequiredWith(ChatGptAuthReason.needsReauth),
    );
    expect(
      store.data.account!.needsReauthReason,
      SiwcReauthReason.missingRefreshToken,
    );
  });

  test('401 뒤 강제 갱신 — 이미 갱신됐으면 새 값 그대로', () async {
    final first = await creds.current();
    final c = await creds.refreshAfterUnauthorized(first);
    expect(c.bearer, 'access-2');
    expect(refreshes, hasLength(1));
    final again = await creds.refreshAfterUnauthorized(first);
    expect(again.bearer, 'access-2');
    expect(refreshes, hasLength(1));
  });

  test('갱신 뒤 같은 code 로 연속 2회 거절 → NEEDS_REAUTH (토큰 유지)', () async {
    await creds.onRejectedAfterRefresh('x');
    expect(store.data.account!.state, SiwcAccountState.signedIn);
    await creds.onRejectedAfterRefresh('x');
    final rec = store.data.account!;
    expect(rec.state, SiwcAccountState.needsReauth);
    expect(rec.needsReauthReason, SiwcReauthReason.unauthorizedAfterRefresh);
    expect(rec.accessToken, 'access-1');
  });

  group('로그아웃', () {
    test('revoke 5xx → 1·2·4초 백오프 3회, 확인 못해도 토큰 삭제, 등록은 유지', () async {
      revokeReply = (_) async => http.Response('', 500);
      final confirmed = await creds.signOut();
      expect(confirmed, isFalse);
      expect(revokes, hasLength(4));
      expect(sleeps, const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
      ]);
      expect(revokes.first.bodyFields['token'], 'refresh-1');
      final rec = store.data.account!;
      expect(rec.state, SiwcAccountState.signedOut);
      expect(rec.accessToken, isNull);
      expect(rec.refreshToken, isNull);
      expect(rec.idToken, isNull);
      expect(rec.clientId, testClientId);
      expect(rec.email, 'me@example.com');
      expect(store.data.hostId, 'urn:uuid:h');
    });

    test('정상 revoke → 확인됨', () async {
      expect(await creds.signOut(), isTrue);
      expect(revokes, hasLength(1));
      expect(store.data.account!.state, SiwcAccountState.signedOut);
    });

    test('SIGNING_OUT 동안 요청 차단, revoke 중 재로그인 → 새 토큰 보존', () async {
      final gate = Completer<void>();
      revokeReply = (_) async {
        await gate.future;
        return http.Response('', 200);
      };
      final out = creds.signOut();
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        creds.current(),
        authRequiredWith(ChatGptAuthReason.signingOut),
      );
      await creds.setAccount(
        signedInRecord(
          access: 'new',
          refresh: 'new-r',
          expiresAtMs: now + hour,
        ),
      );
      gate.complete();
      await out;
      expect(store.data.account!.refreshToken, 'new-r');
      expect(store.data.account!.state, SiwcAccountState.signedIn);
    });
  });
}
