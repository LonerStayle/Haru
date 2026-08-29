import '../../domain/recurrence.dart';
import '../../domain/todo.dart';
import 'calendar_event.dart';

/// 이벤트에 심어둔 앱 서명 (`CalendarService.buildEvent` 가 넣는다).
///
/// 되가져오기가 이 값들로 "우리가 쓴 변경인가 / 어느 할 일 것인가 / 원래 어떤
/// 날짜 모드였나" 를 판단한다.
class HaruSignature {
  const HaruSignature({this.todoId, this.rev, this.dateMode, this.anchor});

  /// 이 이벤트가 대응하는 할 일 id. 로컬 링크가 유실돼도 역추적할 수 있다.
  final String? todoId;

  /// 앱이 마지막으로 push 한 시점의 `updatedAt` (UTC ISO8601).
  /// 로컬 `updatedAt` 과 같으면 이 변경은 우리가 쓴 것 → 무시(echo 차단).
  final String? rev;

  /// push 당시의 날짜 모드. 형태만으로는 복원할 수 없는 정보다.
  final TodoDateMode? dateMode;

  /// push 당시의 `timeAnchor` ('start' | 'end').
  final String? anchor;

  bool get isFromApp => todoId != null;
}

/// 이벤트에서 앱 서명을 읽는다. 서명이 없으면 빈 값 (사람이 캘린더에서 만든 것,
/// 또는 서비스가 확장 속성을 되돌려주지 않은 것).
HaruSignature readHaruSignature(CalEvent event) {
  final p = event.appProperties;
  if (p.isEmpty) return const HaruSignature();
  final modeName = p['haruDateMode'];
  return HaruSignature(
    todoId: p['haruTodoId'],
    rev: p['haruRev'],
    dateMode: modeName == null ? null : _modeFromName(modeName),
    anchor: p['haruAnchor'],
  );
}

TodoDateMode? _modeFromName(String name) {
  for (final m in TodoDateMode.values) {
    if (m.name == name) return m;
  }
  return null;
}

/// 이벤트에서 뽑아낸, 할 일에 적용할 값들.
///
/// **Todo 를 통째로 만들지 않는 이유** — 유입 경로(신규 생성)와 갱신 경로(기존 항목
/// 덮어쓰기)가 필요로 하는 것이 다르다. 신규는 카테고리·정렬·부모를 호출자가 정해야
/// 하고, 갱신은 그것들을 **보존**해야 한다. 날짜·제목 묶음만 돌려주고 적용은 호출자가
/// 하면 두 경로가 같은 매핑을 공유하면서도 서로의 관심사를 침범하지 않는다.
class EventDatePatch {
  const EventDatePatch({
    required this.title,
    required this.dueAt,
    required this.endAt,
    required this.isAllDay,
    required this.timeAnchor,
    required this.dateMode,
    this.recurrence,
    this.recurrenceEndAt,
    this.unsupportedRecurrence = false,
  });

  final String title;
  final DateTime? dueAt;
  final DateTime? endAt;
  final bool isAllDay;
  final String timeAnchor;

  /// 복원된 날짜 모드. 호출자가 검증·표시에 쓴다.
  final TodoDateMode dateMode;

  /// 복원된 반복 규칙. 없거나 표현 불가면 null.
  final RecurrenceRule? recurrence;
  final DateTime? recurrenceEndAt;

  /// 반복 이벤트이긴 한데 우리 모델로 표현할 수 없어 단일로 폴백했는가.
  /// 호출자가 사용자에게 "반복은 캘린더에서만 관리됨" 을 알릴 수 있다.
  final bool unsupportedRecurrence;
}

/// 제목 없는 이벤트의 표시 이름. 빈 제목으로 할 일을 만들면 목록에서 사라진 것처럼 보인다.
const _untitledLabel = '(제목 없음)';

