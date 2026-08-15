import 'package:flutter/material.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import 'calendar_entry.dart';

/// 날짜 셀 key 규약 — `calendar-cell-20260815`.
String calendarDateKey(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y$m$d';
}

/// 셀 안에 세울 수 있는 칩/점의 상한.
///
/// 데스크탑은 칸이 넓어 제목을 읽을 수 있으니 칩 3개, 모바일은 좁아서 점 4개로
/// 압축한다 — "기능은 양쪽 parity, 폭·줄 수·터치 타겟만 모바일 압축" 규칙.
///
/// 데스크탑에서 이 값은 **상한일 뿐 실제 표시 수가 아니다**. 기간 막대가 몇 레인
/// 깔렸느냐([CalendarDayCell.reservedTop])에 따라 칩이 쓸 수 있는 높이가 매 칸
/// 달라지므로, 실제 개수는 [_chipCapacityFor] 가 남은 높이에서 계산한다.
int get calendarCellItemCap => AppPlatform.isMobile ? 4 : 3;

/// 셀 안쪽 padding.
///
/// 기간 막대 오버레이(주 행)가 셀 바깥에서 그려지므로, 막대의 세로 위치를 맞추려면
/// 그쪽에서도 이 값을 알아야 한다 — 그래서 상수를 여기 한 곳에 두고 공유한다.
double get calendarCellPadding => AppPlatform.isMobile ? 2 : AppTokens.space4;

/// 날짜 숫자 줄의 높이.
double get calendarDayNumberHeight => AppPlatform.isMobile ? 20 : 22;

/// 칩 한 줄이 차지하는 높이 (칩 16 + 아래 간격 2).
const double _chipRowHeight = 18;

/// "외 N건" 한 줄의 높이.
const double _moreRowHeight = 14;

/// 남은 높이 [available] 에 실제로 세울 수 있는 칩 수.
///
/// 예전에는 칩 수를 3으로 고정했는데, 기간 막대가 깔린 칸은 그만큼 높이가 줄어드는데도
/// 칩은 그대로 3개를 세워서 세로 오버플로가 났다(노란 빗금). 그래서 상한은 유지하되
/// **남은 높이에서 들어갈 만큼만** 세우고 나머지는 "외 N건" 으로 접는다.
///
/// [needsMoreRow] 가 true 면 마지막 한 줄을 "외 N건" 에 내준다.
int _chipCapacityFor(double available, {required bool needsMoreRow}) {
  final usable = needsMoreRow ? available - _moreRowHeight : available;
  if (usable < _chipRowHeight) return 0;
  final fit = usable ~/ _chipRowHeight;
  return fit > calendarCellItemCap ? calendarCellItemCap : fit;
}

/// 월 그리드의 날짜 한 칸.
///
/// 기간 막대는 여러 칸에 걸쳐야 해서 이 위젯이 아니라 주 행이 오버레이로 그린다.
/// 셀은 그 자리만큼 [reservedTop] 을 비워둔다 — 그래야 막대와 칩이 겹치지 않는다.
class CalendarDayCell extends StatelessWidget {
  const CalendarDayCell({
    super.key,
    required this.date,
    required this.singleDayEntries,
    required this.hiddenBarCount,
    required this.reservedTop,
    required this.isToday,
    required this.isSelected,
    required this.isOutsideMonth,
    this.onTap,
    this.onLongPress,
    this.isDropTarget = false,
  });

  final DateTime date;

  /// 이 칸에 칩/점으로 그릴 **단일 날짜** 엔트리 (정렬 완료 상태).
  final List<CalendarEntry> singleDayEntries;

  /// 레인 상한을 넘겨 이 칸에서 잘린 기간 막대 수 — "외 N건" 에 합산한다.
  final int hiddenBarCount;

  /// 기간 막대 오버레이가 차지하는 상단 높이.
  final double reservedTop;

  final bool isToday;
  final bool isSelected;

  /// 이전/다음 달의 넘침 날짜인가. 흐리게 그리되 탭하면 그 달로 이동한다.
  final bool isOutsideMonth;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 드래그 중인 항목이 이 칸 위에 있는가 (드롭 하이라이트).
  final bool isDropTarget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = AppPlatform.isMobile;

