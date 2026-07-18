import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/theme.dart';
import '../../domain/group.dart';
import '../../domain/todo.dart';
import '../../data/providers.dart';
import '../../ui/widgets/empty_state.dart';
import '../add_todo/add_todo_sheet.dart';
import '../category/categories_controller.dart';
import '../category/groups_controller.dart';
import '../outline/tree_providers.dart';
import '../todo_actions/todo_actions_controller.dart';

/// 타임라인 — **날짜(dueAt)가 지정된 미완료 task** 를 전역에서 날짜 버킷으로 모아 본다.
///
/// v1.5: '오늘' 이 오늘 날짜 항목만 보여 주게 바뀌면서, "언제 할지 정해 둔 모든 일" 을
/// 시간 흐름으로 한눈에 보는 화면이 필요해졌다. 버킷: 지남 / 오늘 / 내일 / 이번 주 / 이후.
/// 완료 항목은 제외(미완료만, 완료보기는 추후). 메모(note)는 dueAt 가 없어 자연히 제외된다.
class TimelineScreen extends ConsumerWidget {
  const TimelineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allTodos =
        ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
    final groups =
        ref.watch(activeGroupsProvider).asData?.value ?? const <Group>[];
    final now = ref.watch(nowProvider)();
    final groupLabelOf = {for (final g in groups) g.id: g.label};
    // 보관된 카테고리의 할 일은 타임라인에서 숨긴다 (보관 없음/로딩 = 필터 미적용).
    final archivedIds = ref.watch(archivedCategoryIdsProvider);

    // 날짜 지정 + 미완료 task 만 (+ 보관 카테고리 제외).
    final dated =
        allTodos
            .where(
              (t) =>
                  t.type == TodoType.task &&
                  t.dueAt != null &&
                  !t.isDone &&
                  !archivedIds.contains(t.category.id),
            )
            .toList()
          ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));

    final buckets = _bucketize(dated, now);

    void edit(Todo t) {
      AddTodoSheet.show(
        context,
        initialCategory: t.category,
        initialTodo: t,
        onSubmit: (_) {},
        onUpdate: (updated) => ref.read(todoActionsProvider).update(updated),
      );
    }

    return CustomScrollView(
      slivers: [
        const SliverPadding(
          padding: EdgeInsets.fromLTRB(
            AppTokens.space24,
            AppTokens.space32,
            AppTokens.space24,
            AppTokens.space12,
          ),
          sliver: SliverToBoxAdapter(child: _Header()),
        ),
        if (dated.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.calendar_month_outlined,
              title: '날짜가 정해진 할 일이 없어요',
              subtitle: '할 일에 날짜를 지정하면 여기 타임라인에 모여요.',
            ),
          )
        else
          for (final bucket in buckets)
            if (bucket.items.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.space24,
                  AppTokens.space16,
                  AppTokens.space24,
                  AppTokens.space8,
                ),
                sliver: SliverToBoxAdapter(
                  child: _BucketHeader(
                    label: bucket.label,
                    count: bucket.items.length,
                    accent: bucket.accent,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.space24,
                ),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((context, i) {
                    final t = bucket.items[i];
                    return Padding(
                      key: ValueKey('timeline-tile-${t.id}'),
                      padding: const EdgeInsets.only(bottom: AppTokens.space8),
                      child: _TimelineTile(
                        todo: t,
                        groupLabel: t.category.groupId == null
                            ? null
                            : groupLabelOf[t.category.groupId],
                        overdue: bucket.kind == _BucketKind.overdue,
                        onToggle: () => ref.read(todoActionsProvider).toggle(t),
                        onTap: () => edit(t),
                      ),
                    );
                  }, childCount: bucket.items.length),
                ),
              ),
            ],
        const SliverToBoxAdapter(child: SizedBox(height: AppTokens.space48)),
      ],
    );
  }

  /// 날짜순 정렬된 [dated] 를 버킷으로 분배. 입력이 정렬돼 있으므로 각 버킷도 정렬 유지.
  static List<_Bucket> _bucketize(List<Todo> dated, DateTime now) {
    final today0 = DateTime(now.year, now.month, now.day);
    final tomorrow0 = today0.add(const Duration(days: 1));
    final dayAfter0 = today0.add(const Duration(days: 2));
    // 이번 주 끝(다음 월요일 0시, 배타적). weekday: 월=1 … 일=7.
    final weekEndExclusive = today0.add(Duration(days: 8 - now.weekday));

    final overdue = <Todo>[];
    final today = <Todo>[];
    final tomorrow = <Todo>[];
    final thisWeek = <Todo>[];
    final later = <Todo>[];

    for (final t in dated) {
      final due = t.dueAt!.toLocal();
      final d = DateTime(due.year, due.month, due.day);
      if (d.isBefore(today0)) {
        overdue.add(t);
      } else if (d.isBefore(tomorrow0)) {
        today.add(t);
      } else if (d.isBefore(dayAfter0)) {
        tomorrow.add(t);
      } else if (d.isBefore(weekEndExclusive)) {
        thisWeek.add(t);
      } else {
        later.add(t);
      }
    }

    return [
      _Bucket(_BucketKind.overdue, '지난 일정', const Color(0xFFEF4444), overdue),
      _Bucket(_BucketKind.today, '오늘', AppPalette.accent, today),
      _Bucket(_BucketKind.tomorrow, '내일', const Color(0xFF8B5CF6), tomorrow),
      _Bucket(_BucketKind.thisWeek, '이번 주', const Color(0xFF10B981), thisWeek),
      _Bucket(_BucketKind.later, '이후', const Color(0xFF5A6273), later),
    ];
  }
}