/// 캘린더 이벤트를 할 일의 날짜·제목 값으로 되돌린다.
///
/// 시작 시각이 없으면 null — 할 일로 만들 근거가 없다.
///
/// 앱이 만든 이벤트라면 서명의 `haruDateMode` 로 **원래 모드를 그대로 복원**한다.
/// 서명이 없으면 [shapeHint] 를 쓰고(연결된 할 일의 현재 모드 — 아래 참조), 그것도
/// 없으면 이벤트 형태로 추론한다:
///
/// | 형태 | 결과 |
/// |---|---|
/// | 종일 하루 | `allDay` |
/// | 종일 이틀 이상 | `range` + isAllDay (end.date 의 exclusive 를 −1일로 되돌림) |
/// | 시간 이벤트 | `range` |
///
/// **[shapeHint] 가 왜 필요한가** — Microsoft Graph 의 증분 응답에는 우리가 심은
/// 확장 속성이 실려 오지 않을 수 있다. 서명이 없으면 "시작시간" 모드로 올린 1시간
/// 블록이 되읽을 때 `range` 로 변질되고, 그 변질이 다시 저장되어 할 일의 날짜 모드가
/// 조용히 바뀐다. 이미 연결된 할 일이 있다면 그 할 일의 현재 모드가 가장 정확한
/// 힌트다. 단 **형태와 어긋나는 힌트는 무시**한다 — 사람이 종일 일정을 시간 일정으로
/// 바꿨는데 힌트를 따르면 그 변경을 영영 못 받는다.
EventDatePatch? eventToTodoPatch(
  CalEvent event, {
  TodoDateMode? shapeHint,
  String? anchorHint,
}) {
  final start = event.start;
  final startDate = start?.date;
  final startTime = start?.dateTime;
  if (startDate == null && startTime == null) return null;

  final sig = readHaruSignature(event);
  final isAllDayEvent = startDate != null;
  final dueAt = startDate ?? startTime!;

  // 종일 이벤트의 end.date 는 exclusive(종료 다음날) — 하루를 빼야 사람이 보는 종료일.
  final rawEnd = isAllDayEvent ? event.end?.date : event.end?.dateTime;
  final endInclusive = isAllDayEvent && rawEnd != null
      ? rawEnd.subtract(const Duration(days: 1))
      : rawEnd;

  final spansMultipleDays =
      isAllDayEvent &&
      endInclusive != null &&
      endInclusive.difference(dueAt).inDays >= 1;

  // 서명 → 힌트 → 형태 추론 순으로 모드를 정한다. 앞의 둘은 형태와 맞을 때만 쓴다.
  final candidate = sig.dateMode ?? shapeHint;
  final mode = _compatible(candidate, isAllDayEvent)
      ? candidate!
      : (isAllDayEvent
            ? (spansMultipleDays ? TodoDateMode.range : TodoDateMode.allDay)
            : TodoDateMode.range);
  final anchor = sig.anchor ?? anchorHint;

  final (
    DateTime? resolvedEnd,
    bool allDay,
    String resolvedAnchor,
  ) = switch (mode) {
    // none 은 dueAt 이 없다는 뜻인데 이벤트에는 시작이 있다 — 종일로 안전 폴백.
    TodoDateMode.none || TodoDateMode.allDay => (null, true, anchor ?? 'start'),
    TodoDateMode.startTime => (null, false, 'start'),
    TodoDateMode.endTime => (null, false, 'end'),
    TodoDateMode.range => (endInclusive, isAllDayEvent, anchor ?? 'start'),
  };

  // 반복 — 표현 가능한 규칙만 살리고, 나머지는 단일로 폴백하되 그 사실을 알린다.
  final recurrence = event.recurrence;

  final title = (event.title ?? '').trim();
  return EventDatePatch(
    title: title.isEmpty ? _untitledLabel : title,
    dueAt: dueAt,
    endAt: resolvedEnd,
    isAllDay: allDay,
    timeAnchor: resolvedAnchor,
    dateMode: mode == TodoDateMode.none ? TodoDateMode.allDay : mode,
    recurrence: recurrence?.rule,
    recurrenceEndAt: recurrence?.until,
    unsupportedRecurrence: recurrence != null && !recurrence.isSupported,
  );
}

/// 후보 모드가 이벤트의 실제 형태(종일/시간)와 어울리는가.
///
/// 종일 이벤트에 `startTime` 을, 시간 이벤트에 `allDay` 를 씌우면 시각이 통째로
/// 사라지거나 없던 시각이 생긴다. 어긋나면 힌트를 버리고 형태로 추론한다.
bool _compatible(TodoDateMode? mode, bool isAllDayEvent) {
  if (mode == null) return false;
  return switch (mode) {
    TodoDateMode.none => false,
    TodoDateMode.allDay => isAllDayEvent,
    TodoDateMode.startTime || TodoDateMode.endTime => !isAllDayEvent,
    // 기간은 양쪽 형태 모두 가능하다 (종일 기간 / 시간 기간).
    TodoDateMode.range => true,
  };
}
