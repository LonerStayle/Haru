import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../domain/policies/carryover_policy.dart';
import '../../domain/policies/recurrence_dedup_policy.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/skeleton.dart';
import '../../ui/widgets/today_progress_summary.dart';
import '../../ui/widgets/todo_category_sections.dart';
import '../../ui/widgets/undo_snackbar.dart';
import '../add_todo/add_todo_controller.dart';
import '../add_todo/add_todo_sheet.dart';
import '../category/categories_controller.dart';
import '../category/groups_controller.dart';
import '../outline/tree_providers.dart';
import '../recurrence/recurrence_actions.dart';
import '../recurrence/recurrence_manage_screen.dart';
import '../todo_actions/todo_actions_controller.dart';
import '../todo_detail/todo_detail_screen.dart';
import 'today_providers.dart';

/// 오늘 화면 — 헤더 + 이월 배너 + visible todos 리스트.
///
/// [group] 이 non-null 이면 그 그룹에 속한 카테고리의 오늘 할 일만 보여 준다 (A안 —
/// 그룹별 '오늘' 탭). null 이면 전역 오늘. [showHeader] 가 false 면 큰 '오늘' 헤더를
/// 숨긴다 (그룹 화면 탭으로 임베드될 때 — 탭 라벨이 제목을 대신한다).
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, this.group, this.showHeader = true});

  /// non-null = 이 그룹 카테고리만 필터. null = 전역.
  final Group? group;

  /// 큰 '오늘' 헤더 표시 여부.
  final bool showHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 보관 카테고리 제외된 오늘 목록 (visibleTodayTodosProvider). 원본 stream 은
    // 순수 유지하고 파생 필터만 적용 — 보관/복원 시 즉시 반영.
    final asyncTodos = ref.watch(visibleTodayTodosProvider);
    // date-repeat — 반복 인스턴스 자동 생성 트리거 활성화(앱시작·자정). 이 화면이
    // 떠 있는 동안 마스터의 누락 발생분이 채워진다.
    ref.watch(recurrenceMaterializerProvider);
    final globalCarryover = ref.watch(carryoverCountProvider);
    final allTodos = ref.watch(allTodosProvider).asData?.value ?? const [];
    final groups =
        ref.watch(activeGroupsProvider).asData?.value ?? const <Group>[];
    final now = ref.watch(nowProvider)();

    // 그룹 필터 — 이 그룹에 속한 카테고리 id 집합 (null = 전역, 필터 없음).
    Set<String>? groupCategoryIds;
    if (group != null) {
      final categories =
          ref.watch(activeCategoriesProvider).asData?.value ??
          const <Category>[];
      groupCategoryIds = categories
          .where((c) => c.groupId == group!.id)
          .map((c) => c.id)
          .toSet();
    }

    return asyncTodos.when(
      loading: () => const TodoListSkeleton(),
      error: (e, _) => _Error(message: '$e'),
      data: (allTodayRaw) {
        // date-repeat (FR-4) — 같은 반복 미체크 누적은 leader 1건으로 접고 나머지는
        // 묶음 배지로. 데이터는 보존(표시 레이어 변환).
        final deduped = RecurrenceDedupPolicy.dedupe(allTodayRaw);
        final allToday = deduped.visible;
        final hiddenCountBySeries = deduped.hiddenCountBySeries;
        final todos = groupCategoryIds == null
            ? allToday
            : allToday
                  .where((t) => groupCategoryIds!.contains(t.category.id))
                  .toList();
        // 그룹 화면에선 이월 배너도 그 그룹 범위로 재계산 (전역 카운트는 오해 유발).
        final carryoverCount = groupCategoryIds == null
            ? globalCarryover
            : todos
                  .where((t) => CarryoverPolicy.shouldCarryOverToday(t, now))
                  .length;
        // 상단 진척 요약 — 오늘 task(메모 제외) 완료/전체.
        final tasks = todos.where((t) => t.type == TodoType.task);
        final doneCount = tasks.where((t) => t.isDone).length;
        final totalCount = tasks.length;
        return _Loaded(
          todos: todos,
          allTodos: allTodos,
          groups: groups,
          hiddenCountBySeries: hiddenCountBySeries,
          // 그룹 탭(group != null) 안에서는 그룹 라벨이 중복이라 숨긴다.
          showGroupLabel: group == null,
          doneCount: doneCount,
          totalCount: totalCount,
          carryoverCount: carryoverCount,
          showHeader: showHeader,
          now: now,
          onToggle: (t) => ref.read(todoActionsProvider).toggle(t),
          onDelete: (t) async {
            final actions = ref.read(todoActionsProvider);
            await actions.delete(t);
            if (!context.mounted) return;
            showUndoSnackbar(
              context,
              message: '"${t.title}" 삭제됨',
              onUndo: () => actions.restore(t),
            );
          },
          // 기능 M — leaf tap → AddTodoSheet edit 모드 진입.
          onEdit: (t) async {
            await AddTodoSheet.show(
              context,
              initialCategory: t.category,
              initialTodo: t,
              onSubmit: (_) {}, // edit 모드에선 호출 안 됨.
              onUpdate: (updated) {
                ref.read(todoActionsProvider).update(updated);
              },
            );
          },
          // 기능 M — 하위 있는 root tap → 상세 화면(드릴다운) push.
          onDrillDown: (folder) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => TodoDetailScreen(parent: folder),
            ),
          ),
          // Task C — ＋ 하위 추가.
          onAddChild: (parent) =>
              showAddChildSheet(context, ref, parent: parent),
          onCopy: (t) => showCopyTodoSheet(context, ref, original: t),
          // Task B — 형제 드래그 재정렬.
          onReorderSiblings: (siblings, oldIndex, newIndex) => ref
              .read(todoActionsProvider)
              .reorderSiblings(siblings, oldIndex, newIndex),
          // date-repeat — ⋮ '반복 중지' → 시리즈 마스터 삭제(비파괴적).
          onStopRecurrence: (t) => confirmStopRecurrence(context, ref, t),
        );
      },
    );
  }
}

