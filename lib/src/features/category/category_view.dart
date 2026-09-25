import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../domain/category.dart';
import '../../domain/policies/todo_sort_policy.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/skeleton.dart';
import '../../ui/widgets/sort_mode_button.dart';
import '../../ui/widgets/todo_drill_list.dart';
import '../../ui/widgets/todo_status_filter.dart';
import '../add_todo/add_todo_controller.dart';
import '../move_todo/move_todo_sheet.dart';
import '../settings/sort_mode_controller.dart';
import '../todo_actions/todo_actions_controller.dart';
import '../todo_actions/toggle_with_undo.dart';
import '../recurrence/recurrence_actions.dart';
import '../todo_actions/todo_row_actions.dart';
import 'category_actions.dart';
import 'category_providers.dart';

/// 카테고리 destination 선택 시 보여줄 화면. 헤더 + 미체크/완료 통계 + 리스트.
class CategoryView extends ConsumerWidget {
  const CategoryView({super.key, required this.category});

  final Category category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncTodos = ref.watch(watchTodosByCategoryProvider(category));
    // 정렬 모드는 전역 — 여기서 켜면 하위 상세(체크리스트)에도 그대로 적용된다.
    final sortMode = ref.watch(sortModeProvider);

    return asyncTodos.when(
      loading: () => const TodoListSkeleton(),
      error: (e, _) => ErrorState(
        title: '카테고리를 불러오지 못했어요',
        error: e,
        onRetry: () => ref.invalidate(watchTodosByCategoryProvider(category)),
      ),
      data: (todos) => _Loaded(
        category: category,
        todos: todos,
        sortMode: sortMode,
        onToggleSort: () => ref.read(sortModeProvider.notifier).toggle(),
        onAddTodo: () =>
            showNewTodoSheet(context, ref, initialCategory: category),
        onToggle: (t) =>
            toggleWithUndo(context, ref.read(todoActionsProvider), t),
        onToggleInProgress: (t) =>
            ref.read(todoActionsProvider).toggleInProgress(t),
        onDelete: (t) => deleteTodoWithUndo(context, ref, t),
        onEdit: (t) => openTodoEdit(context, ref, t),
        onDrillDown: (t) => openTodoDetail(context, t),
        onStopRecurrence: (t) => confirmStopRecurrence(context, ref, t),
        onAddChild: (parent) => showAddChildSheet(context, ref, parent: parent),
        onMove: (t) => showMoveTodoSheet(context, ref, item: t),
        onCopy: (t) => showCopyTodoSheet(context, ref, original: t),
        onReorderSiblings: (siblings, oldIndex, newIndex) => ref
            .read(todoActionsProvider)
            .reorderSiblings(siblings, oldIndex, newIndex),
      ),
    );
  }
}

class _Loaded extends StatefulWidget {
  const _Loaded({
    required this.category,
    required this.todos,
    required this.sortMode,
    required this.onToggleSort,
    required this.onToggle,
    required this.onToggleInProgress,
    required this.onDelete,
    required this.onEdit,
    required this.onDrillDown,
    required this.onAddChild,
    required this.onMove,
    required this.onCopy,
    required this.onReorderSiblings,
    required this.onAddTodo,
    required this.onStopRecurrence,
  });

  final Category category;

  /// 빈 화면의 "새 할 일" 버튼 — 이 카테고리로 추가 시트를 연다.
  final VoidCallback onAddTodo;

  /// 이 카테고리에 속한 모든 todo (root + 자손). root 선별 + childCount 양쪽에 사용.
  final List<Todo> todos;

  /// 현재 목록 정렬 방식 (수동 / 일정순).
  final TodoSortMode sortMode;

  /// 헤더의 정렬 버튼 탭 — 수동 ↔ 일정순 전환.
  final VoidCallback onToggleSort;
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
  final void Function(Todo) onStopRecurrence;

  @override
  State<_Loaded> createState() => _LoadedState();
}

class _LoadedState extends State<_Loaded> {
  /// 상태별 보기 — 현재 선택된 칩. 세션 비영속(화면 재진입 시 '전체'로 초기화).
  TodoStatusFilter _filter = TodoStatusFilter.all;

  /// 이 카테고리의 root (parentId null). 자식은 드릴다운 상세 화면에서 본다.
  List<Todo> get _roots =>
      widget.todos.where((t) => t.parentId == null).toList();

