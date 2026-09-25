import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../domain/policies/carryover_policy.dart';
import '../../domain/policies/move_policy.dart';
import '../../domain/policies/recurrence_dedup_policy.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/skeleton.dart';
import '../../ui/widgets/today_progress_summary.dart';
import '../../ui/widgets/todo_category_sections.dart';
import '../../ui/widgets/undo_snackbar.dart';
import '../add_todo/add_todo_controller.dart';
import '../add_todo/add_todo_default_category.dart';
import '../category/categories_controller.dart';
import '../settings/app_preferences.dart';
import '../category/groups_controller.dart';
import '../move_todo/move_todo_sheet.dart';
import '../outline/tree_providers.dart';
import '../recurrence/recurrence_actions.dart';
import '../recurrence/recurrence_manage_screen.dart';
import '../todo_actions/todo_actions_controller.dart';
import '../todo_actions/toggle_with_undo.dart';
import '../../ui/widgets/group_scope_chips.dart';
import '../todo_actions/todo_row_actions.dart';
import 'today_providers.dart';

/// 오늘 화면 — 헤더 + 그룹 필터 칩 + 이월 배너 + visible todos 리스트.
///
/// 그룹 필터([groupScopeProvider], 전체보기와 공유)가 켜져 있으면 그 그룹에 속한
/// 카테고리의 오늘 할 일만 보여 준다. (예전 그룹 화면의 '오늘' 탭을 대신한다.)
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(scopedGroupProvider);
    // 보관 카테고리 제외된 오늘 목록 (visibleTodayTodosProvider). 원본 stream 은
    // 순수 유지하고 파생 필터만 적용 — 보관/복원 시 즉시 반영.
    final asyncTodos = ref.watch(visibleTodayTodosProvider);
    // date-repeat — 반복 인스턴스 자동 생성 트리거 활성화(앱시작·자정). 이 화면이
    // 떠 있는 동안 마스터의 누락 발생분이 채워진다.
    ref.watch(recurrenceMaterializerProvider);
    final globalCarryover = ref.watch(carryoverCountProvider);
    ref.watch(carryoverBannerDismissedProvider);
    final bannerNotifier = ref.read(carryoverBannerDismissedProvider.notifier);
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
          .where((c) => c.groupId == group.id)
          .map((c) => c.id)
          .toSet();
    }

    return asyncTodos.when(
      loading: () => const TodoListSkeleton(),
      error: (e, _) => ErrorState(
        title: '오늘 화면을 불러오지 못했어요',
        error: e,
        onRetry: () => ref.invalidate(visibleTodayTodosProvider),
      ),
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
        // 상단 진척 요약 — 오늘 task(메모 제외) 완료/전체 + 진행중.
        final tasks = todos.where((t) => t.type == TodoType.task);
        final doneCount = tasks.where((t) => t.isDone).length;
        final inProgressCount = tasks.where((t) => t.isInProgress).length;
        final totalCount = tasks.length;
        return _Loaded(
          // 그룹을 바꾸면 화면 상태(이월만 보기·완료 펼침)를 새로 — 예전 그룹 화면처럼.
          key: ValueKey('today-${group?.id}'),
          todos: todos,
          allTodos: allTodos,
          groups: groups,
          hiddenCountBySeries: hiddenCountBySeries,
          // 그룹 필터 중에는 그룹 라벨이 중복이라 숨긴다.
          showGroupLabel: group == null,
          showScopeChips: groups.isNotEmpty,
          doneCount: doneCount,
          inProgressCount: inProgressCount,
          totalCount: totalCount,
          carryoverCount: carryoverCount,
          carryoverBannerDismissed: bannerNotifier.isDismissedOn(
            group?.id ?? '',
            now,
          ),
          onDismissCarryoverBanner: () =>
              bannerNotifier.dismiss(group?.id ?? '', now),
          now: now,
          onToggle: (t) =>
              toggleWithUndo(context, ref.read(todoActionsProvider), t),
          onToggleInProgress: (t) =>
              ref.read(todoActionsProvider).toggleInProgress(t),
          onDelete: (t) => deleteTodoWithUndo(context, ref, t),
          // 메뉴 "편집" → 편집 시트.
          onEdit: (t) => openTodoEdit(context, ref, t),
          // 탭 → 상세 (하위 유무와 무관).
          onDrillDown: (t) => openTodoDetail(context, t),
          // Task C — ＋ 하위 추가.
          onAddChild: (parent) =>
              showAddChildSheet(context, ref, parent: parent),
          onMove: (t) => showMoveTodoSheet(context, ref, item: t),
          onCopy: (t) => showCopyTodoSheet(context, ref, original: t),
          // Task B — 형제 드래그 재정렬.
          onReorderSiblings: (siblings, oldIndex, newIndex) => ref
              .read(todoActionsProvider)
              .reorderSiblings(siblings, oldIndex, newIndex),
          // 섹션 간 드래그 — 다른 카테고리 섹션에 놓으면 그 카테고리로 이동까지.
          // 순서만 바꾸려다 옆 섹션에 떨어뜨리는 실수가 잦아 되돌리기를 붙인다 (UX 감사 B7).
          onMoveToCategory: (item, target, targetItems, insertIndex) async {
            final actions = ref.read(todoActionsProvider);
            // 되돌리기 스냅샷 — 본인 + 자손(카테고리 동기화 대상) + 대상 섹션 형제(순서 재부여 대상).
            final snapshot = <Todo>{
              item,
              ...MovePolicy.descendants(item.id, allTodos),
              ...targetItems,
            }.toList();
            final moved = await actions.moveToCategoryAt(
              item,
              target: target,
              targetSiblings: targetItems,
              insertIndex: insertIndex,
              all: allTodos,
            );
            if (!moved || !context.mounted) return;
            showUndoSnackbar(
              context,
              message: '"${item.title}" → ${target.label}(으)로 이동',
              onUndo: () => actions.restoreAll(snapshot),
            );
          },
          // date-repeat — ⋮ '반복 중지' → 시리즈 마스터 삭제(비파괴적).
          onStopRecurrence: (t) => confirmStopRecurrence(context, ref, t),
          // 오늘 화면에서 추가하면 오늘 날짜 — 날짜가 없으면 '오늘' 에 안 보인다.
          onAddTodo: () {
            final now = ref.read(nowProvider)();
            showNewTodoSheet(
              context,
              ref,
              initialCategory: _defaultCategoryFor(ref, group),
              initialDueAt: DateTime(now.year, now.month, now.day),
            );
          },
        );
      },
    );
  }
}