class _Loaded extends StatefulWidget {
  const _Loaded({
    required this.todos,
    required this.allTodos,
    required this.groups,
    required this.hiddenCountBySeries,
    required this.showGroupLabel,
    required this.doneCount,
    required this.totalCount,
    required this.carryoverCount,
    required this.showHeader,
    required this.now,
    required this.onToggle,
    required this.onDelete,
    required this.onEdit,
    required this.onDrillDown,
    required this.onAddChild,
    required this.onCopy,
    required this.onReorderSiblings,
    required this.onStopRecurrence,
  });

  /// 오늘 화면에서 root 로 보일 todo (visibility/carryover 정책 적용된 visible set).
  /// 자식은 인라인으로 펼치지 않고 드릴다운 상세 화면에서 본다.
  final List<Todo> todos;
  final List<Todo> allTodos;

  /// 카테고리 섹션 헤더의 그룹 라벨 출력용.
  final List<Group> groups;

  /// date-repeat (FR-4) — seriesId → 숨겨진 미체크 건수 (leader 묶음 배지용).
  final Map<String, int> hiddenCountBySeries;

  /// 그룹 탭 안에서는 그룹 라벨이 중복이라 false.
  final bool showGroupLabel;

  /// 상단 진척 요약 — 오늘 task 완료/전체.
  final int doneCount;
  final int totalCount;
  final int carryoverCount;

  /// 큰 '오늘' 헤더 표시 여부 (그룹 탭 임베드 시 false).
  final bool showHeader;
  final DateTime now;
  final void Function(Todo) onToggle;
  final void Function(Todo) onDelete;
  final void Function(Todo) onEdit;
  final void Function(Todo) onDrillDown;
  final void Function(Todo) onAddChild;
  final void Function(Todo) onCopy;
  final void Function(List<Todo> siblings, int oldIndex, int newIndex)
  onReorderSiblings;

  /// date-repeat (FR-6) — ⋮ '반복 중지' 콜백.
  final void Function(Todo) onStopRecurrence;

  @override
  State<_Loaded> createState() => _LoadedState();
}

