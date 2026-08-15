import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/empty_state.dart';
import '../todo_actions/todo_actions_controller.dart';
import 'calendar_actions.dart';
import 'calendar_entry.dart';

/// 선택된 날짜의 할 일 목록.
///
/// 달력 격자는 "언제 무엇이 있는지" 를, 이 패널은 "그날 정확히 무엇을 하는지" 를
/// 맡는다. 달력 칸이 상한(칩 3 / 점 4) 때문에 전부 못 보여주므로 이 패널이 그
/// 전체를 책임진다.
class CalendarDayPanel extends ConsumerWidget {
  const CalendarDayPanel({
    super.key,
    required this.date,
    required this.entries,
    this.entryWrapper,
  });

  final DateTime date;

  /// 그날의 엔트리 (기간 항목 포함, `compareEntries` 순서).
  final List<CalendarEntry> entries;

  /// 타일을 감싸 드래그 소스로 만들기 위한 훅 (T13 에서 사용).
  final Widget Function(CalendarEntry entry, Widget tile)? entryWrapper;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final compact = AppPlatform.isMobile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            AppTokens.space16,
            compact ? AppTokens.space8 : AppTokens.space16,
            AppTokens.space8,
            AppTokens.space8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  KoDate.dayWithWeekday(date),
                  key: const ValueKey('calendar-panel-header'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (entries.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: AppTokens.space8),
                  child: Text(
                    '${entries.length}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              TextButton.icon(
                key: const ValueKey('calendar-add-on-day'),
                onPressed: () => openAddTodoOnDate(context, ref, date),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('이 날짜로 추가'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              // 패널이 아주 낮아질 수 있다 (모바일에서 달력을 펼친 상태 / 좁은 창).
              // 그 높이에서도 빈 상태가 잘리지 않도록 스크롤 가능하게 감싼다 —
              // 공간이 남을 땐 minHeight 로 여전히 가운데 정렬된다.
              ? LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: const EmptyState(
                        icon: Icons.event_available_outlined,
                        title: '이 날은 비어 있습니다',
                        subtitle: '＋ 이 날짜로 추가 를 누르거나, 아래 서랍에서 끌어다 놓으세요',
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.space12,
                    0,
                    AppTokens.space12,
                    AppTokens.space24,
                  ),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppTokens.space4),
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    final tile = CalendarEntryTile(entry: e, onDate: date);
                    return entryWrapper?.call(e, tile) ?? tile;
                  },
                ),
        ),
      ],
    );
  }
}

/// 선택일 목록의 한 줄.
///
/// 세 종류를 한 위젯이 그린다 —
/// - 실제 Todo: 체크 + 제목 + 날짜 라벨. 탭하면 편집 시트 (닫으면 저장).
/// - 미래 반복 고스트: 테두리만. 체크·탭하면 그 회차를 실체화한 뒤 같은 동작.
/// - 구글 이벤트: 체크 없음, 탭해도 아무 일 없음 (읽기 전용).
class CalendarEntryTile extends ConsumerWidget {
  const CalendarEntryTile({
    super.key,
    required this.entry,
    required this.onDate,
  });

  final CalendarEntry entry;

  /// 이 타일이 놓인 날짜 — 기간 항목이 여러 날에 걸릴 때 어느 칸에서 봤는지.
  final DateTime onDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = AppPlatform.isMobile;
    final isEvent = entry is GoogleEventEntry;
    final outlined = entry.isGhost || isEvent;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('calendar-panel-tile-${entry.entryKey}'),
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        onTap: isEvent ? null : () => _openEdit(context, ref),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: AppTokens.space8,
            vertical: compact ? AppTokens.space4 : AppTokens.space8,
          ),
          decoration: BoxDecoration(
            color: outlined ? null : scheme.surface,
            border: Border.all(
              color: outlined
                  ? entry.color.withValues(alpha: 0.45)
                  : scheme.outlineVariant.withValues(alpha: 0.6),
              width: AppTokens.hairline,
            ),
            borderRadius: BorderRadius.circular(AppTokens.radiusM),
          ),
          child: Row(
            children: [
              Container(
                width: 4,
                height: compact ? 22 : 26,
                decoration: BoxDecoration(
                  color: entry.color.withValues(alpha: entry.isDone ? 0.35 : 1),
                  borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                ),
              ),
              const SizedBox(width: AppTokens.space8),
              if (!isEvent) _CheckDot(entry: entry),
              if (isEvent)
                Padding(
                  padding: const EdgeInsets.only(right: AppTokens.space8),
                  child: Icon(
                    Icons.event_outlined,
                    size: 16,
                    color: scheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: compact ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        decoration: entry.isDone
                            ? TextDecoration.lineThrough
                            : null,
                        color: scheme.onSurface.withValues(
                          alpha: entry.isDone ? 0.45 : 1,
                        ),
                      ),
                    ),
                    if (_subtitle() != null)
                      Text(
                        _subtitle()!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 날짜/시각 보조 라벨. 종일이면 시각을 아예 만들지 않는다 (`00:00` 금지 규칙).
  String? _subtitle() {
    final parts = <String>[];
    if (entry.isGhost) parts.add('예정');
    if (entry is GoogleEventEntry) parts.add('Google');

    final e = entry;
    if (e is TodoEntry) {
      final label = TodoDateLabel.format(e.todo);
      if (label != null) parts.add(label);
    } else if (!entry.isAllDay && entry.timeAnchorAt != null) {
      parts.add(KoDate.time(entry.timeAnchorAt!));
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Future<void> _openEdit(BuildContext context, WidgetRef ref) async {
    final todo = await resolveEntryTodo(ref, entry);
    if (todo == null || !context.mounted) return;
    openCalendarEditSheet(context, ref, todo);
  }
}

/// 체크 원. 고스트면 누르는 순간 실체화한 뒤 체크한다.
class _CheckDot extends ConsumerWidget {
  const _CheckDot({required this.entry});

  final CalendarEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = entry;
    // 메모(note) 는 체크 개념이 없다 — 글리프로 대체해 타입을 구분한다.
    final isNote = e is TodoEntry && e.todo.type == TodoType.note;

    if (isNote) {
      return Padding(
        padding: const EdgeInsets.only(right: AppTokens.space8),
        child: Icon(
          Icons.sticky_note_2_outlined,
          size: 16,
          color: entry.color.withValues(alpha: 0.8),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(right: AppTokens.space8),
      child: InkWell(
        key: ValueKey('calendar-panel-check-${entry.entryKey}'),
        customBorder: const CircleBorder(),
        onTap: () async {
          final todo = await resolveEntryTodo(ref, entry);
          if (todo == null) return;
          await ref.read(todoActionsProvider).toggle(todo);
        },
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: entry.isDone ? entry.color : null,
            border: Border.all(
              color: entry.color.withValues(alpha: entry.isGhost ? 0.5 : 0.8),
              width: 1.5,
            ),
          ),
          child: entry.isDone
              ? const Icon(Icons.check, size: 13, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}