  @override
  Widget build(BuildContext context) {
    final todos = widget.todos;
    final category = widget.category;
    // 미완료/진행중/완료 카운트는 **task 만** 센다. note(메모) 는 체크 개념이 없어
    // isDone 이 항상 false → 예전엔 모두 '미체크'로 잘못 잡혔다 (이슈 수정).
    // 진행중 3-상태 — '미완료'는 순수 미완료(진행중 제외), 진행중은 별도 칩.
    // 자손까지 모두 세므로 칩 카운트 = 그 칩을 눌렀을 때 실제로 보이는 건수.
    final counts = TodoStatusCounts.of(todos);

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            AppTokens.space24,
            AppPlatform.isMobile ? AppTokens.space12 : AppTokens.space32,
            AppTokens.space24,
            AppTokens.space16,
          ),
          sliver: SliverToBoxAdapter(
            child: _Header(
              category: category,
              counts: counts,
              filter: _filter,
              // 빈 카테고리에서는 전부 0 인 칩 줄이 의미 없어 감춘다.
              showFilters: todos.isNotEmpty,
              onFilterChanged: (f) => setState(() => _filter = f),
              sortMode: widget.sortMode,
              onToggleSort: widget.onToggleSort,
            ),
          ),
        ),
        if (todos.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: category.icon,
              tone: category.color,
              title: '${category.label}에 할 일이 없어요',
              subtitle: '여기서 추가하면 ${category.label} 카테고리로 들어가요.',
              action: FilledButton.tonalIcon(
                key: const ValueKey('empty-add-todo'),
                onPressed: widget.onAddTodo,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('새 할 일'),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.space24,
              AppTokens.space8,
              AppTokens.space24,
              AppTokens.space48,
            ),
            sliver: TodoDrillListSliver(
              items: _roots,
              allTodos: todos,
              // 필터가 걸리면 root 뿐 아니라 자손까지 평탄하게 (칩 카운트와 일치).
              filter: _filter,
              filterPool: todos,
              onToggle: widget.onToggle,
              onToggleInProgress: widget.onToggleInProgress,
              onDelete: widget.onDelete,
              onEdit: widget.onEdit,
              onDrillDown: widget.onDrillDown,
              onAddChild: widget.onAddChild,
              onMove: widget.onMove,
              onCopy: widget.onCopy,
              onReorderSiblings: widget.onReorderSiblings,
              onStopRecurrence: widget.onStopRecurrence,
              sortMode: widget.sortMode,
            ),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.category,
    required this.counts,
    required this.filter,
    required this.showFilters,
    required this.onFilterChanged,
    required this.sortMode,
    required this.onToggleSort,
  });

  final Category category;
  final TodoStatusCounts counts;
  final TodoStatusFilter filter;
  final bool showFilters;
  final ValueChanged<TodoStatusFilter> onFilterChanged;
  final TodoSortMode sortMode;
  final VoidCallback onToggleSort;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sortButton = SortModeButton(
      mode: sortMode,
      accent: category.color,
      onPressed: onToggleSort,
    );
    final filterBar = TodoStatusFilterBar(
      counts: counts,
      selected: filter,
      onSelected: onFilterChanged,
      accent: category.color,
    );
    // ⋮ — 카테고리 관리 (수정 · 그룹 이동 · 보관 · 삭제). 사이드바·목록과 같은 메뉴.
    final menuButton = Builder(
      builder: (ctx) => IconButton(
        key: const ValueKey('category-header-menu'),
        tooltip: '카테고리 메뉴',
        icon: const Icon(Icons.more_vert),
        onPressed: () {
          Offset? at;
          if (AppPlatform.isDesktop) {
            final box = ctx.findRenderObject()! as RenderBox;
            at = box.localToGlobal(box.size.bottomLeft(Offset.zero));
          }
          CategoryActions.of(ctx).showCategoryMenu(category, position: at);
        },
      ),
    );
    final tasks = counts.undone + counts.inProgress + counts.done;
    // 모바일은 앱바가 카테고리 이름을 이미 보여 준다 → 큰 아이콘·제목 줄을 빼고
    // 필터 칩 + 정렬 버튼 한 줄만 둔다 (제목 중복 제거, UX 감사).
    if (AppPlatform.isMobile) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: showFilters ? filterBar : const SizedBox.shrink()),
          const SizedBox(width: AppTokens.space8),
          sortButton,
          menuButton,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: category.color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppTokens.radiusM),
              ),
              child: Icon(category.icon, color: category.color),
            ),
            const SizedBox(width: AppTokens.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    category.label,
                    style: theme.textTheme.displayMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  // 진척 한 줄 — 할 일이 있을 때만.
                  if (tasks > 0)
                    Text(
                      '완료 ${counts.done}/$tasks · 남은 ${tasks - counts.done}개',
                      key: const ValueKey('category-header-progress'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppTokens.space8),
            // 정렬 토글 — 이 카테고리 목록과 그 하위 체크리스트를 일정순으로 본다.
            sortButton,
            menuButton,
          ],
        ),
        // 상태별 보기 — 카운트 배지이자 필터 버튼. 누르면 그 상태만 목록에 남는다.
        // (기존 미완료/진행중/완료/메모 통계 칩을 그대로 클릭 가능하게 승격 + '전체'.)
        if (showFilters) ...[
          const SizedBox(height: AppTokens.space12),
          filterBar,
        ],
      ],
    );
  }
}
