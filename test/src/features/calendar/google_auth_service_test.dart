import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/features/calendar/google_auth_service.dart';

void main() {
  test('OAuth 환경변수 미설정 (test 환경) → auth null + 비활성화', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(calendarAuthProvider), isNull);
    expect(container.read(googleCalendarAvailableProvider), isFalse);
  });

  test('_scopes 가 이벤트 CRUD scope + 캘린더 목록 조회 scope 를 모두 포함한다', () {
    expect(
      calendarScopes,
      containsAll(<String>[calendarEventsScope, calendarListScope]),
    );
    expect(calendarScopes.length, 2);
  });

  group('storedScopesCoverRequired — 저장된 refresh token 재사용 가능 여부 판정', () {
    test('저장된 scopes 가 현재 필요한 scope 를 전부 포함하면 true', () {
      expect(storedScopesCoverRequired(calendarScopes, calendarScopes), isTrue);
      // 저장된 쪽이 더 넓어도(과거에 더 많은 scope 로 동의) 재사용 가능.
      expect(
        storedScopesCoverRequired([
          calendarEventsScope,
          calendarListScope,
          'https://www.googleapis.com/auth/calendar',
        ], calendarScopes),
        isTrue,
      );
    });

    test('부분집합(옛 scope 만 있음)이면 false — refresh 시도 없이 재동의로', () {
      expect(
        storedScopesCoverRequired([calendarEventsScope], calendarScopes),
        isFalse,
      );
    });

    test('scopes 가 null(구버전 토큰 파일, scopes 키 없음)이면 false', () {
      expect(storedScopesCoverRequired(null, calendarScopes), isFalse);
    });
  });

  group('parseStoredToken — 토큰 파일 JSON 파싱', () {
    test('refresh_token + scopes 모두 있는 정상 JSON', () {
      final result = parseStoredToken(
        jsonEncode({'refresh_token': 'rt-1', 'scopes': calendarScopes}),
      );
      expect(result, isNotNull);
      expect(result!.refreshToken, 'rt-1');
      expect(result.scopes, calendarScopes);
    });

    test('scopes 키가 없는 구버전 포맷 → scopes 는 null (refreshToken 은 보존)', () {
      final result = parseStoredToken(jsonEncode({'refresh_token': 'rt-1'}));
      expect(result, isNotNull);
      expect(result!.refreshToken, 'rt-1');
      expect(result.scopes, isNull);
    });

    test('깨진 JSON 문자열은 예외 없이 null', () {
      expect(parseStoredToken('{이건 json 이 아님'), isNull);
    });

    test('refresh_token 이 없는 JSON 은 null', () {
      expect(parseStoredToken(jsonEncode({'scopes': calendarScopes})), isNull);
    });

    test('refresh_token 이 빈 문자열이면 null', () {
      expect(parseStoredToken(jsonEncode({'refresh_token': ''})), isNull);
    });
  });
}
