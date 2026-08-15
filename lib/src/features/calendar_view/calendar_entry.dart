import 'package:flutter/material.dart' show Color;

import '../../domain/todo.dart';

/// 캘린더 한 칸에 그려지는 항목의 통합 표현.
///
/// 캘린더는 성격이 다른 셋을 한 격자에 섞어 그린다 — 실제 [Todo], 아직 DB 에 실체가
/// 없는 미래 반복 회차(고스트), 그리고 읽기 전용 구글 이벤트. 셋을 각각 분기하면
/// 버킷팅·정렬·막대 배치 로직이 세 벌이 되므로, **한 인터페이스로 좁혀** 레이아웃
/// 계산은 한 벌만 두고 시각 표현만 위젯에서 갈라낸다.
///
/// freezed 를 쓰지 않는 이유: 순수 UI 뷰모델이라 copyWith / JSON 이 필요 없고,
/// codegen 을 붙이면 빌드만 느려진다.
sealed class CalendarEntry {
  const CalendarEntry();

  /// local **date-only** 시작일.
  DateTime get startDate;

  /// local **date-only** 종료일. 단일 항목이면 [startDate] 와 같다.
  DateTime get endDate;

  String get title;

  /// 좌측 색 바 / 점의 색. Todo 계열은 카테고리 색을 그대로 쓴다.
  Color get color;

  bool get isDone;

  /// 드래그로 날짜를 옮길 수 있는가. 구글 이벤트는 읽기 전용이라 false.
  bool get isDraggable;

  /// 아직 DB 에 실체가 없는 예정인가 (미래 반복 회차). 점선으로 그린다.
  bool get isGhost;

  /// 종일 항목인가. true 면 시각을 화면 어디에도 찍지 않는다 (전 앱 불변 규칙).
  bool get isAllDay;

  /// 시각 정렬용 앵커. 종일이면 null.
  DateTime? get timeAnchorAt;

  /// 같은 칸 안의 순서 tiebreak — Todo 의 사용자 정의 순서.
  int get sortOrder;

  /// 순서 tiebreak (createdAt desc).
  DateTime get createdAt;

  /// `ValueKey` 및 정렬 최종 tiebreak 용 안정 식별자.
  String get entryKey;

  /// 이틀 이상 걸치는가 — true 면 칩이 아니라 가로 막대로 그린다.
  bool get spansMultipleDays => endDate.isAfter(startDate);
}

/// 실제 [Todo] 한 건.
class TodoEntry extends CalendarEntry {
  TodoEntry(this.todo)
    : assert(todo.dueAt != null, 'dueAt 없는 Todo 는 캘린더 엔트리가 될 수 없다'),
      startDate = dateOnly(todo.dueAt!.toLocal()),
      endDate = _resolveEndDate(todo);

  final Todo todo;

  @override
  final DateTime startDate;

  @override
  final DateTime endDate;

  /// 종료일이 시작일보다 앞서는 뒤집힌 데이터는 단일 항목으로 접는다.
  /// (막대 span 이 음수가 되면 레이아웃이 통째로 깨지므로 여기서 한 번만 막는다.)
  static DateTime _resolveEndDate(Todo todo) {
    final start = dateOnly(todo.dueAt!.toLocal());
    final end = todo.endAt;
    if (end == null) return start;
    final end0 = dateOnly(end.toLocal());
    return end0.isBefore(start) ? start : end0;
  }

  @override
  String get title => todo.title;

  @override
  Color get color => todo.category.color;

  @override
  bool get isDone => todo.isDone;

  @override
  bool get isDraggable => true;

  @override
  bool get isGhost => false;

  @override
  bool get isAllDay => todo.isAllDay;

  @override
  DateTime? get timeAnchorAt => todo.isAllDay ? null : todo.dueAt!.toLocal();

  @override
  int get sortOrder => todo.sortOrder;

  @override
  DateTime get createdAt => todo.createdAt;

  @override
  String get entryKey => 'todo:${todo.id}';
}

