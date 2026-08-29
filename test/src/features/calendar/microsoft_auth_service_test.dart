import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/features/calendar/calendar_auth.dart';
import 'package:solo_todo/src/features/calendar/microsoft_auth_service.dart';

/// Microsoft OAuth2 PKCE 플로우의 **순수 부분**을 덮는다.
///
/// 브라우저 동의와 loopback 서버는 사람이 개입해야 하는 IO 라 테스트하지 않는다.
/// 대신 "값 하나만 틀려도 조용히 실패하는" 조립 규칙(동의 URL · PKCE 챌린지 ·
/// 토큰 응답 파싱 · state 검증 · 저장 파일 파싱)을 함수로 떼어 전부 검증한다.
void main() {
  group('PKCE', () {
    test('code_verifier 는 RFC 7636 의 unreserved 문자만 쓴다', () {
      final v = createCodeVerifier(random: Random(1));
      expect(v.length, 64);
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(v), isTrue);
    });

    test('길이를 지정할 수 있다 (43~128 범위 안에서)', () {
      expect(createCodeVerifier(length: 43, random: Random(2)).length, 43);
    });

    test('code_challenge 는 패딩 없는 base64url(SHA-256)', () {
      const verifier = 'abcdefghijklmnopqrstuvwxyz0123456789-._~ABCDEFGHIJK';
      final challenge = codeChallengeS256(verifier);
      expect(challenge, isNot(contains('=')));
      expect(challenge, isNot(contains('+')));
      expect(challenge, isNot(contains('/')));
      expect(
        challenge,
        base64UrlEncode(
          sha256.convert(utf8.encode(verifier)).bytes,
        ).replaceAll('=', ''),
      );
    });

    test('서로 다른 verifier 는 서로 다른 challenge 를 낸다', () {
      expect(codeChallengeS256('a'), isNot(codeChallengeS256('b')));
    });
  });

  group('동의 URL', () {
    final url = buildAuthorizeUrl(
      tenant: 'organizations',
      clientId: 'client-guid',
      redirectUri: 'http://localhost:52345',
      scopes: microsoftCalendarScopes,
      state: 'state-1',
      codeChallenge: 'challenge-1',
    );

    test('테넌트가 경로에 들어간다', () {
      expect(
        url.toString(),
        startsWith(
          'https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize',
        ),
      );
    });

    test('PKCE 파라미터가 S256 로 실린다', () {
      expect(url.queryParameters['code_challenge'], 'challenge-1');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['response_mode'], 'query');
    });

    test('scope 는 공백 구분이고 최소 권한만 담는다', () {
      expect(
        url.queryParameters['scope'],
        'offline_access User.Read Calendars.ReadWrite',
      );
    });

    test('redirect_uri 는 loopback — 커스텀 스킴을 쓰지 않는다', () {
      expect(url.queryParameters['redirect_uri'], 'http://localhost:52345');
    });

    test('client secret 은 어디에도 없다 (공개 클라이언트)', () {
      expect(url.toString(), isNot(contains('client_secret')));
    });
  });

  group('토큰 응답 파싱', () {
    final now = DateTime.utc(2026, 8, 20, 10);

    test('access token 과 만료 시각을 뽑는다', () {
      final t = parseTokenResponse(
        jsonEncode({
          'access_token': 'at-1',
          'expires_in': 3600,
          'refresh_token': 'rt-1',
          'scope': 'offline_access User.Read Calendars.ReadWrite',
        }),
        now: now,
      )!;
      expect(t.accessToken, 'at-1');
      expect(t.refreshToken, 'rt-1');
      expect(t.expiresAt, now.add(const Duration(hours: 1)));
      expect(t.scopes, ['offline_access', 'User.Read', 'Calendars.ReadWrite']);
    });

    test('만료 여유 — 1분 안에 만료될 토큰은 신선하지 않다', () {
      final t = parseTokenResponse(
        jsonEncode({'access_token': 'at', 'expires_in': 30}),
        now: now,
      )!;
      expect(t.isFresh(now), isFalse);

      final long = parseTokenResponse(
        jsonEncode({'access_token': 'at', 'expires_in': 3600}),
        now: now,
      )!;
      expect(long.isFresh(now), isTrue);
    });

    test('refresh 응답에 refresh_token 이 없어도 파싱된다', () {
      final t = parseTokenResponse(
        jsonEncode({'access_token': 'at', 'expires_in': 3600}),
        now: now,
      )!;
      expect(t.refreshToken, isNull);
    });

    test('access_token 이 없거나 깨진 본문은 null — 재동의로 보낸다', () {
      expect(parseTokenResponse('{}'), isNull);
      expect(parseTokenResponse('not json'), isNull);
      expect(parseTokenResponse('[]'), isNull);
      expect(
        parseTokenResponse(jsonEncode({'error': 'invalid_grant'})),
        isNull,
      );
    });
  });

  group('리다이렉트 파싱', () {
    test('state 가 맞으면 code 를 준다', () {
      expect(extractAuthCode(Uri.parse('/?code=abc&state=s1'), 's1'), 'abc');
    });

    test('state 가 다르면 무시한다 — 다른 창/위조 응답', () {
      expect(
        extractAuthCode(Uri.parse('/?code=abc&state=other'), 's1'),
        isNull,
      );
    });

    test('동의 거부는 code 가 없다', () {
      expect(
        extractAuthCode(Uri.parse('/?error=access_denied&state=s1'), 's1'),
        isNull,
      );
    });
  });

  group('저장 토큰 파싱', () {
    test('refresh_token 과 scopes 를 읽는다', () {
      final parsed = parseStoredMicrosoftToken(
        jsonEncode({
          'refresh_token': 'rt',
          'scopes': ['offline_access', 'Calendars.ReadWrite'],
        }),
      )!;
      expect(parsed.refreshToken, 'rt');
      expect(parsed.scopes, ['offline_access', 'Calendars.ReadWrite']);
    });

    test('깨졌거나 토큰이 없으면 null — 예외를 던지지 않는다', () {
      expect(parseStoredMicrosoftToken('{'), isNull);
      expect(parseStoredMicrosoftToken('{}'), isNull);
      expect(
        parseStoredMicrosoftToken(jsonEncode({'refresh_token': ''})),
        isNull,
      );
    });

    test('scopes 키가 없는 구버전 파일은 scopes null', () {
      final parsed = parseStoredMicrosoftToken(
        jsonEncode({'refresh_token': 'rt'}),
      )!;
      expect(parsed.scopes, isNull);
    });
  });

  group('scope 대조 — refresh 는 부족한 권한을 알려주지 않는다', () {
    test('필요한 scope 를 다 덮어야 재사용한다', () {
      expect(
        scopesCoverRequired(microsoftCalendarScopes, microsoftCalendarScopes),
        isTrue,
      );
    });

    test('하나라도 빠지면 재동의로 보낸다', () {
      expect(
        scopesCoverRequired(const [
          'offline_access',
          'User.Read',
        ], microsoftCalendarScopes),
        isFalse,
      );
    });

    test('scopes 를 모르는 옛 토큰은 무조건 재동의', () {
      expect(scopesCoverRequired(null, microsoftCalendarScopes), isFalse);
    });
  });
}
