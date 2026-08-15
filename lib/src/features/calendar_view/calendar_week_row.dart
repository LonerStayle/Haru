import 'package:flutter/material.dart';

import '../../core/platform.dart';
import 'calendar_day_cell.dart';
import 'calendar_entry.dart';
import 'calendar_layout.dart';

/// 기간 막대 한 줄의 높이.
const double _barHeight = 12;
const double _barGap = 2;

/// 셀 안 날짜 숫자 줄의 높이 — 막대 오버레이를 그 아래에 얹기 위한 오프셋.
double get _dayNumberHeight => AppPlatform.isMobile ? 20 : 22;

/// 막대 레인 상한. 넘치는 막대는 셀의 "외 N건" 으로 합산한다.
///
/// 상한이 없으면 기간 항목이 겹칠 때 주 행 높이가 무한정 늘어나 달력이 스크롤된다.
/// 달력의 값은 "한 화면에서 한 달을 본다" 이므로 높이를 고정하는 쪽을 택했다.
int get _maxLanes => AppPlatform.isMobile ? 2 : 3;

/// 월 그리드의 한 주(7일) 행.
///
/// 구조는 Stack 두 겹 —
/// 1. 날짜 셀 7개 (탭·롱프레스·드롭 대상, 칩/점 렌더)
/// 2. 기간 막대 오버레이 (여러 칸에 걸쳐야 해서 셀 밖에서 그린다. `IgnorePointer`
///    라 아래 셀의 탭을 가리지 않는다)
class CalendarWeekRow extends StatelessWidget {
  const CalendarWeekRow({
    super.key,
    required this.days,
    required this.buckets,
    required this.focusedMonth,
    required this.today,
    required this.selectedDay,
    this.onSelectDay,
    this.onLongPressDay,
    this.dayCellBuilder,
  });

  /// 이 행의 7일 (일요일 시작).
  final List<DateTime> days;

  /// 날짜별 엔트리 버킷 (정렬 완료).
  final Map<DateTime, List<CalendarEntry>> buckets;

  final DateTime focusedMonth;
  final DateTime today;
  final DateTime selectedDay;

  final void Function(DateTime date)? onSelectDay;
  final void Function(DateTime date)? onLongPressDay;

  /// 셀을 드롭 타깃으로 감싸기 위한 훅.
  ///
  /// 완성된 위젯이 아니라 **빌더**를 넘기는 이유: 드롭 하이라이트는 셀 자신의
  /// 장식이라 `DragTarget` 이 후보 여부를 알게 된 뒤에야 셀을 만들 수 있다.
  final Widget Function(DateTime date, CalendarDayCellBuilder build)?
  dayCellBuilder;