class _LoadedState extends State<_Loaded> {
  /// 오늘 화면 root 후보: visible todo 중 그 부모도 visible 인 항목은 자식으로만 보여야
  /// 중복되지 않는다. 부모가 today set 에 있으면 그 부모 아래 자식으로 자연 렌더되므로
  /// root 목록에서 제외. (부모가 today 가 아니면 이 visible 자식이 root 로 올라온다.)
  List<Todo> get _roots {
    final visibleIds = widget.todos.map((t) => t.id).toSet();
    return widget.todos
        .where((t) => t.parentId == null || !visibleIds.contains(t.parentId))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final roots = _roots;
    return CustomScrollView(
      slivers: [
        if (widget.showHeader)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.space24,
              AppTokens.space32,
              AppTokens.space24,
              AppTokens.space12,
            ),
            sliver: SliverToBoxAdapter(child: _Header(now: widget.now)),
          )
        else
          const SliverToBoxAdapter(child: SizedBox(height: AppTokens.space16)),
        // 상단 진척 요약 — 오늘 task 가 1개 이상일 때만.
        if (widget.totalCount > 0)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.space24,
              0,
              AppTokens.space24,
              AppTokens.space8,
            ),
            sliver: SliverToBoxAdapter(
              child: TodayProgressSummary(
                done: widget.doneCount,
                total: widget.totalCount,
              ),
            ),
          ),
        if (widget.carryoverCount > 0)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.space24,
              AppTokens.space8,
              AppTokens.space24,
              0,
            ),
            sliver: SliverToBoxAdapter(
              child: _CarryoverBanner(count: widget.carryoverCount),
            ),
          ),
        if (widget.todos.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.check_circle_outline_rounded,
              title: '오늘 할 일이 없어요',
              subtitle: 'Cmd+N 으로 빠르게 추가해보세요.',
            ),
          )
        else ...[
          ...todayCategorySectionSlivers(
            roots: roots,
            allTodos: widget.allTodos,
            groups: widget.groups,
            showGroupLabel: widget.showGroupLabel,
            onToggle: widget.onToggle,
            onDelete: widget.onDelete,
            onEdit: widget.onEdit,
            onDrillDown: widget.onDrillDown,
            onAddChild: widget.onAddChild,
            onCopy: widget.onCopy,
            onReorderSiblings: widget.onReorderSiblings,
            hiddenCountBySeries: widget.hiddenCountBySeries,
            onStopRecurrence: widget.onStopRecurrence,
          ),
          const SliverToBoxAdapter(child: SizedBox(height: AppTokens.space48)),
        ],
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.now});

  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pendingCount = ref.watch(outboxCountProvider).value ?? 0;
    // date-repeat — 반복 마스터가 있으면 "반복 관리" 진입 버튼 노출(FR-6).
    final hasRecurring = ref.watch(recurringMastersProvider).isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '오늘',
              style: theme.textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const Spacer(),
            if (pendingCount > 0)
              _SyncPendingChip(count: pendingCount, theme: theme),
            if (hasRecurring)
              IconButton(
                key: const ValueKey('home-recurrence-manage'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const RecurrenceManageScreen(),
                  ),
                ),
                icon: const Icon(Icons.repeat_rounded),
                iconSize: 20,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                tooltip: '반복 관리',
              ),
          ],
        ),
        const SizedBox(height: AppTokens.space4),
        Text(KoDate.pretty(now), style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

class _SyncPendingChip extends StatelessWidget {
  const _SyncPendingChip({required this.count, required this.theme});

  final int count;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Container(
      key: const ValueKey('sync-pending-chip'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space12,
        vertical: AppTokens.space4,
      ),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_sync_outlined,
            size: 14,
            color: scheme.onTertiaryContainer,
          ),
          const SizedBox(width: AppTokens.space4),
          Text(
            '동기화 대기 $count건',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onTertiaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _CarryoverBanner extends StatelessWidget {
  const _CarryoverBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 다크 모드에서 alpha 0.08 은 거의 안 보여 가독성이 떨어진다. 다크에서 대비 강화.
    final isDark = theme.brightness == Brightness.dark;
    final bgAlpha = isDark ? 0.18 : 0.08;
    final borderAlpha = isDark ? 0.40 : 0.20;
    return Container(
      key: const ValueKey('carryover-banner'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space16,
        vertical: AppTokens.space12,
      ),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: bgAlpha),
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        border: Border.all(
          color: scheme.primary.withValues(alpha: borderAlpha),
          width: AppTokens.hairline,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.history_toggle_off_outlined,
            size: 20,
            color: scheme.primary,
          ),
          const SizedBox(width: AppTokens.space12),
          Expanded(
            child: Text(
              '어제까지 못 끝낸 $count건이 오늘로 이월되었어요.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Error extends StatelessWidget {
  const _Error({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 36),
            const SizedBox(height: AppTokens.space12),
            Text('오늘 화면을 불러오지 못했어요', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppTokens.space4),
            Text(
              message,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
