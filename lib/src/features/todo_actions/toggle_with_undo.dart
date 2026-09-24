import 'package:flutter/material.dart';

import '../../domain/todo.dart';
import '../../ui/widgets/undo_snackbar.dart';
import 'todo_actions_controller.dart';

/// 체크(완료 토글) + **완료했을 때만** 되돌리기 스낵바 (UX Phase 1).
///
/// 체크가 원 하나로 커지고 폰은 오른쪽 스와이프로도 완료되므로 실수 체크가 늘 수
/// 있다. 되돌리기는 체크 전 상태(미완료 / 진행중, 시작 시각 포함)로 정확히 돌린다.
/// 완료 **취소** 쪽은 원 한 번 더 누르면 되니 스낵바를 띄우지 않는다.
///
/// [context] 는 목록의 한 줄일 수 있다 — 완료하면 그 줄이 목록에서 빠져 context 가
/// 죽는다. 그래서 스낵바 창구(ScaffoldMessenger)는 저장을 기다리기 **전에** 잡는다.
///
/// 이미 떠 있는 **삭제** 되돌리기는 밀어내지 않는다 — 삭제는 되돌릴 길이 스낵바뿐이지만
/// 완료는 원을 다시 누르면 된다.
///
/// 순서는 건드리지 않는다 ([TodoActionsController.toggle] /
/// [TodoActionsController.restoreStatus] 모두 sortOrder 보존).
Future<void> toggleWithUndo(
  BuildContext context,
  TodoActionsController actions,
  Todo todo,
) => toggleWithUndoOn(ScaffoldMessenger.maybeOf(context), actions, todo);

/// [toggleWithUndo] 의 messenger 버전 — 토글 전에 이미 await 가 있어 context 가
/// 그사이 죽을 수 있는 호출처(캘린더 반복 미리보기 체크 등)용.
Future<void> toggleWithUndoOn(
  ScaffoldMessengerState? messenger,
  TodoActionsController actions,
  Todo todo,
) async {
  final updated = await actions.toggle(todo);
  if (!updated.isDone || messenger == null || !messenger.mounted) return;
  showUndoSnackbarOn(
    messenger,
    message: '"${todo.title}" 완료',
    duration: const Duration(seconds: 4),
    yieldToOthers: true,
    onUndo: () => actions.restoreStatus(todo),
  );
}
