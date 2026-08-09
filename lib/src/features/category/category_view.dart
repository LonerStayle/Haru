import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/category.dart';
import '../../domain/policies/todo_sort_policy.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/skeleton.dart';
import '../../ui/widgets/sort_mode_button.dart';
import '../../ui/widgets/todo_drill_list.dart';
import '../../ui/widgets/todo_status_filter.dart';
import '../../ui/widgets/undo_snackbar.dart';
import '../add_todo/add_todo_controller.dart';
import '../add_todo/add_todo_sheet.dart';
import '../move_todo/move_todo_sheet.dart';
import '../settings/sort_mode_controller.dart';
import '../todo_actions/todo_actions_controller.dart';
import '../todo_detail/todo_detail_screen.dart';
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
      error: (e, _) => _Error(message: '$e'),
      data: (todos) => _Loaded(
        category: category,
        todos: todos,
        sortMode: sortMode,
        onToggleSort: () => ref.read(sortModeProvider.notifier).toggle(),
        onToggle: (t) => ref.read(todoActionsProvider).toggle(t),
        onToggleInProgress: (t) =>
            ref.read(todoActionsProvider).toggleInProgress(t),
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
        onEdit: (t) async {
          await AddTodoSheet.show(
            context,
            initialCategory: t.category,
            initialTodo: t,
            onSubmit: (_) {},
            onUpdate: (updated) =>
                ref.read(todoActionsProvider).update(updated),
            onRequestMove: (item) =>
                showMoveTodoSheet(context, ref, item: item),
          );
        },
        onDrillDown: (folder) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TodoDetailScreen(parent: folder),
          ),
        ),
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
  });

  final Category category;

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
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space24,
            AppTokens.space32,
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
              subtitle: '여기에 추가하면 ${category.label} 카테고리로 분류됩니다.',
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
              child: Text(
                category.label,
                style: theme.textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppTokens.space8),
            // 정렬 토글 — 이 카테고리 목록과 그 하위 체크리스트를 일정순으로 본다.
            SortModeButton(
              mode: sortMode,
              accent: category.color,
              onPressed: onToggleSort,
            ),
          ],
        ),
        // 상태별 보기 — 카운트 배지이자 필터 버튼. 누르면 그 상태만 목록에 남는다.
        // (기존 미완료/진행중/완료/메모 통계 칩을 그대로 클릭 가능하게 승격 + '전체'.)
        if (showFilters) ...[
          const SizedBox(height: AppTokens.space12),
          TodoStatusFilterBar(
            counts: counts,
            selected: filter,
            onSelected: onFilterChanged,
            accent: category.color,
          ),
        ],
      ],
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
            Text('카테고리를 불러오지 못했어요', style: theme.textTheme.titleMedium),
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
