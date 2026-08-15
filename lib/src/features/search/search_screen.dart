import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/skeleton.dart';
import '../../ui/widgets/todo_tile.dart';
import '../../ui/widgets/undo_snackbar.dart';
import '../add_todo/add_todo_controller.dart';
import '../add_todo/add_todo_sheet.dart';
import '../category/categories_controller.dart';
import '../move_todo/move_todo_sheet.dart';
import '../outline/tree_providers.dart';
import '../todo_actions/todo_actions_controller.dart';
import 'todo_search.dart';

/// 할 일·메모 전역 검색 화면.
///
/// 카테고리/그룹/트리 깊이를 가리지 않고 제목과 메모 본문을 함께 훑는다. 결과는
/// 평탄한 한 겹 목록이라 항목마다 소속 경로(breadcrumb)를 붙여 위치를 잃지 않게 한다.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  /// 어느 화면에서든 검색을 띄우는 단일 진입점 (사이드바 버튼 / 앱바 버튼 / Cmd+F).
  static Future<void> show(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()));
  }

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();

  /// 검색어는 이 화면에서만 쓰는 일시 상태라 전역 provider 대신 로컬로 둔다
  /// (화면을 닫으면 사라지고, 다시 열면 빈 상태에서 시작).
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 보관된 카테고리의 항목은 다른 화면과 마찬가지로 검색에서도 빠진다
    // (보관 = 지금 안 보는 것. 되살리려면 설정 > 보관함에서 복원).
    final archivedIds = ref.watch(archivedCategoryIdsProvider);
    final todosAsync = ref.watch(allTodosProvider);

    return Shortcuts(
      // 데스크탑에서 Esc 로 닫기 — 다른 시트/오버레이와 같은 관례.
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              Navigator.of(context).maybePop();
              return null;
            },
          ),
        },
        child: Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: TextField(
              key: const ValueKey('search-field'),
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              style: theme.textTheme.titleMedium,
              decoration: const InputDecoration(
                hintText: '제목·메모 내용 검색',
                border: InputBorder.none,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            actions: [
              if (_query.isNotEmpty)
                IconButton(
                  key: const ValueKey('search-clear-button'),
                  icon: const Icon(Icons.close),
                  tooltip: '검색어 지우기',
                  onPressed: () {
                    _controller.clear();
                    setState(() => _query = '');
                  },
                ),
            ],
          ),
          body: todosAsync.when(
            loading: () => const TodoListSkeleton(),
            error: (_, _) => const EmptyState(
              icon: Icons.error_outline,
              title: '검색할 수 없어요',
              subtitle: '항목을 불러오지 못했습니다. 잠시 뒤 다시 시도해주세요.',
            ),
            data: (all) => _Results(
              hits: searchTodos(
                all: all,
                query: _query,
                excludedCategoryIds: archivedIds,
              ),
              query: _query,
            ),
          ),
        ),
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.hits, required this.query});

  final List<TodoSearchHit> hits;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (query.trim().isEmpty) {
      return const EmptyState(
        key: ValueKey('search-idle'),
        icon: Icons.search,
        title: '무엇을 찾을까요?',
        subtitle: '할 일 제목과 메모 내용을 함께 검색합니다.',
      );
    }
    if (hits.isEmpty) {
      return EmptyState(
        key: const ValueKey('search-empty'),
        icon: Icons.search_off,
        title: '"${query.trim()}" 결과 없음',
        subtitle: '다른 단어로 찾아보세요. 보관된 카테고리는 검색되지 않습니다.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space16,
        AppTokens.space12,
        AppTokens.space16,
        AppTokens.space32,
      ),
      itemCount: hits.length,
      itemBuilder: (context, i) {
        final hit = hits[i];
        final todo = hit.todo;
        return Padding(
          key: ValueKey('search-hit-${todo.id}'),
          padding: const EdgeInsets.only(bottom: AppTokens.space8),
          child: TodoTile(
            todo: todo,
            breadcrumb: hit.breadcrumb,
            snippet: hit.snippet,
            onToggle: () => ref.read(todoActionsProvider).toggle(todo),
            // 메모는 체크 개념이 없어 진행중 토글도 두지 않는다.
            onToggleInProgress: todo.type == TodoType.note
                ? null
                : () => ref.read(todoActionsProvider).toggleInProgress(todo),
            onTap: () => _edit(context, ref, todo),
            onEditItem: () => _edit(context, ref, todo),
            onMove: () => showMoveTodoSheet(context, ref, item: todo),
            onCopy: () => showCopyTodoSheet(context, ref, original: todo),
            onDelete: () => _delete(context, ref, todo),
          ),
        );
      },
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Todo todo) {
    return AddTodoSheet.show(
      context,
      initialCategory: todo.category,
      initialTodo: todo,
      onSubmit: (_) {},
      onUpdate: (updated) => ref.read(todoActionsProvider).update(updated),
      onRequestMove: (item) => showMoveTodoSheet(context, ref, item: item),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Todo todo) async {
    final actions = ref.read(todoActionsProvider);
    await actions.delete(todo);
    if (!context.mounted) return;
    showUndoSnackbar(
      context,
      message: '"${todo.title}" 삭제됨',
      onUndo: () => actions.restore(todo),
    );
  }
}
