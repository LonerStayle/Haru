import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import '../../domain/todo.dart';
import 'google_auth_service.dart';

/// Google Calendar API wrapper. Todo ↔ Event 매핑 단일 출처.
///
/// 인증은 [CalendarAuth] 가 플랫폼별로(macOS=데스크톱 OAuth, Android=google_sign_in)
/// 책임지고, 이 서비스는 인증된 [http.Client] 만 받아 Calendar API 를 호출한다.
class CalendarService {
  CalendarService(this._auth);

  final CalendarAuth _auth;

  /// 기본 대상 캘린더. 사용자가 설정에서 고르기 전(또는 레거시 항목)의 값이다.
  static const defaultCalendarId = 'primary';

  /// Todo 의 dueAt 기반 이벤트 생성. dueAt 이 null 이면 null 반환.
  /// 사용자가 OAuth 인증을 거부/실패하면 null (호출자가 graceful 처리).
  Future<String?> createEventForTodo(
    Todo todo, {
    bool isAllDay = false,
    String calendarId = defaultCalendarId,
  }) async {
    if (todo.dueAt == null) return null;
    final client = await _auth.authedClient();
    if (client == null) return null;
    try {
      final api = gcal.CalendarApi(client);
      final created = await api.events.insert(
        _toEvent(todo, isAllDay: isAllDay),
        calendarId,
      );
      return created.id;
    } finally {
      client.close();
    }
  }

  /// 기존 캘린더 이벤트를 todo 의 최신 상태로 갱신. dueAt 이 null 이 되면 이벤트 삭제.
  Future<void> updateEventForTodo(
    Todo todo,
    String eventId, {
    String calendarId = defaultCalendarId,
  }) async {
    if (todo.dueAt == null) {
      await deleteEvent(eventId, calendarId: calendarId);
      return;
    }
    final client = await _auth.authedClient();
    if (client == null) return;
    try {
      final api = gcal.CalendarApi(client);
      await api.events.update(_toEvent(todo), calendarId, eventId);
    } finally {
      client.close();
    }
  }

  /// 캘린더 이벤트 삭제. 이미 삭제된 (404/410) 경우 silent — 멱등.
  Future<void> deleteEvent(
    String eventId, {
    String calendarId = defaultCalendarId,
  }) async {
    final client = await _auth.authedClient();
    if (client == null) return;
    try {
      final api = gcal.CalendarApi(client);
      await api.events.delete(calendarId, eventId);
    } on gcal.DetailedApiRequestError catch (e) {
      if (e.status == 404 || e.status == 410) return; // 이미 없음 — 멱등
      rethrow;
    } finally {
      client.close();
    }
  }

  gcal.Event _toEvent(Todo todo, {bool isAllDay = false}) =>
      buildEvent(todo, isAllDayHint: isAllDay);