    return Semantics(
      selected: isSelected,
      button: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isDropTarget
                ? AppPalette.accent.withValues(alpha: 0.12)
                : isSelected
                ? scheme.surfaceContainerHighest.withValues(alpha: 0.55)
                : null,
            border: Border.all(
              // 선택 표시는 테두리, 오늘 표시는 날짜 숫자 원 — 둘이 동시에 보여야 한다.
              color: isSelected
                  ? AppPalette.accent
                  : scheme.outlineVariant.withValues(alpha: 0.5),
              width: isSelected ? 1.5 : AppTokens.hairline,
            ),
            borderRadius: BorderRadius.circular(AppTokens.radiusS),
          ),
          child: Padding(
            padding: EdgeInsets.all(calendarCellPadding),
            child: LayoutBuilder(
              builder: (context, cell) {
                // 창이 낮으면 막대 레인이 꽉 찬 칸에서 예약 높이가 칸 자체를 넘길 수
                // 있다(막대 3줄 + 낮은 주 행). 그때는 예약을 칸 안으로 눌러 넣는다 —
                // 넘기면 칸 전체가 빗금이 되어 날짜조차 안 보인다.
                final room = cell.maxHeight - calendarDayNumberHeight;
                final reserved = room <= 0
                    ? 0.0
                    : (reservedTop > room ? room : reservedTop);

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DayNumber(
                      date: date,
                      isToday: isToday,
                      isOutsideMonth: isOutsideMonth,
                      compact: compact,
                    ),
                    SizedBox(height: reserved),
                    // 남은 높이는 기간 막대 레인 수에 따라 칸마다 다르다. 그래서 몇
                    // 개를 세울지는 여기서(실측 높이) 정한다. ClipRect 는 1px 반올림
                    // 오차로 빗금이 뜨지 않게 하는 안전망.
                    Expanded(
                      child: ClipRect(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final total =
                                singleDayEntries.length + hiddenBarCount;
                            final available = constraints.maxHeight;

                            // 모바일은 점이라 한 줄이면 충분 — 상한만 쓴다.
                            if (compact) {
                              final shown = singleDayEntries
                                  .take(calendarCellItemCap)
                                  .toList();
                              return _DotRow(
                                entries: shown,
                                overflow: total - shown.length,
                              );
                            }

                            // 전부 들어가는지 먼저 보고, 안 되면 "외 N건" 줄을 빼고
                            // 다시 센다.
                            var capacity = _chipCapacityFor(
                              available,
                              needsMoreRow: false,
                            );
                            if (hiddenBarCount > 0 ||
                                singleDayEntries.length > capacity) {
                              capacity = _chipCapacityFor(
                                available,
                                needsMoreRow: true,
                              );
                            }

                            final shown = singleDayEntries
                                .take(capacity)
                                .toList();
                            return _ChipColumn(
                              date: date,
                              entries: shown,
                              overflow: total - shown.length,
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _DayNumber extends StatelessWidget {
  const _DayNumber({
    required this.date,
    required this.isToday,
    required this.isOutsideMonth,
    required this.compact,
  });

  final DateTime date;
  final bool isToday;
  final bool isOutsideMonth;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = compact ? 20.0 : 22.0;

    final baseStyle = (compact
        ? theme.textTheme.labelSmall
        : theme.textTheme.labelMedium);
    final color = isToday
        ? Colors.white
        : isOutsideMonth
        ? scheme.onSurface.withValues(alpha: 0.32)
        : _weekendColor(date, scheme);

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: isToday
            ? const BoxDecoration(
                color: AppPalette.accent,
                shape: BoxShape.circle,
              )
            : null,
        child: Text(
          '${date.day}',
          style: baseStyle?.copyWith(
            color: color,
            fontWeight: isToday ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    );
  }

  /// 주말은 살짝 다른 색 — 달력에서 주 경계를 눈으로 잡는 가장 싼 단서.
  static Color _weekendColor(DateTime d, ColorScheme scheme) {
    if (d.weekday == DateTime.sunday) return const Color(0xFFE05252);
    if (d.weekday == DateTime.saturday) return const Color(0xFF3B7DD8);
    return scheme.onSurface;
  }
}

/// 데스크탑 — 카테고리 색 좌측 바 + 제목 칩.
class _ChipColumn extends StatelessWidget {
  const _ChipColumn({
    required this.date,
    required this.entries,
    required this.overflow,
  });

  final DateTime date;
  final List<CalendarEntry> entries;
  final int overflow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      // 남은 높이를 다 채우려 들지 않게 — 높이 계산은 호출측이 이미 끝냈다.
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in entries) ...[
          CalendarEntryChip(entry: e),
          const SizedBox(height: 2),
        ],
        if (overflow > 0)
          SizedBox(
            // 높이를 고정해야 호출측의 용량 계산(_moreRowHeight)과 어긋나지 않는다.
            height: _moreRowHeight,
            child: Padding(
              key: ValueKey('calendar-more-${calendarDateKey(date)}'),
              padding: const EdgeInsets.only(left: 2),
              child: Text(
                '외 $overflow건',
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  height: 1.2,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 모바일 — 카테고리 색 점.
class _DotRow extends StatelessWidget {
  const _DotRow({required this.entries, required this.overflow});

  final List<CalendarEntry> entries;
  final int overflow;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Wrap(
        spacing: 3,
        runSpacing: 3,
        children: [
          for (final e in entries)
            CalendarEntryDot(
              key: ValueKey('calendar-dot-${e.entryKey}'),
              entry: e,
            ),
          // 넘친 건수는 점 하나를 더 찍는 대신 작은 '+' 로 — 개수를 세는 게 아니라
          // "더 있다" 만 알리면 되고, 좁은 칸에서 숫자는 읽히지 않는다.
          if (overflow > 0)
            Icon(
              Icons.add,
              size: 8,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
        ],
      ),
    );
  }
}

/// 단일 날짜 엔트리의 칩 표현 (데스크탑 셀 / 선택일 패널 공용).
class CalendarEntryChip extends StatelessWidget {
  const CalendarEntryChip({super.key, required this.entry});

  final CalendarEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ghostOrEvent = entry.isGhost || entry is GoogleEventEntry;

    return Container(
      key: ValueKey('calendar-chip-${entry.entryKey}'),
      height: 16,
      padding: const EdgeInsets.only(right: 3),
      decoration: BoxDecoration(
        // 실체가 있는 항목만 채운다. 고스트(미래 반복 예정)와 구글 이벤트는
        // 테두리만 — "여기 있지만 내 데이터로 확정된 건 아니다" 를 한눈에.
        color: ghostOrEvent
            ? null
            : entry.color.withValues(alpha: entry.isDone ? 0.08 : 0.16),
        border: ghostOrEvent
            ? Border.all(
                color: entry.color.withValues(alpha: 0.6),
                width: AppTokens.hairline,
              )
            : null,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: entry.color.withValues(alpha: entry.isDone ? 0.4 : 1),
              borderRadius: BorderRadius.circular(AppTokens.radiusFull),
            ),
          ),
          const SizedBox(width: 3),
          Expanded(
            child: Text(
              entry.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10,
                height: 1.1,
                fontWeight: FontWeight.w600,
                decoration: entry.isDone ? TextDecoration.lineThrough : null,
                color: scheme.onSurface.withValues(
                  alpha: entry.isDone ? 0.45 : 0.9,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 모바일 셀의 점 표현.
class CalendarEntryDot extends StatelessWidget {
  const CalendarEntryDot({super.key, required this.entry});

  final CalendarEntry entry;

  @override
  Widget build(BuildContext context) {
    final ghostOrEvent = entry.isGhost || entry is GoogleEventEntry;
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ghostOrEvent
            ? null
            : entry.color.withValues(alpha: entry.isDone ? 0.35 : 1),
        border: ghostOrEvent
            ? Border.all(color: entry.color.withValues(alpha: 0.75), width: 1)
            : null,
      ),
    );
  }
}
