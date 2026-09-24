import 'package:flutter/material.dart';

import '../../domain/todo.dart';
import '../../ui/widgets/undo_snackbar.dart';
import 'todo_actions_controller.dart';

/// 체크(완료 토글) + **완료했을 때만** 되돌리기 스낵바 (UX Phase 1).
///
/// 체크가 원 하나로 커지고 폰은 오른쪽 스와이프로도 완료되므로 실수 체크가 늘 수
/// 있다. 되돌리기는 체크 전 상태(미완료 / 진행중)로 정확히 돌린다 — 진행중이던
/// 항목을 실수로 끝냈다가 되돌리면 다시 진행중이다. 완료 **취소** 쪽은 원 한 번
/// 더 누르면 되니 스낵바를 띄우지 않는다.
///
/// 순서는 건드리지 않는다 ([TodoActionsController.toggle] /
/// [TodoActionsController.updatePreservingOrder] 모두 sortOrder 보존).
Future<void> toggleWithUndo(
  BuildContext context,
  TodoActionsController actions,
  Todo todo,
) async {
  final updated = await actions.toggle(todo);
  if (!updated.isDone || !context.mounted) return;
  final before = todo.status;
  showUndoSnackbar(
    context,
    message: '"${todo.title}" 완료',
    duration: const Duration(seconds: 4),
    onUndo: () => actions.updatePreservingOrder(updated.withStatus(before)),
  );
}
