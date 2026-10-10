import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/features/ai/chatgpt/pkce.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_account.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_authorize_url.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_login.dart';

import 'siwc_test_support.dart';

void main() {
  group('PKCE', () {
    test('RFC 7636 부록 B 벡터', () {
      expect(
        challengeOf('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('state·nonce 43자, verifier 86자, base64url 무패딩', () {
      for (var i = 0; i < 20; i++) {
        final s = generateLoginSecrets(Random(i));
        expect(s.state.length, 43);
        expect(s.nonce.length, 43);
        expect(s.verifier.length, 86);
        for (final v in [s.state, s.nonce, s.verifier, s.challenge]) {
          expect(v, isNot(matches(r'[=+/]')));
        }
      }
      expect(generateLoginSecrets().toString(), 'LoginSecrets(***)');
    });

    test('상수 시간 비교', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
    });
  });

  group('RFC 3986', () {
    test('공백 %20, 예약 문자 인코딩, 비예약 그대로, 한글 대문자 hex', () {
      expect(encodeRfc3986(' '), '%20');
      expect(encodeRfc3986(':'), '%3A');
      expect(encodeRfc3986('/'), '%2F');
      expect(encodeRfc3986('~-._'), '~-._');
      expect(encodeRfc3986('하'), '%ED%95%98');
      expect(encodeRfc3986('a+b'), 'a%2Bb');
    });
  });

  group('authorize 파라미터', () {
    List<String> keys(SiwcLoginMode mode, {String? id, String? login}) =>
        siwcAuthorizeParams(
          mode: mode,
          hostId: 'urn:uuid:1',
          redirectUri: 'http://127.0.0.1:1455/auth/callback',
          state: 's',
          nonce: 'n',
          codeChallenge: 'c',
          idTokenHint: id,
          loginHint: login,
        ).map((p) => p.$1).toList();

    const base = [
      'ext_agent_host_id',
      'response_type',
      'redirect_uri',
      'scope',
      'resource',
      'state',
      'nonce',
      'code_challenge_method',
      'code_challenge',
    ];

    test('NewAccount 만 agent_name_hint, hint 는 넣지 않는다', () {
      expect(keys(const SiwcNewAccount(), id: 'x', login: 'y'), [
        'client_id',
        'agent_name_hint',
        ...base,
      ]);
      final params = siwcAuthorizeParams(
        mode: const SiwcNewAccount(),
        hostId: 'h',
        redirectUri: 'r',
        state: 's',
        nonce: 'n',
        codeChallenge: 'c',
      );
      expect(params.first, ('client_id', 'dynamic_agent_client'));
      expect(params[1], ('agent_name_hint', 'Haru'));
    });

    test('Reauth hint 2종은 값 있을 때만', () {
      expect(keys(const SiwcReauth('oaiapp_1')), ['client_id', ...base]);
      expect(keys(const SiwcReauth('oaiapp_1'), id: 'tok', login: 'a@b.c'), [
        'client_id',
        ...base,
        'id_token_hint',
        'login_hint',
      ]);
      expect(keys(const SiwcReauth('oaiapp_1'), login: '  '), [
        'client_id',
        ...base,
      ]);
    });

    test('Reconsent 는 prompt=consent, PendingRetry 는 hint 없음', () {
      expect(keys(const SiwcReconsent('oaiapp_1'), login: 'a'), [
        'client_id',
        ...base,
        'login_hint',
        'prompt',
      ]);
      expect(keys(const SiwcPendingRetry('oaiapp_1'), id: 'x', login: 'y'), [
        'client_id',
        ...base,
      ]);
    });

    test('URL 은 + 없이 %20, redirect 인코딩, host id 비면 예외', () {
      final url = buildSiwcAuthorizeUrl(
        mode: const SiwcNewAccount(),
        hostId: 'urn:uuid:abc',
        redirectUri: 'http://127.0.0.1:1455/auth/callback',
        state: 'st',
        nonce: 'no',
        codeChallenge: 'ch',
      );
      expect(
        url,
        startsWith('https://auth.openai.com/api/accounts/authorize?'),
      );
      expect(url, isNot(contains('+')));
      expect(
        url,
        contains(
          'scope=openid%20profile%20email%20offline_access%20resource.invoke'
          '%20chatgpt.tokens.use.direct',
        ),
      );
      expect(
        url,
        contains(
          'redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback',
        ),
      );
      expect(url, contains('resource=https%3A%2F%2Fapi.openai.com%2Fv1'));
      expect(
        () => buildSiwcAuthorizeUrl(
          mode: const SiwcNewAccount(),
          hostId: ' ',
          redirectUri: 'r',
          state: 's',
          nonce: 'n',
          codeChallenge: 'c',
        ),
        throwsArgumentError,
      );
    });
  });

  group('시작 모드', () {
    test('기록 없음 → NewAccount, PENDING → PendingRetry', () {
      expect(siwcStartMode(null), isA<SiwcNewAccount>());
      final pending = SiwcAccountRecord(
        clientId: 'oaiapp_p',
        state: SiwcAccountState.pendingRegistration,
      );
      final mode = siwcStartMode(pending);
      expect(mode, isA<SiwcPendingRetry>());
      expect(mode.requestClientId, 'oaiapp_p');
    });

    test(
      '저장 계정 → Reauth, planUsage=false → Reconsent, invalid_client → NewAccount',
      () {
        expect(siwcStartMode(signedInRecord()), isA<SiwcReauth>());
        expect(
          siwcStartMode(signedInRecord(planUsage: false)),
          isA<SiwcReconsent>(),
        );
        expect(siwcStartMode(signedInRecord().signedOut(0)), isA<SiwcReauth>());
        final invalid = signedInRecord().copyWith(
          state: SiwcAccountState.needsReauth,
          needsReauthReason: SiwcReauthReason.invalidClient,
        );
        expect(siwcStartMode(invalid), isA<SiwcNewAccount>());
        final terminal = signedInRecord().needsReauthTerminal(
          'invalid_grant',
          0,
        );
        expect(siwcStartMode(terminal), isA<SiwcReauth>());
        expect(terminal.idToken, 'id-token-1');
        expect(terminal.accessToken, isNull);
        expect(terminal.refreshToken, isNull);
      },
    );
  });
}