/// 오늘 화면 빈 상태 "새 할 일" 버튼의 기본 카테고리 — ⌘N 과 같은 규칙(설정의 기본 카테고리
/// → 마지막에 쓴 카테고리 → 사이드바 첫 카테고리, 그룹 탭이면 그 그룹 안에서). 로딩 중이면 '일상'.
Category _defaultCategoryFor(WidgetRef ref, Group? group) {
  final categories =
      ref.read(activeCategoriesProvider).asData?.value ?? const <Category>[];
  if (categories.isEmpty) return Category.daily;
  return resolveAddTodoDefaultCategory(
    categories: categories,
    groups: ref.read(activeGroupsProvider).asData?.value ?? const <Group>[],
    destinations: const [],
    index: 0,
    selectedGroupId: group?.id,
    preferredCategoryId: ref.read(defaultCategoryIdProvider),
    lastUsedId: ref.read(lastUsedCategoryProvider),
  );
}

class _Loaded extends StatefulWidget {
  const _Loaded({
    super.key,
    required this.todos,
    required this.allTodos,
    required this.groups,
    required this.hiddenCountBySeries,
    required this.showGroupLabel,
    required this.doneCount,
    required this.inProgressCount,
    required this.totalCount,
    required this.carryoverCount,
    required this.carryoverBannerDismissed,
    required this.onDismissCarryoverBanner,
    required this.showScopeChips,
    required this.now,
    required this.onToggle,
    required this.onToggleInProgress,
    required this.onDelete,
    required this.onEdit,
    required this.onDrillDown,
    required this.onAddChild,
    required this.onMove,
    required this.onCopy,
    required this.onReorderSiblings,
    required this.onMoveToCategory,
    required this.onStopRecurrence,
    required this.onAddTodo,
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

  /// 상단 진척 요약 — 오늘 task 완료/전체 + 진행중.
  final int doneCount;
  final int inProgressCount;
  final int totalCount;
  final int carryoverCount;

  /// 오늘 이월 배너를 닫았는지 / 닫기.
  final bool carryoverBannerDismissed;
  final VoidCallback onDismissCarryoverBanner;

  /// 그룹 필터 칩 줄 표시 여부 (그룹이 하나라도 있을 때).
  final bool showScopeChips;
  final DateTime now;
  final void Function(Todo) onToggle;
  final void Function(Todo) onToggleInProgress;
  final void Function(Todo) onDelete;
  final void Function(Todo) onEdit;
  final void Function(Todo) onDrillDown;
  final void Function(Todo) onAddChild;
  final void Function(Todo) onMove;
  final void Function(Todo) onCopy;
  final void Function(List<Todo> siblings, int oldIndex, int newIndex)
  onReorderSiblings;

  /// 섹션 간 드래그 — 다른 카테고리 섹션에 놓았을 때 (그 카테고리로 이동 + 자리 삽입).
  final void Function(
    Todo item,
    Category target,
    List<Todo> targetItems,
    int insertIndex,
  )
  onMoveToCategory;

  /// date-repeat (FR-6) — ⋮ '반복 중지' 콜백.
  final void Function(Todo) onStopRecurrence;

  /// 빈 화면의 "새 할 일" 버튼.
  final VoidCallback onAddTodo;

  @override
  State<_Loaded> createState() => _LoadedState();
}

class _LoadedState extends State<_Loaded> {
  /// 섹션별 "완료 N개" 접기 행을 펼친 카테고리 — 기본 접힘, 세션 비영속.
  final Set<String> _expandedDone = {};

  /// 이월 배너의 "이월만 보기" — 켜면 어제 이전에서 넘어온 항목만 보인다.
  bool _carryoverOnly = false;

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
  void didUpdateWidget(covariant _Loaded oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 이월이 다 정리되면 필터를 실제로 끈다 — 계산으로만 숨기면, 되돌리기·동기화로
    // 이월이 다시 생길 때 사용자가 누르지도 않았는데 필터가 되살아났다.
    if (widget.carryoverCount == 0) _carryoverOnly = false;
  }

  /// '이월만 보기' 의 대상 root — root 자신이 이월됐거나, 그 아래 보이는 하위 중
  /// 이월된 게 있는 root. (하위만 이월된 경우 root 를 빼면 화면이 통째로 비었다.)
  List<Todo> _carryoverRoots(List<Todo> roots) {
    final byId = {for (final t in widget.todos) t.id: t};
    final marked = <String>{};
    for (final t in widget.todos) {
      if (!CarryoverPolicy.shouldCarryOverToday(t, widget.now)) continue;
      var cur = t;
      final seen = <String>{};
      while (cur.parentId != null &&
          byId.containsKey(cur.parentId) &&
          seen.add(cur.id)) {
        cur = byId[cur.parentId]!;
      }
      marked.add(cur.id);
    }
    return roots.where((t) => marked.contains(t.id)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final allRoots = _roots;
    final carriedRoots = _carryoverOnly
        ? _carryoverRoots(allRoots)
        : const <Todo>[];
    // 추릴 게 없으면(반복 묶음에 가려졌거나 이미 정리됨) 필터는 풀린 것으로 본다.
    final carryoverOnly = _carryoverOnly && carriedRoots.isNotEmpty;
    final roots = carryoverOnly ? carriedRoots : allRoots;
    final showBanner =
        widget.carryoverCount > 0 &&
        (carryoverOnly || !widget.carryoverBannerDismissed);
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: AppPlatform.isMobile
              ? const EdgeInsets.fromLTRB(
                  AppTokens.space24,
                  AppTokens.space12,
                  AppTokens.space24,
                  AppTokens.space8,
                )
              : const EdgeInsets.fromLTRB(
                  AppTokens.space24,
                  AppTokens.space32,
                  AppTokens.space24,
                  AppTokens.space12,
                ),
          sliver: SliverToBoxAdapter(child: _Header(now: widget.now)),
        ),
        // 그룹 필터 — 전체보기와 공유. 그룹이 없으면 줄 자체가 없다.
        if (widget.showScopeChips)
          const SliverPadding(
            padding: EdgeInsets.only(bottom: AppTokens.space12),
            sliver: SliverToBoxAdapter(
              child: GroupScopeChips(
                padding: EdgeInsets.symmetric(horizontal: AppTokens.space24),
              ),
            ),
          ),
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
                inProgress: widget.inProgressCount,
                total: widget.totalCount,
              ),
            ),
          ),
        if (showBanner)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.space24,
              AppTokens.space8,
              AppTokens.space24,
              0,
            ),
            sliver: SliverToBoxAdapter(
              child: _CarryoverBanner(
                count: widget.carryoverCount,
                filtering: carryoverOnly,
                onToggleFilter: () =>
                    setState(() => _carryoverOnly = !carryoverOnly),
                onDismiss: () {
                  setState(() => _carryoverOnly = false);
                  widget.onDismissCarryoverBanner();
                },
              ),
            ),
          ),
        if (widget.todos.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.check_circle_outline_rounded,
              title: '오늘 할 일이 없어요',
              // 단축키 안내는 데스크탑에서만 — 폰에는 Cmd 키가 없다.
              subtitle: AppPlatform.isDesktop
                  ? '⌘N 으로 바로 추가해요. 다른 앱을 쓰다가도 ⌘⇧N.'
                  : '아래 버튼이나 + 로 추가해 보세요.',
              action: FilledButton.tonalIcon(
                key: const ValueKey('empty-add-todo'),
                onPressed: widget.onAddTodo,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('새 할 일'),
              ),
            ),
          )
        else ...[
          ...todayCategorySectionSlivers(
            roots: roots,
            allTodos: widget.allTodos,
            groups: widget.groups,
            showGroupLabel: widget.showGroupLabel,
            onToggle: widget.onToggle,
            onToggleInProgress: widget.onToggleInProgress,
            onDelete: widget.onDelete,
            onEdit: widget.onEdit,
            onDrillDown: widget.onDrillDown,
            onAddChild: widget.onAddChild,
            onMove: widget.onMove,
            onCopy: widget.onCopy,
            onReorderSiblings: widget.onReorderSiblings,
            onMoveToCategory: widget.onMoveToCategory,
            hiddenCountBySeries: widget.hiddenCountBySeries,
            onStopRecurrence: widget.onStopRecurrence,
            now: widget.now,
            expandedDoneCategories: _expandedDone,
            // 일부만 보이는 동안엔 순서 바꾸기를 끈다 (숨은 항목과 번호가 겹친다).
            reorderEnabled: !carryoverOnly,
            onToggleDone: (cid) => setState(() {
              if (!_expandedDone.remove(cid)) _expandedDone.add(cid);
            }),
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
    // 모바일은 앱바가 이미 "오늘" 을 보여 주므로 큰 제목을 빼고 날짜만 한 줄로 둔다.
    // 제목이 두 번 나오며 첫 화면 세로 공간을 ~100dp 잡아먹던 문제 (UX 감사).
    final compact = AppPlatform.isMobile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: compact
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.end,
          children: [
            if (compact)
              Text(
                KoDate.pretty(now),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              )
            else
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
        if (!compact) ...[
          const SizedBox(height: AppTokens.space4),
          Text(KoDate.pretty(now), style: theme.textTheme.bodyMedium),
        ],
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

/// 이월 배너 — 알림 + 행동 두 개 (UX Phase 1).
///  - "이월만 보기": 어제 이전에서 넘어온 항목만 추려 본다 (다시 누르면 전체).
///  - "닫기": 오늘은 더 띄우지 않는다.
class _CarryoverBanner extends StatelessWidget {
  const _CarryoverBanner({
    required this.count,
    required this.filtering,
    required this.onToggleFilter,
    required this.onDismiss,
  });

  final int count;
  final bool filtering;
  final VoidCallback onToggleFilter;
  final VoidCallback onDismiss;

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
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space16,
        AppTokens.space4,
        AppTokens.space4,
        AppTokens.space4,
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
              filtering ? '이월된 $count건만 보는 중' : '어제까지 못 끝낸 $count건이 오늘로 넘어왔어요.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('carryover-banner-filter'),
            onPressed: onToggleFilter,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: Text(filtering ? '전체 보기' : '이월만 보기'),
          ),
          IconButton(
            key: const ValueKey('carryover-banner-dismiss'),
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded, size: 18),
            tooltip: '오늘은 그만 보기',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
