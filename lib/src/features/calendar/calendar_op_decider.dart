import '../../domain/todo.dart';

/// 한 번의 Todo 저장이 캘린더에 무엇을 해야 하는지.
enum CalendarOpKind {
  /// 캘린더와 무관한 변경 — 큐에 넣지 않는다.
  none,

  /// 이벤트 신규 생성.
  create,

  /// 기존 이벤트 갱신.
  update,

  /// 기존 이벤트 삭제 (+ 로컬 링크 해제는 호출자 책임).
  delete,
}

/// [decideCalendarOp] 의 결과. 큐 row 를 만드는 데 필요한 것만 담는다.
class CalendarOpDecision {
  const CalendarOpDecision(this.kind, {this.eventId, this.calendarId});

  const CalendarOpDecision.none()
    : kind = CalendarOpKind.none,
      eventId = null,
      calendarId = null;

  final CalendarOpKind kind;

  /// update / delete 대상 이벤트. create 면 null (아직 없다).
  final String? eventId;

  /// 대상 캘린더. create 는 설정의 쓰기 캘린더, update/delete 는 **이벤트가 실제로
  /// 들어있는** 캘린더다 — 사용자가 쓰기 캘린더를 바꿔도 옛 이벤트를 찾아가야 한다.
  final String? calendarId;

  @override
  String toString() =>
      'CalendarOpDecision($kind, event: $eventId, calendar: $calendarId)';
}

/// 이 필드들이 바뀌면 이벤트도 바뀌어야 한다.
///
/// 여기 없는 필드(sortOrder / parentId / description / calendarEventId ...)는
/// 아무리 바뀌어도 캘린더를 건드리지 않는다. 이 구분이 이 파일의 존재 이유다 —
/// `reorderSiblings` 는 형제 전체를 upsert 하므로, 판정이 느슨하면 순서 한 번
/// 바꿀 때마다 구글 API 가 형제 수만큼 호출된다.
bool _watchedFieldsChanged(Todo a, Todo b) {
  // 카테고리는 **id 만** 본다. label/색/아이콘은 조회 시점 join 으로 복원되는
  // 표시 속성이라 내용 변경이 아니다 (TodoActionsController._isUnchanged 와 동일 규칙).
  if (a.category.id != b.category.id) return true;
  return a.title != b.title ||
      a.dueAt != b.dueAt ||
      a.endAt != b.endAt ||
      a.isAllDay != b.isAllDay ||
      a.timeAnchor != b.timeAnchor ||
      a.doneAt != b.doneAt ||
      a.type != b.type ||
      a.recurrenceRule != b.recurrenceRule ||
      a.recurrenceEndAt != b.recurrenceEndAt;
}

/// 반복 시리즈의 **인스턴스**인가 — 마스터가 RRULE 이벤트 1개를 소유하므로
/// 인스턴스는 이벤트를 갖지 않는다. 막지 않으면 회차마다 이벤트가 생긴다.
bool _isSeriesInstance(Todo t) => t.seriesId != null && !t.isSeriesMaster;

/// 이 할 일이 캘린더에 있을 수 있는 종류인가 (내용 무관, 자격 판정).
bool _eligible(Todo t) =>
    t.type == TodoType.task && t.dueAt != null && !_isSeriesInstance(t);

/// 한 번의 저장([prev] → [next])이 캘린더에 무엇을 해야 하는지 판정하는 순수 함수.
///
/// 저장소 데코레이터가 **모든** mutation 마다 호출한다. I/O 도 시계도 쓰지 않는다.
///
/// - [prev] 는 변경 전 상태. null 이면 신규 저장이다.
/// - [addToCalendar] 는 편집 시트의 "Google Calendar 에 등록" 토글(신규 생성 여부만
///   좌우한다 — 이미 등록된 항목의 갱신·삭제는 토글과 무관하게 따라가야 한다).
/// - [writeCalendarId] 는 설정에서 고른 쓰기 캘린더.
CalendarOpDecision decideCalendarOp({
  required Todo? prev,
  required Todo next,
  required bool addToCalendar,
  required String writeCalendarId,
}) {
  final eventId = next.calendarEventId;

  if (eventId != null) {
    // 이미 캘린더에 있다. 사라져야 하는가?
    final calendarId = next.calendarId ?? prev?.calendarId ?? writeCalendarId;
    if (!_eligible(next)) {
      return CalendarOpDecision(
        CalendarOpKind.delete,
        eventId: eventId,
        calendarId: calendarId,
      );
    }
    // 변경 전 상태를 모르면(다른 기기가 만든 항목이 처음 도착한 경우 등) 되쏘지
    // 않는다. 우리가 만든 변경이 아니므로 캘린더는 이미 최신일 가능성이 높다.
    if (prev == null) return const CalendarOpDecision.none();
    if (!_watchedFieldsChanged(prev, next)) {
      return const CalendarOpDecision.none();
    }
    return CalendarOpDecision(
      CalendarOpKind.update,
      eventId: eventId,
      calendarId: calendarId,
    );
  }

  // 링크가 없다 — 새로 만들 자격과 의사가 모두 있어야 만든다.
  if (_eligible(next) && addToCalendar) {
    return CalendarOpDecision(
      CalendarOpKind.create,
      calendarId: writeCalendarId,
    );
  }
  return const CalendarOpDecision.none();
}
