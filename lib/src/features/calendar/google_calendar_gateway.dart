import 'dart:async';
import 'dart:io';

import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:http/http.dart' as http;

import 'calendar_gateway.dart';
import 'google_auth_service.dart';

/// 실제 Google Calendar API 를 호출하는 [CalendarGateway].
///
/// 인증은 [CalendarAuth] 가 플랫폼별로 책임진다 (macOS = 데스크톱 OAuth,
/// Android = google_sign_in). 이 클래스는 인증된 client 를 받아 API 를 부르고
/// **오류를 [CalendarGatewayException] 으로 번역**하는 일만 한다.
class GoogleCalendarGateway implements CalendarGateway {
  GoogleCalendarGateway(this._auth);

  final CalendarAuth _auth;

  /// 한 번에 받아올 이벤트 수. Calendar API 상한(2500)보다 넉넉히 낮춰 응답을 짧게 유지한다.
  static const _pageSize = 250;

  /// 전체(비증분) 조회의 미래 방향 상한. 이 창을 넘는 일정은 첫 동기화에서 제외된다 —
  /// 이후 그 시점이 가까워지면 증분 조회가 자연히 실어 온다.
  static const _fullSyncWindow = Duration(days: 365);

  @override
  Future<List<CalendarInfo>> listCalendars() => _withApi((api) async {
    final out = <CalendarInfo>[];
    String? pageToken;
    do {
      final page = await api.calendarList.list(pageToken: pageToken);
      for (final entry in page.items ?? const <gcal.CalendarListEntry>[]) {
        final id = entry.id;
        // 목록에서 내려간 캘린더는 선택지로 노출하지 않는다.
        if (id == null || entry.deleted == true) continue;
        out.add(
          CalendarInfo(
            id: id,
            // 사용자가 이름을 바꿨으면(summaryOverride) 그 이름이 우선.
            summary: entry.summaryOverride ?? entry.summary ?? id,
            primary: entry.primary ?? false,
            accessRole: entry.accessRole ?? 'reader',
          ),
        );
      }
      pageToken = page.nextPageToken;
    } while (pageToken != null);
    return out;
  });

  @override
  Future<String?> insertEvent(String calendarId, gcal.Event event) =>
      _withApi((api) async => (await api.events.insert(event, calendarId)).id);

  @override
  Future<void> updateEvent(
    String calendarId,
    String eventId,
    gcal.Event event,
  ) => _withApi((api) async {
    try {
      await api.events.update(event, calendarId, eventId);
    } on gcal.DetailedApiRequestError catch (e) {
      // 사용자가 구글 쪽에서 이미 지운 이벤트 — 갱신을 계속 재시도해봐야 영영 실패한다.
      // 멱등 성공으로 흘려보내고, 링크 해제는 다음 pull 이 tombstone 을 보고 처리한다.
      if (_isMissingEvent(e)) return;
      rethrow;
    }
  });

  @override
  Future<void> deleteEvent(String calendarId, String eventId) =>
      _withApi((api) async {
        try {
          await api.events.delete(calendarId, eventId);
        } on gcal.DetailedApiRequestError catch (e) {
          if (_isMissingEvent(e)) return; // 이미 없음 = 목표 달성 — 멱등
          rethrow;
        }
      });

  @override
  Future<EventPage> listChanges(
    String calendarId, {
    String? syncToken,
    DateTime? timeMin,
  }) => _withApi((api) async {
    final events = <gcal.Event>[];
    String? pageToken;
    String? nextSyncToken;
    do {
      final page = await api.events.list(
        calendarId,
        syncToken: syncToken,
        // syncToken 과 시간 범위는 함께 못 쓴다 (API 가 400 을 준다) — 증분이면 토큰만.
        timeMin: syncToken == null ? timeMin : null,
        // 전체 조회에는 상한을 건다. 없으면 몇 년 뒤 반복 일정까지 통째로 긁어와
        // 첫 동기화가 수백 건을 앱에 쏟는다. 증분(syncToken)일 때는 넣지 않는다.
        timeMax: syncToken == null
            ? (timeMin ?? DateTime.now().toUtc()).add(_fullSyncWindow)
            : null,
        // 삭제 감지 — 취소된 이벤트(status == 'cancelled')를 받아야 한다.
        showDeleted: true,
        // 반복은 마스터 1건으로. 개별 회차로 펼치면 수백 건이 쏟아진다.
        singleEvents: false,
        pageToken: pageToken,
        maxResults: _pageSize,
      );
      events.addAll(page.items ?? const <gcal.Event>[]);
      pageToken = page.nextPageToken;
      // nextSyncToken 은 마지막 페이지에만 실려 온다.
      nextSyncToken = page.nextSyncToken ?? nextSyncToken;
    } while (pageToken != null);
    return EventPage(events: events, nextSyncToken: nextSyncToken);
  });

