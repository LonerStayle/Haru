import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/todo.dart';
import '../../ui/widgets/undo_snackbar.dart';
import '../add_todo/add_todo_sheet.dart';
import '../move_todo/move_todo_sheet.dart';
import '../outline/tree_providers.dart';
import '../todo_detail/todo_detail_screen.dart';
import 'todo_actions_controller.dart';

/// 목록 한 줄이 공통으로 쓰는 동작 — 화면마다 복붙돼 있던 편집 시트·상세 열기·
/// 삭제+되돌리기를 한 곳에 모았다 (UX 개선 Phase 2: "행 동작은 어디서나 같다").

/// 할 일 편집 시트 (닫힘 = 저장).
Future<void> openTodoEdit(BuildContext context, WidgetRef ref, Todo todo) {
  final actions = ref.read(todoActionsProvider);
  return AddTodoSheet.show(
    context,
    initialCategory: todo.category,
    initialTodo: todo,
    onSubmit: (_) {},
    onUpdate: actions.update,
    onStatusChanged: actions.updatePreservingOrder,
    onRequestMove: (item) => showMoveTodoSheet(context, ref, item: item),
  );
}

/// 할 일 상세 — 탭은 어디서나 여기로 온다 (하위 항목 유무와 무관).
Future<void> openTodoDetail(BuildContext context, Todo todo) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => TodoDetailScreen(parent: todo)),
  );
}

/// 삭제(하위 항목 포함) + 되돌리기 스낵바.
///
/// 목록 한 줄의 context 는 삭제되는 순간 사라지므로 messenger 를 먼저 잡는다.
Future<void> deleteTodoWithUndo(
  BuildContext context,
  WidgetRef ref,
  Todo todo,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final actions = ref.read(todoActionsProvider);
  final all = ref.read(allTodosProvider).asData?.value;
  final snapshot = await actions.deleteTree(todo, all: all);
  if (messenger == null || !messenger.mounted) return;
  final children = snapshot.length - 1;
  showUndoSnackbarOn(
    messenger,
    message: children > 0
        ? '"${todo.title}"(하위 $children개 포함) 삭제됨'
        : '"${todo.title}" 삭제됨',
    onUndo: () => actions.restoreAll(snapshot),
  );
}