/// 미래 반복 회차 — 아직 DB 에 row 가 없는 "예정".
///
/// 이 앱의 반복은 하이브리드다: `RecurrenceMaterializer` 가 **오늘까지만** 인스턴스를
/// 실체화하므로 미래 회차는 존재하지 않는다. 캘린더는 마스터의 규칙으로 미래 발생일을
/// 런타임 계산해 이 고스트로 그리고, 사용자가 건드리는 순간 실체화한다.
class RecurringGhostEntry extends CalendarEntry {
  RecurringGhostEntry({required this.master, required DateTime date})
    : assert(master.dueAt != null, '반복 마스터는 anchor(dueAt) 를 가진다'),
      startDate = dateOnly(date),
      endDate = DateTime(date.year, date.month, date.day + _spanDays(master));

  /// 이 회차가 속한 반복 마스터. 실체화할 때 그대로 쓴다.
  final Todo master;

  @override
  final DateTime startDate;

  @override
  final DateTime endDate;

  /// 마스터가 기간 항목이면 회차도 같은 길이를 갖는다.
  static int _spanDays(Todo master) {
    final end = master.endAt;
    if (end == null) return 0;
    final days = dateOnly(
      end.toLocal(),
    ).difference(dateOnly(master.dueAt!.toLocal())).inDays;
    return days > 0 ? days : 0;
  }

  @override
  String get title => master.title;

  @override
  Color get color => master.category.color;

  /// 고스트는 실체가 없으므로 완료일 수 없다.
  @override
  bool get isDone => false;

  @override
  bool get isDraggable => true;

  @override
  bool get isGhost => true;

  @override
  bool get isAllDay => master.isAllDay;

  /// 시각은 마스터의 것을 그대로 이어받고 날짜만 이 회차의 것으로 바꾼다.
  @override
  DateTime? get timeAnchorAt {
    if (master.isAllDay) return null;
    final anchor = master.dueAt!.toLocal();
    return DateTime(
      startDate.year,
      startDate.month,
      startDate.day,
      anchor.hour,
      anchor.minute,
    );
  }

  @override
  int get sortOrder => master.sortOrder;

  @override
  DateTime get createdAt => master.createdAt;

  /// 실체화됐을 때의 `RecurrenceMaterializer.instanceId` 와 같은 규약을 쓴다 —
  /// 고스트가 실체로 바뀌어도 key 가 튀지 않아 리스트 애니메이션이 이어진다.
  @override
  String get entryKey {
    final y = startDate.year.toString().padLeft(4, '0');
    final m = startDate.month.toString().padLeft(2, '0');
    final d = startDate.day.toString().padLeft(2, '0');
    return 'ghost:${master.seriesId ?? master.id}#$y$m$d';
  }
}

/// 구글 캘린더 이벤트 — **읽기 전용**.
///
/// 이 워크트리는 앱 내 캘린더 화면만 담당하고 구글 동기화는 형제 워크트리가 맡는다.
/// 따라서 여기서는 조회 결과를 그리기만 하고 편집·삭제·이동을 일절 열지 않는다.
class GoogleEventEntry extends CalendarEntry {
  GoogleEventEntry({
    required this.id,
    required this.title,
    required DateTime start,
    required DateTime end,
    required this.isAllDay,
  }) : startDate = dateOnly(start),
       endDate = dateOnly(end).isBefore(dateOnly(start))
           ? dateOnly(start)
           : dateOnly(end),
       _start = start;

  /// 구글 이벤트를 로컬 항목과 구분하는 고정 색. 카테고리 색과 겹치지 않는 중성 톤.
  static const Color eventColor = Color(0xFF6B7A90);

  final String id;
  final DateTime _start;

  @override
  final String title;

  @override
  final DateTime startDate;

  @override
  final DateTime endDate;

  @override
  final bool isAllDay;

  @override
  Color get color => eventColor;

  /// 구글 이벤트에는 완료 개념이 없다.
  @override
  bool get isDone => false;

  @override
  bool get isDraggable => false;

  @override
  bool get isGhost => false;

  @override
  DateTime? get timeAnchorAt => isAllDay ? null : _start;

  @override
  int get sortOrder => 0;

  @override
  DateTime get createdAt => _start;

  @override
  String get entryKey => 'gcal:$id';
}

/// 시각 성분을 잘라낸 **local date-only** 값. 캘린더의 모든 날짜 비교는 이 값으로 한다.
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
