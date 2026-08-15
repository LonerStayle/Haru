import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import '../../domain/todo.dart';
import 'google_auth_service.dart';

/// Todo → Google Calendar Event 매핑의 **단일 출처**.
///
/// 예전에는 이 클래스가 API 호출까지 직접 했지만, 그러면 실제 구글 인증 없이는
/// 한 줄도 테스트할 수 없었다. 호출은 `CalendarGateway` 로 옮기고 여기에는 매핑만
/// 남겼다 — 동기화 서비스·큐·되가져오기가 전부 이 매핑을 공유한다.
class CalendarService {
  const CalendarService();

  /// 기본 대상 캘린더. 사용자가 설정에서 고르기 전(또는 레거시 항목)의 값이다.
  static const defaultCalendarId = 'primary';

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

/// 캘린더 연동이 **설정되어 있는가**의 신호. OAuth 키가 없으면 null.
/// (호출 경로는 `CalendarGateway` 가 담당하므로 이 값은 게이트 용도로만 쓴다.)
final calendarServiceProvider = Provider<CalendarService?>((ref) {
  final auth = ref.watch(calendarAuthProvider);
  return auth == null ? null : const CalendarService();
});