  @override
  Widget build(BuildContext context) {
    // 이 주에 걸친 기간 막대를 레인에 배치. 주 전체의 엔트리를 한 번에 넘겨야
    // 레인이 칸별로 어긋나지 않는다.
    final weekEntries = <String, CalendarEntry>{};
    for (final d in days) {
      for (final e in buckets[d] ?? const <CalendarEntry>[]) {
        weekEntries[e.entryKey] = e;
      }
    }
    final segments = layoutWeekBars(weekEntries.values, days.first);
    final visible = segments.where((s) => s.lane < _maxLanes).toList();
    final laneCount = visible.isEmpty
        ? 0
        : visible.map((s) => s.lane).reduce((a, b) => a > b ? a : b) + 1;

    // 상한을 넘겨 안 그려진 막대는 걸친 날짜마다 "외 N건" 으로 합산한다.
    final hiddenByDate = <DateTime, int>{};
    for (final s in segments.where((s) => s.lane >= _maxLanes)) {
      for (var c = s.startCol; c <= s.endCol; c++) {
        hiddenByDate.update(days[c], (v) => v + 1, ifAbsent: () => 1);
      }
    }

    final reservedTop = laneCount == 0
        ? 0.0
        : laneCount * (_barHeight + _barGap);

    return Stack(
      children: [
        Row(
          children: [
            for (final d in days)
              Expanded(child: _buildCell(d, reservedTop, hiddenByDate)),
          ],
        ),
        if (laneCount > 0)
          Positioned(
            left: 0,
            right: 0,
            top: _dayNumberHeight + (AppPlatform.isMobile ? 4 : 8),
            child: IgnorePointer(
              child: Padding(
                // 셀의 좌우 padding + 테두리만큼 안쪽으로 들여 막대가 칸 경계에
                // 딱 붙지 않게 한다.
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(
                  children: [
                    for (var lane = 0; lane < laneCount; lane++) ...[
                      _LaneRow(
                        segments: visible.where((s) => s.lane == lane).toList(),
                      ),
                      const SizedBox(height: _barGap),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCell(
    DateTime date,
    double reservedTop,
    Map<DateTime, int> hiddenByDate,
  ) {
    final entries = buckets[date] ?? const <CalendarEntry>[];
    Widget build({bool isDropTarget = false}) => CalendarDayCell(
      // key 는 셀 위젯 자체에 둔다 — 테스트가 find.byKey 로 찾은 것을 그대로
      // CalendarDayCell 로 읽을 수 있어야 상태(isToday/isSelected)를 검증할 수 있다.
      key: ValueKey('calendar-cell-${calendarDateKey(date)}'),
      date: date,
      singleDayEntries: entries
          .where((e) => !e.spansMultipleDays)
          .toList(growable: false),
      hiddenBarCount: hiddenByDate[date] ?? 0,
      reservedTop: reservedTop,
      isToday: date == today,
      isSelected: date == selectedDay,
      isOutsideMonth:
          date.month != focusedMonth.month || date.year != focusedMonth.year,
      isDropTarget: isDropTarget,
      onTap: onSelectDay == null ? null : () => onSelectDay!(date),
      onLongPress: onLongPressDay == null ? null : () => onLongPressDay!(date),
    );
    return dayCellBuilder?.call(date, build) ?? build();
  }
}

/// [CalendarWeekRow.dayCellBuilder] 가 받는 셀 빌더.
typedef CalendarDayCellBuilder = Widget Function({bool isDropTarget});

/// 막대 한 레인 — 7열을 flex 로 나눠 세그먼트를 배치한다.
class _LaneRow extends StatelessWidget {
  const _LaneRow({required this.segments});

  final List<BarSegment> segments;

  @override
  Widget build(BuildContext context) {
    final sorted = [...segments]
      ..sort((a, b) => a.startCol.compareTo(b.startCol));

    final children = <Widget>[];
    var col = 0;
    for (final s in sorted) {
      if (s.startCol > col) {
        children.add(Expanded(flex: s.startCol - col, child: const SizedBox()));
      }
      children.add(
        Expanded(
          flex: s.span,
          child: _Bar(segment: s),
        ),
      );
      col = s.endCol + 1;
    }
    if (col < calendarDaysPerWeek) {
      children.add(
        Expanded(flex: calendarDaysPerWeek - col, child: const SizedBox()),
      );
    }
    return SizedBox(
      height: _barHeight,
      child: Row(children: children),
    );
  }
}

/// 기간 막대 한 칸.
class _Bar extends StatelessWidget {
  const _Bar({required this.segment});

  final BarSegment segment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = segment.entry;
    final outlined = e.isGhost || e is GoogleEventEntry;
    // 주 경계에서 잘린 쪽은 모서리를 각지게 — 이어진다는 걸 모양으로 말한다.
    final radius = BorderRadius.horizontal(
      left: Radius.circular(segment.continuesLeft ? 0 : 3),
      right: Radius.circular(segment.continuesRight ? 0 : 3),
    );

    return Container(
      key: ValueKey('calendar-bar-${e.entryKey}'),
      margin: const EdgeInsets.symmetric(horizontal: 1),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: outlined
            ? null
            : e.color.withValues(alpha: e.isDone ? 0.25 : 0.85),
        border: outlined
            ? Border.all(color: e.color.withValues(alpha: 0.7), width: 1)
            : null,
        borderRadius: radius,
      ),
      child: Text(
        // 이어져 온 막대는 제목을 다시 쓰지 않는다 — 같은 일이 매 주 반복해서
        // 이름표를 다는 것보다, 첫 주에 한 번 쓰고 이후는 색으로 잇는 게 읽기 쉽다.
        segment.continuesLeft ? '' : e.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 9,
          height: 1.1,
          fontWeight: FontWeight.w700,
          decoration: e.isDone ? TextDecoration.lineThrough : null,
          color: outlined
              ? theme.colorScheme.onSurface.withValues(alpha: 0.75)
              : Colors.white,
        ),
      ),
    );
  }
}
