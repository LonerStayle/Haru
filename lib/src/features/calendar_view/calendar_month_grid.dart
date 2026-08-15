import 'package:flutter/material.dart';

import '../../core/date_format.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import 'calendar_entry.dart';
import 'calendar_layout.dart';
import 'calendar_week_row.dart';

/// 월 달력 격자 — 요일 헤더 + 6주 행.
///
/// 행 수를 6으로 고정한 이유는 [calendarWeekRows] 참조. 각 행은 `Expanded` 라
/// 높이가 균일하고, 달을 넘겨도 격자 전체 높이가 변하지 않는다.
class CalendarMonthGrid extends StatelessWidget {
  const CalendarMonthGrid({
    super.key,
    required this.focusedMonth,
    required this.buckets,
    required this.today,
    required this.selectedDay,
    this.onSelectDay,
    this.onLongPressDay,
    this.dayCellBuilder,
  });

  /// 그릴 달 (그 달의 아무 날짜나 넣어도 된다).
  final DateTime focusedMonth;

  final Map<DateTime, List<CalendarEntry>> buckets;
  final DateTime today;
  final DateTime selectedDay;

  final void Function(DateTime date)? onSelectDay;
  final void Function(DateTime date)? onLongPressDay;
  final Widget Function(DateTime date, Widget cell)? dayCellBuilder;

  @override
  Widget build(BuildContext context) {
    final weeks = chunkIntoWeeks(monthGridDays(focusedMonth));
    final today0 = dateOnly(today);
    final selected0 = dateOnly(selectedDay);

    return Column(
      children: [
        _WeekdayHeader(days: weeks.first),
        const SizedBox(height: AppTokens.space4),
        Expanded(
          child: Column(
            children: [
              for (final week in weeks)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: CalendarWeekRow(
                      key: ValueKey('calendar-week-${week.first}'),
                      days: week,
                      buckets: buckets,
                      focusedMonth: focusedMonth,
                      today: today0,
                      selectedDay: selected0,
                      onSelectDay: onSelectDay,
                      onLongPressDay: onLongPressDay,
                      dayCellBuilder: dayCellBuilder,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader({required this.days});

  /// 첫 주의 7일 — 요일 라벨을 실제 날짜에서 뽑아 일요일 시작 규약과 어긋나지 않게 한다.
  final List<DateTime> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        for (final d in days)
          Expanded(
            child: Center(
              child: Text(
                KoDate.weekdayShort(d.weekday),
                style:
                    (AppPlatform.isMobile
                            ? theme.textTheme.labelSmall
                            : theme.textTheme.labelMedium)
                        ?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: switch (d.weekday) {
                            DateTime.sunday => const Color(0xFFE05252),
                            DateTime.saturday => const Color(0xFF3B7DD8),
                            _ => scheme.onSurface.withValues(alpha: 0.6),
                          },
                        ),
              ),
            ),
          ),
      ],
    );
  }
}