  /// fast-tasks — Todo 의 날짜·기간 모델을 Google Calendar Event 로 매핑. 단일 출처.
  ///
  /// - 하루종일 / 기간+isAllDay → all-day 이벤트 (start.date / end.date,
  ///   end.date 는 종료+1일 — Google 의 exclusive 종료 규칙).
  /// - 단일 시간 (start/end anchor) → 그 시각 기준 기본 1시간 이벤트.
  /// - 기간(!isAllDay) → start.dateTime=dueAt, end.dateTime=endAt.
  ///
  /// [isAllDayHint] 는 호출자가 모델 없이 종일 의도를 줄 때의 fallback —
  /// todo 자체의 모드가 우선한다.
  @visibleForTesting
  static gcal.Event buildEvent(Todo todo, {bool isAllDayHint = false}) {
    final desc = '${todo.category.label} · 하루 자동 등록';
    final due = todo.dueAt!;

    gcal.Event allDayEvent(DateTime start, DateTime endInclusive) {
      final s = start.toLocal();
      final e = endInclusive.toLocal();
      final startDate = DateTime(s.year, s.month, s.day);
      // Google 종일 이벤트의 end.date 는 exclusive → 종료 다음날.
      final endDate = DateTime(
        e.year,
        e.month,
        e.day,
      ).add(const Duration(days: 1));
      return gcal.Event(
        summary: todo.title,
        description: desc,
        start: gcal.EventDateTime(date: startDate),
        end: gcal.EventDateTime(date: endDate),
      );
    }

    gcal.Event timedEvent(DateTime start, DateTime end) => gcal.Event(
      summary: todo.title,
      description: desc,
      start: gcal.EventDateTime(dateTime: start.toUtc(), timeZone: 'UTC'),
      end: gcal.EventDateTime(dateTime: end.toUtc(), timeZone: 'UTC'),
    );

    final event = switch (todo.dateMode) {
      // none: dueAt!.toUtc() 가 위에서 보장되므로 도달 안 함. 안전상 종일로.
      TodoDateMode.none || TodoDateMode.allDay => allDayEvent(due, due),
      // 시각 기준 기본 1시간. (anchor 는 표시 의미라 캘린더는 동일하게 1h 블록.)
      TodoDateMode.startTime || TodoDateMode.endTime => timedEvent(
        due,
        due.add(const Duration(hours: 1)),
      ),
      TodoDateMode.range =>
        todo.isAllDay
            ? allDayEvent(due, todo.endAt ?? due)
            : timedEvent(due, todo.endAt ?? due),
    };

    // date-repeat: 반복 마스터면 RRULE 1개를 이벤트에 부착해 반복 일정으로 등록한다.
    // 인스턴스/일반 Todo 는 단일 이벤트 — 반복은 마스터의 RRULE 이 커버하므로 부착 X.
    final rule = todo.recurrence;
    if (todo.isRecurringMaster && rule != null) {
      event.recurrence = [rule.toRRule(todo.recurrenceEndAt)];
    }

    // google-calendar-sync: 완료 표시는 **색으로만** 한다 (8 = Graphite 회색).
    // 제목에 "✓" 를 붙이는 방식은 되가져올 때 제목을 파싱해 떼어내야 해서
    // 사용자가 직접 "✓" 로 시작하는 제목을 쓰면 깨진다. 미완료면 null 로 되돌려
    // 캘린더 기본색을 복구한다.
    event.colorId = todo.isDone ? '8' : null;

    // google-calendar-sync: 앱 서명. 되가져오기(pull) 가 이 값들을 읽는다.
    //  - haruRev   — echo 차단. 수신한 이벤트의 rev 가 로컬 updatedAt 과 같으면
    //                "우리가 쓴 것" 이므로 무시한다. 이 비교가 어긋나면 push↔pull
    //                무한 루프가 돈다 → UTC ISO8601 로 고정.
    //  - haruDateMode / haruAnchor — 왕복 안정성. startTime 모드는 "시각+1시간"
    //                블록으로 나가므로, 형태만 보고 되읽으면 range 로 변질된다.
    //  - haruTodoId — 링크 복구·중복 이벤트 정리용 역추적 키.
    event.extendedProperties = gcal.EventExtendedProperties(
      private: {
        'haruTodoId': todo.id,
        'haruRev': todo.updatedAt.toUtc().toIso8601String(),
        'haruDateMode': todo.dateMode.name,
        'haruAnchor': todo.timeAnchor,
      },
    );
    return event;
  }
}

/// CalendarService 인스턴스. CalendarAuth 미설정 시 null.
final calendarServiceProvider = Provider<CalendarService?>((ref) {
  final auth = ref.watch(calendarAuthProvider);
  return auth == null ? null : CalendarService(auth);
});

/// AddTodoController 가 호출하는 헬퍼. 실패는 fatal X — todo 자체는 저장되어야 한다.
Future<String?> tryCreateCalendarEvent(Ref ref, Todo todo) async {
  final svc = ref.read(calendarServiceProvider);
  if (svc == null) return null;
  try {
    return await svc.createEventForTodo(todo);
  } catch (e) {
    debugPrint('[solo_todo] Calendar 이벤트 생성 실패: $e');
    return null;
  }
}

/// Todo 변경 시 (편집 흐름) 호출. eventId 가 있는 todo 만 처리.
Future<void> tryUpdateCalendarEvent(Ref ref, Todo todo) async {
  final eventId = todo.calendarEventId;
  if (eventId == null) return;
  final svc = ref.read(calendarServiceProvider);
  if (svc == null) return;
  try {
    await svc.updateEventForTodo(todo, eventId);
  } catch (e) {
    debugPrint('[solo_todo] Calendar 이벤트 갱신 실패: $e');
  }
}

Future<void> tryDeleteCalendarEvent(Ref ref, String? eventId) async {
  if (eventId == null) return;
  final svc = ref.read(calendarServiceProvider);
  if (svc == null) return;
  try {
    await svc.deleteEvent(eventId);
  } catch (e) {
    debugPrint('[solo_todo] Calendar 이벤트 삭제 실패: $e');
  }
}
