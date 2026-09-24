import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/todo.dart';

/// 할 일 한 줄의 메뉴 항목 — 우클릭(데스크탑)·길게 누르기(폰)·⋮ 가 같은 목록을 쓴다.
enum TodoMenuAction {
  inProgress,
  addChild,
  edit,
  move,
  copy,
  stopRecurrence,
  delete,
}

/// 한 항목의 메뉴 콜백 묶음. null 인 콜백의 항목은 메뉴에 나오지 않는다.
///
/// 목록 타일([TodoTile])과 전체보기 행이 같은 메뉴를 쓰게 하려고 뺐다 —
/// "체크 하나 + 나머지는 메뉴" 원칙이 화면마다 어긋나지 않게.
class TodoMenu {
  const TodoMenu({
    required this.todo,
    this.onToggleInProgress,
    this.onAddChild,
    this.onEdit,
    this.onMove,
    this.onCopy,
    this.onStopRecurrence,
    this.onDelete,
  });

  final Todo todo;
  final VoidCallback? onToggleInProgress;
  final VoidCallback? onAddChild;
  final VoidCallback? onEdit;
  final VoidCallback? onMove;
  final VoidCallback? onCopy;
  final VoidCallback? onStopRecurrence;
  final VoidCallback? onDelete;

  /// [includeQuick] — 진행중·하위 추가까지 넣을지. 데스크탑 ⋮ 는 그 둘이 옆에
  /// hover 버튼으로 따로 있어 빼고, 우클릭·길게 누르기 메뉴는 전부 넣는다.
  List<TodoMenuAction> actions({required bool includeQuick}) {
    final isNote = todo.type == TodoType.note;
    return [
      if (includeQuick && !isNote && onToggleInProgress != null)
        TodoMenuAction.inProgress,
      if (includeQuick && onAddChild != null) TodoMenuAction.addChild,
      if (onEdit != null) TodoMenuAction.edit,
      if (onMove != null) TodoMenuAction.move,
      if (onCopy != null) TodoMenuAction.copy,
      if (onStopRecurrence != null && todo.isInRecurringSeries)
        TodoMenuAction.stopRecurrence,
      if (onDelete != null) TodoMenuAction.delete,
    ];
  }

  void run(TodoMenuAction action) {
    switch (action) {
      case TodoMenuAction.inProgress:
        onToggleInProgress?.call();
      case TodoMenuAction.addChild:
        onAddChild?.call();
      case TodoMenuAction.edit:
        onEdit?.call();
      case TodoMenuAction.move:
        onMove?.call();
      case TodoMenuAction.copy:
        onCopy?.call();
      case TodoMenuAction.stopRecurrence:
        onStopRecurrence?.call();
      case TodoMenuAction.delete:
        onDelete?.call();
    }
  }

  (IconData, String) describe(TodoMenuAction a) => switch (a) {
    TodoMenuAction.inProgress => (
      Icons.change_history_rounded,
      todo.isInProgress ? '진행중 해제' : '진행중으로',
    ),
    TodoMenuAction.addChild => (
      Icons.subdirectory_arrow_right_rounded,
      '하위 추가',
    ),
    TodoMenuAction.edit => (Icons.edit_outlined, '편집'),
    TodoMenuAction.move => (Icons.drive_file_move_outline, '이동'),
    TodoMenuAction.copy => (Icons.copy_outlined, '복사'),
    TodoMenuAction.stopRecurrence => (Icons.repeat_rounded, '반복 중지'),
    TodoMenuAction.delete => (Icons.delete_outline_rounded, '삭제'),
  };

  List<PopupMenuEntry<TodoMenuAction>> popupItems(
    BuildContext context,
    List<TodoMenuAction> actions,
  ) {
    final error = Theme.of(context).colorScheme.error;
    return [
      for (final a in actions)
        PopupMenuItem(
          key: ValueKey('todo-tile-menu-item-${a.name}'),
          value: a,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              describe(a).$1,
              size: 18,
              color: a == TodoMenuAction.delete ? error : null,
            ),
            title: Text(
              describe(a).$2,
              style: a == TodoMenuAction.delete
                  ? TextStyle(color: error)
                  : null,
            ),
          ),
        ),
    ];
  }

  /// 데스크탑 우클릭 — 커서 위치에 전체 메뉴. 고른 항목을 실행한다.
  Future<void> showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final list = actions(includeQuick: true);
    if (list.isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final picked = await showMenu<TodoMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: popupItems(context, list),
    );
    if (picked != null) run(picked);
  }

  /// 폰 길게 누르기 — 아래에서 올라오는 메뉴 시트.
  ///
  /// [navigator] 로 띄운다 — 순서 이동 목록에서는 길게 누르는 순간 드래그가 시작되며
  /// 누른 줄이 트리에서 빠지므로, 누를 때 잡아 둔 Navigator 가 필요하다.
  Future<void> showSheet(NavigatorState navigator) async {
    final list = actions(includeQuick: true);
    if (list.isEmpty || !navigator.mounted) return;
    final picked = await showModalBottomSheet<TodoMenuAction>(
      context: navigator.context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final error = theme.colorScheme.error;
        // 항목이 많거나 화면이 낮아도 넘치지 않게 스크롤.
        return SafeArea(
          child: SingleChildScrollView(
            key: const ValueKey('todo-tile-menu-sheet'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.space24,
                    0,
                    AppTokens.space24,
                    AppTokens.space8,
                  ),
                  child: Text(
                    todo.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (final a in list)
                  ListTile(
                    key: ValueKey('todo-tile-sheet-${a.name}'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppTokens.space24,
                    ),
                    leading: Icon(
                      describe(a).$1,
                      color: a == TodoMenuAction.delete ? error : null,
                    ),
                    title: Text(
                      describe(a).$2,
                      style: a == TodoMenuAction.delete
                          ? TextStyle(color: error)
                          : null,
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(a),
                  ),
                const SizedBox(height: AppTokens.space8),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) run(picked);
  }
}
