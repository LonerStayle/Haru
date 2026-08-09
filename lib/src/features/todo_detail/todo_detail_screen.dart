import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/in_progress_triangle.dart';
import '../../ui/widgets/skeleton.dart';
import '../../ui/widgets/sort_mode_button.dart';
import '../../ui/widgets/todo_drill_list.dart';
import '../../ui/widgets/undo_snackbar.dart';
import '../add_todo/add_todo_controller.dart';
import '../add_todo/add_todo_sheet.dart';
import '../outline/tree_providers.dart';
import '../recurrence/recurrence_actions.dart';
import '../settings/sort_mode_controller.dart';
import '../todo_actions/todo_actions_controller.dart';

/// 기능 M — 하위 체크리스트 드릴다운 상세 화면.
///
/// [parent] 의 직속 자식들을 "평면 + 드릴다운" 리스트로 보여준다. 자식 중 또 자식이
/// 있으면 탭 → 더 깊은 [TodoDetailScreen] 으로 드릴, leaf 면 탭 → 편집 시트.
/// AppBar 에 parent 제목 + 체크 토글 + ✎ 편집. 상단 헤더에 ＋하위추가.
///
/// parent 가 watch 중 삭제되면(allTodos 에 사라지면) 자동으로 pop 한다 (dangling 방지).
class TodoDetailScreen extends ConsumerWidget {
  const TodoDetailScreen({super.key, required this.parent});

  /// 진입 시점의 parent 스냅샷. 최신 상태는 [allTodosProvider] 에서 id 로 재조회.
  final Todo parent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncAll = ref.watch(allTodosProvider);
    final asyncChildren = ref.watch(childrenOfProvider(parent.id));
    // 카테고리 화면의 정렬 버튼과 같은 전역 상태 — 하위 목록도 함께 일정순으로 보인다.
    final sortMode = ref.watch(sortModeProvider);

    final allTodos = asyncAll.asData?.value ?? const <Todo>[];
    // parent 최신 상태 — 삭제되었으면 진입 스냅샷으로 fallback (pop 처리는 아래).
    final live = allTodos.firstWhere(
      (t) => t.id == parent.id,
      orElse: () => parent,
    );

    // parent 가 삭제되면 상세 화면을 닫는다 (자식만 남는 빈 화면 방지).
    final deleted =
        asyncAll.hasValue && !allTodos.any((t) => t.id == parent.id);
    if (deleted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
    }

    final isNote = live.type == TodoType.note;
    final isDone = live.isDone;
    final isInProgress = live.isInProgress;
    // §14 — 자손 task 진척 요약 (note 헤딩/ task 폴더 공통). taskCount 0 이면 숨김.
    final progress = computeSubtreeProgress(live, allTodos);

    final actions = ref.read(todoActionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(live.title, overflow: TextOverflow.ellipsis),
        actions: [
          // 하위 목록 정렬 토글 — 카테고리 화면의 "일정순" 버튼과 같은 설정.
          SortModeIconButton(
            mode: sortMode,
            accent: live.category.color,
            onPressed: () => ref.read(sortModeProvider.notifier).toggle(),
          ),
          // 진행중(세모) 토글 — 완료 체크 왼쪽. note 는 진행 개념 없음 → 미표시.
          if (!isNote)
            IconButton(
              key: const ValueKey('detail-progress'),
              tooltip: isInProgress ? '진행중 해제' : '진행중',
              icon: InProgressTriangle(
                active: isInProgress,
                color: live.category.color,
                size: 20,
              ),
              onPressed: () => actions.toggleInProgress(live),
            ),
          // parent 체크 토글 (note 는 체크 개념 없음 → 미표시).
          if (!isNote)
            IconButton(
              key: const ValueKey('detail-toggle'),
              tooltip: isDone ? '완료 취소' : '완료',
              icon: Icon(
                isDone
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked,
                color: isDone ? live.category.color : null,
              ),
              onPressed: () => actions.toggle(live),
            ),
          // ✎ 편집 — AddTodoSheet edit 모드.
          IconButton(
            key: const ValueKey('detail-edit'),
            tooltip: '편집',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => AddTodoSheet.show(
              context,
              initialCategory: live.category,
              initialTodo: live,
              onSubmit: (_) {},
              onUpdate: (updated) => actions.update(updated),
            ),
          ),
        ],
      ),
      // §14 — ＋ 하위 추가. note 도 "섹션 헤딩" 으로 자식 보유 가능 → 항상 노출.
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('detail-add-child'),
        onPressed: () => showAddChildSheet(context, ref, parent: live),
        icon: const Icon(Icons.add),
        label: const Text('하위 추가'),
      ),
      body: asyncChildren.when(
        loading: () => const TodoListSkeleton(),
        error: (e, _) => _DetailError(message: '$e'),
        data: (children) {
          if (children.isEmpty) {
            return EmptyState(
              icon: Icons.checklist_rounded,
              tone: live.category.color,
              title: '하위 항목이 없어요',
              subtitle: isNote
                  ? '아래 “하위 추가” 로 이 메모 아래에 항목을 만들어보세요.'
                  : '아래 “하위 추가” 로 체크리스트를 만들어보세요.',
            );
          }
          return CustomScrollView(
            slivers: [
              if (progress.taskCount > 0)
                SliverToBoxAdapter(
                  child: _SubtreeProgressBar(
                    progress: progress,
                    accent: live.category.color,
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.space16,
                  AppTokens.space16,
                  AppTokens.space16,
                  // FAB 가 마지막 항목을 가리지 않도록 하단 여백 확보.
                  AppTokens.space48 + 40,
                ),
                sliver: TodoDrillListSliver(
                  items: children,
                  allTodos: allTodos,
                  onDrillDown: (folder) => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TodoDetailScreen(parent: folder),
                    ),
                  ),
                  onEdit: (leaf) => AddTodoSheet.show(
                    context,
                    initialCategory: leaf.category,
                    initialTodo: leaf,
                    onSubmit: (_) {},
                    onUpdate: (updated) => actions.update(updated),
                  ),
                  onToggle: actions.toggle,
                  onToggleInProgress: actions.toggleInProgress,
                  onAddChild: (p) => showAddChildSheet(context, ref, parent: p),
                  onCopy: (t) => showCopyTodoSheet(context, ref, original: t),
                  onDelete: (t) async {
                    await actions.delete(t);
                    if (!context.mounted) return;
                    showUndoSnackbar(
                      context,
                      message: '"${t.title}" 삭제됨',
                      onUndo: () => actions.restore(t),
                    );
                  },
                  onReorderSiblings: actions.reorderSiblings,
                  onStopRecurrence: (t) =>
                      confirmStopRecurrence(context, ref, t),
                  sortMode: sortMode,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// §14 — 상세 화면 상단의 자손 task 진척 요약. `done/total 완료` + 진행 바.
class _SubtreeProgressBar extends StatelessWidget {
  const _SubtreeProgressBar({required this.progress, required this.accent});

  final SubtreeProgress progress;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: const ValueKey('detail-progress'),
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space16,
        AppTokens.space16,
        AppTokens.space16,
        0,
      ),
      child: Row(
        children: [
          Text(
            '${progress.doneCount}/${progress.taskCount} 완료',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: accent,
            ),
          ),
          const SizedBox(width: AppTokens.space12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTokens.radiusFull),
              child: LinearProgressIndicator(
                value: progress.ratio ?? 0,
                minHeight: 6,
                backgroundColor: scheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailError extends StatelessWidget {
  const _DetailError({required this.message});

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
            Text('하위 항목을 불러오지 못했어요', style: theme.textTheme.titleMedium),
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