  /// 인증된 client 를 열어 [body] 를 돌리고, 오류를 분류해 다시 던진다.
  ///
  /// [CalendarAuth.authedClient] 계약대로 사용 후 반드시 close 한다.
  /// client 가 null (동의 거부/세션 없음) 이면 재인증 필요로 알린다 — 조용한 no-op 은
  /// 호출자가 "성공했는데 아무 일도 없었다" 로 오해하게 만든다.
  Future<T> _withApi<T>(Future<T> Function(gcal.CalendarApi api) body) async {
    final client = await _auth.authedClient();
    if (client == null) {
      throw CalendarGatewayException.authRequired('Google 계정 동의가 없습니다.');
    }
    try {
      return await body(gcal.CalendarApi(client));
    } catch (e, st) {
      Error.throwWithStackTrace(classifyCalendarError(e), st);
    } finally {
      client.close();
    }
  }

  static bool _isMissingEvent(gcal.DetailedApiRequestError e) =>
      e.status == 404 || e.status == 410;
}

/// 백오프 대상 — 잠시 뒤 같은 요청이 통한다.
/// 구형(`errors[].reason`) · 신형(`error.status`) 표기를 함께 받는다.
const _rateLimitReasons = {
  'rateLimitExceeded',
  'userRateLimitExceeded',
  'quotaExceeded',
  'RESOURCE_EXHAUSTED',
};

/// 재인증 대상 — 토큰 자체가 부족하거나 무효하다.
const _authReasons = {
  'authError',
  'invalidCredentials',
  'insufficientPermissions',
  'ACCESS_TOKEN_SCOPE_INSUFFICIENT',
  'UNAUTHENTICATED',
};

/// 오류 본문에서 사유 코드를 긁어모은다.
///
/// `errors` 는 googleapis 가 풀어준 typed 목록이지만 신형 오류 포맷은 여기 안 담긴다.
/// 원본 JSON(`jsonResponse`) 도 함께 훑어서 사유를 놓치지 않는다.
Set<String> _reasonsOf(gcal.DetailedApiRequestError error) {
  final reasons = error.errors.map((d) => d.reason).whereType<String>().toSet();
  final body = error.jsonResponse?['error'];
  if (body is Map) {
    final details = body['errors'];
    if (details is List) {
      for (final d in details) {
        if (d is Map && d['reason'] is String) {
          reasons.add(d['reason'] as String);
        }
      }
    }
    if (body['status'] is String) reasons.add(body['status'] as String);
  }
  return reasons;
}

/// Google API 오류 → 게이트웨이 오류 분류. **순수 함수** (실제 네트워크가 필요 없어
/// 단위 테스트로 전 분기를 덮는다).
CalendarGatewayException classifyCalendarError(Object error) {
  // 이미 분류된 오류는 그대로 통과 — 이중 래핑하면 kind 가 뭉개진다.
  if (error is CalendarGatewayException) return error;

  if (error is gcal.DetailedApiRequestError) {
    final status = error.status;
    final reasons = _reasonsOf(error);

    if (status == 401 || reasons.any(_authReasons.contains)) {
      return CalendarGatewayException(
        CalendarErrorKind.authRequired,
        status: status,
        message: error.message,
      );
    }
    if (status == 429 ||
        (status == 403 && reasons.any(_rateLimitReasons.contains))) {
      return CalendarGatewayException(
        CalendarErrorKind.rateLimited,
        status: status,
        message: error.message,
      );
    }
    // 410 은 syncToken 만료 신호로만 여기까지 온다 — 이벤트 단위 410 은
    // update/delete 가 위에서 멱등 성공으로 먼저 삼킨다.
    if (status == 410) {
      return CalendarGatewayException(
        CalendarErrorKind.syncTokenExpired,
        status: status,
        message: error.message,
      );
    }
    if (status != null && status >= 500) {
      return CalendarGatewayException(
        CalendarErrorKind.transient,
        status: status,
        message: error.message,
      );
    }
    return CalendarGatewayException(
      CalendarErrorKind.permanent,
      status: status,
      message: error.message,
    );
  }

  // refresh token 이 폐기된 경우 — googleapis_auth 는 전용 타입 대신 메시지로 알린다.
  if (error.toString().contains('invalid_grant')) {
    return CalendarGatewayException.authRequired(error.toString());
  }

  if (error is SocketException ||
      error is http.ClientException ||
      error is TimeoutException) {
    return CalendarGatewayException(
      CalendarErrorKind.transient,
      message: error.toString(),
    );
  }

  return CalendarGatewayException(
    CalendarErrorKind.permanent,
    message: error.toString(),
  );
}