enum _BucketKind { overdue, today, tomorrow, thisWeek, later }

class _Bucket {
  const _Bucket(this.kind, this.label, this.accent, this.items);
  final _BucketKind kind;
  final String label;
  final Color accent;
  final List<Todo> items;
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '타임라인',
          style: theme.textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: AppTokens.space4),
        Text('날짜가 정해진 할 일을 한눈에', style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

class _BucketHeader extends StatelessWidget {
  const _BucketHeader({
    required this.label,
    required this.count,
    required this.accent,
  });

  final String label;
  final int count;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(AppTokens.radiusFull),
          ),
        ),
        const SizedBox(width: AppTokens.space8),
        Text(
          label,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(width: AppTokens.space8),
        Text(
          '$count',
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurface.withValues(alpha: 0.5),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// 타임라인 한 줄 — 체크 + 제목 + 카테고리·그룹 + 날짜 라벨.
class _TimelineTile extends StatelessWidget {
  const _TimelineTile({
    required this.todo,
    required this.groupLabel,
    required this.overdue,
    required this.onToggle,
    required this.onTap,
  });

  final Todo todo;
  final String? groupLabel;
  final bool overdue;
  final VoidCallback onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = todo.category.color;
    final dateLabel = TodoDateLabel.format(todo);

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space12,
            vertical: AppTokens.space12,
          ),
          child: Row(
            children: [
              // 원형 체크 — 탭 시 완료(목록에서 사라짐).
              InkWell(
                key: ValueKey('timeline-check-${todo.id}'),
                onTap: onToggle,
                customBorder: const CircleBorder(),
                child: Padding(
                  padding: const EdgeInsets.all(AppTokens.space4),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.outline, width: 2),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppTokens.space12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      todo.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppTokens.space4),
                    Row(
                      children: [
                        Icon(todo.category.icon, size: 13, color: color),
                        const SizedBox(width: AppTokens.space4),
                        Flexible(
                          child: Text(
                            groupLabel == null
                                ? todo.category.label
                                : '$groupLabel - ${todo.category.label}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurface.withValues(alpha: 0.65),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (dateLabel != null) ...[
                const SizedBox(width: AppTokens.space8),
                Text(
                  dateLabel,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: overdue
                        ? const Color(0xFFEF4444)
                        : scheme.onSurface.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
