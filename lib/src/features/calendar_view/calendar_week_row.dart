import 'package:flutter/material.dart';

import '../../core/platform.dart';
import 'calendar_day_cell.dart';
import 'calendar_entry.dart';
import 'calendar_layout.dart';

/// 기간 막대 한 줄의 높이와 줄 사이 간격.
///
/// 12/2 였을 때 막대들이 서로 달라붙어 보인다는 지적이 있었다 — 9pt 글자가 12px 안에
/// 꽉 차 위아래 여백이 없었던 탓이다. 높이와 간격을 함께 키워 줄을 눈으로 분리한다.
///
/// 모바일은 글자 없는 얇은 색 띠로 그린다. 모바일 주 행은 약 50dp 라 14px 막대를
/// 넣으면 레인 수가 0 으로 계산돼 여러 날 일정이 격자에서 통째로 사라졌다
/// (UX 감사 B5). 띠만 있어도 "며칠에 걸친 일정이 있다" 는 신호는 충분하고, 제목은
/// 아래 선택일 목록이 보여 준다.
double get _barHeight => AppPlatform.isMobile ? 5 : 16;
double get _barGap => AppPlatform.isMobile ? 2 : 3;

/// 막대 안에 제목을 쓸지 — 모바일 띠는 너무 얇아 글자를 넣지 않는다.
bool get _barShowsTitle => !AppPlatform.isMobile;

/// 날짜 숫자와 첫 막대 사이 여백.
double get _barsTopInset => AppPlatform.isMobile ? 3 : 5;

/// 마지막 막대와 그 아래 칩 사이 여백.
const double _barsBottomInset = 4;

/// 막대 레인 수의 절대 상한. 넘치는 막대는 셀의 "외 N건" 으로 합산한다.
///
/// 상한이 없으면 기간 항목이 겹칠 때 주 행 높이가 무한정 늘어나 달력이 스크롤된다.
/// 달력의 값은 "한 화면에서 한 달을 본다" 이므로 높이를 고정하는 쪽을 택했다.
int get _laneHardCap => AppPlatform.isMobile ? 2 : 3;

/// 막대에 자리를 내주고도 남겨야 하는 최소 칩 공간 (칩 한 줄).
///
/// 이게 없으면 좁은 창에서 막대 3줄이 칸을 통째로 먹어, 그날의 단일 항목이 하나도
/// 안 보이고 빗금만 뜬다 (기본 창 크기에서 실제로 그랬다).
///
/// 모바일 셀은 칩 대신 6px 점 한 줄을 그리므로 필요한 공간이 훨씬 작다.
double get _minChipRoom => AppPlatform.isMobile ? 8 : 20;

/// 주 행 높이 [rowHeight] 에서 실제로 쓸 수 있는 막대 레인 수.
///
/// 상한을 3으로 고정하지 않고 높이에서 역산하는 이유: 창 크기에 따라 한 행이
/// 75px 도 되고 160px 도 된다. 고정 상한은 좁은 창에서 반드시 넘친다.
int _laneCapacityFor(double rowHeight) {
  final content = rowHeight - calendarCellPadding * 2 - calendarDayNumberHeight;
  final forBars = content - _barsTopInset - _barsBottomInset - _minChipRoom;
  if (forBars < _barHeight) return 0;
  final fit = forBars ~/ (_barHeight + _barGap);
  return fit > _laneHardCap ? _laneHardCap : fit;
}

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
    this.onSecondaryTapDay,
    this.chipWrapper,
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

  /// 데스크탑 우클릭 — 칸 메뉴. [Offset] 은 전역 커서 위치.
  final void Function(DateTime date, Offset globalPosition)? onSecondaryTapDay;

  /// 데스크탑 칩 드래그 훅 — [CalendarDayCell.chipWrapper] 로 그대로 넘긴다.
  final Widget Function(CalendarEntry entry, Widget chip)? chipWrapper;

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

    // 몇 레인까지 그릴지는 이 행이 실제로 몇 픽셀인지 알아야 정할 수 있다.
    return LayoutBuilder(
      builder: (context, rowConstraints) {
        final maxLanes = _laneCapacityFor(rowConstraints.maxHeight);
        final visible = segments.where((s) => s.lane < maxLanes).toList();
        final laneCount = visible.isEmpty
            ? 0
            : visible.map((s) => s.lane).reduce((a, b) => a > b ? a : b) + 1;

        // 상한을 넘겨 안 그려진 막대는 걸친 날짜마다 "외 N건" 으로 합산한다.
        final hiddenByDate = <DateTime, int>{};
        for (final s in segments.where((s) => s.lane >= maxLanes)) {
          for (var c = s.startCol; c <= s.endCol; c++) {
            hiddenByDate.update(days[c], (v) => v + 1, ifAbsent: () => 1);
          }
        }

        // 칩이 시작할 y = 셀padding + 날짜숫자 + reservedTop. 막대는 그 사이
        // (오버레이)에 그려지므로 **막대가 쓰는 높이 + 위아래 여백**을 전부 반영한다.
        // 예전엔 여백(위 5 / 아래 4)을 빼먹어 마지막 막대가 첫 칩 위에 4px 겹쳤다.
        final reservedTop = laneCount == 0
            ? 0.0
            : _barsTopInset +
                  laneCount * (_barHeight + _barGap) +
                  _barsBottomInset;

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
                // 셀 안 Column 의 좌표계와 맞춘다 — 셀 padding + 날짜 숫자 아래.
                top:
                    calendarCellPadding +
                    calendarDayNumberHeight +
                    _barsTopInset,
                child: IgnorePointer(
                  child: Padding(
                    // 셀의 좌우 padding + 테두리만큼 안쪽으로 들여 막대가 칸 경계에
                    // 딱 붙지 않게 한다.
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      children: [
                        for (var lane = 0; lane < laneCount; lane++) ...[
                          _LaneRow(
                            segments: visible
                                .where((s) => s.lane == lane)
                                .toList(),
                          ),
                          SizedBox(height: _barGap),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
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
      onSecondaryTapUp: onSecondaryTapDay == null
          ? null
          : (d) => onSecondaryTapDay!(date, d.globalPosition),
      chipWrapper: chipWrapper,
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
      padding: EdgeInsets.symmetric(horizontal: _barShowsTitle ? 4 : 0),
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
      child: !_barShowsTitle
          ? null
          : Text(
              // 이어져 온 막대에도 제목을 다시 쓴다. 예전엔 "첫 주에 한 번 쓰고 이후는 색으로
              // 잇는다" 였는데, 실사용에서 둘째 주부터는 이름 없는 색 막대만 남아 무슨 일인지
              // 알 수 없었다. 이어짐 표시는 잘린 쪽 모서리를 각지게 그리는 것으로 충분하다.
              e.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                height: 1.15,
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
