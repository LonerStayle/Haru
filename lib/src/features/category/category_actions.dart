import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../ui/widgets/undo_snackbar.dart';
import 'add_category_dialog.dart';
import 'add_group_dialog.dart';
import 'categories_controller.dart';
import 'groups_controller.dart';

/// 카테고리 메뉴 항목.
enum CategoryMenuAction { edit, move, archive, delete }

/// 그룹 메뉴 항목.
enum GroupMenuAction { open, edit, addCategory, archive, delete }

/// 카테고리·그룹 관리 동작 한 벌 — 데스크탑 사이드바, 모바일 카테고리 목록,
/// 카테고리 화면 헤더 ⋮ 가 같은 메뉴·다이얼로그·문구를 쓴다.
///
/// 예전엔 셸과 관리 Drawer 가 각자 복제해 들고 있어 문구·동작이 어긋났다
/// (그룹 삭제 항목 이름, 같은 그룹으로 '이동' 시 불필요한 쓰기 등).
///
/// 호출 context 는 메뉴가 닫히는 사이 사라질 수 있다(목록 행 등). 그래서 시작할 때
/// [ProviderContainer] 와 [ScaffoldMessengerState] 를 잡아 두고 그걸로 끝까지 간다.
class CategoryActions {
  CategoryActions._(this._context, this._container, this._messenger);

  factory CategoryActions.of(BuildContext context) => CategoryActions._(
    context,
    ProviderScope.containerOf(context, listen: false),
    ScaffoldMessenger.maybeOf(context),
  );

  final BuildContext _context;
  final ProviderContainer _container;
  final ScaffoldMessengerState? _messenger;

  CategoriesController get _categories =>
      _container.read(categoriesControllerProvider);
  GroupsController get _groups => _container.read(groupsControllerProvider);

  // ───────────────────────── 메뉴 ─────────────────────────

  /// 카테고리 메뉴 — [position] 이 있으면 커서 위치 팝업(데스크탑 우클릭), 없으면
  /// 아래에서 올라오는 시트(폰 길게 누르기·⋮).
  Future<void> showCategoryMenu(Category category, {Offset? position}) async {
    final picked = await _pick<CategoryMenuAction>(
      position: position,
      entries: [
        (CategoryMenuAction.edit, Icons.edit_outlined, '이름·색·아이콘 수정', null),
        (
          CategoryMenuAction.move,
          Icons.drive_file_move_outlined,
          '그룹 이동',
          null,
        ),
        (
          CategoryMenuAction.archive,
          Icons.inventory_2_outlined,
          '보관',
          '할 일과 함께 숨겨요',
        ),
        (CategoryMenuAction.delete, Icons.delete_outline, '삭제', null),
      ],
      destructive: CategoryMenuAction.delete,
      keyPrefix: 'category-menu',
    );
    if (picked != null) await runCategory(picked, category);
  }

  Future<void> runCategory(CategoryMenuAction action, Category category) =>
      switch (action) {
        CategoryMenuAction.edit => editCategory(category),
        CategoryMenuAction.move => moveCategory(category),
        CategoryMenuAction.archive => archiveCategory(category),
        CategoryMenuAction.delete => deleteCategory(category),
      };

  /// 그룹 메뉴. [onOpen] 이 있으면 맨 위에 "전체보기에서 보기" 를 넣는다.
  Future<void> showGroupMenu(
    Group group, {
    Offset? position,
    VoidCallback? onOpen,
  }) async {
    final picked = await _pick<GroupMenuAction>(
      position: position,
      entries: [
        if (onOpen != null)
          (
            GroupMenuAction.open,
            Icons.account_tree_outlined,
            '전체보기에서 보기',
            null,
          ),
        (GroupMenuAction.edit, Icons.edit_outlined, '이름·색 수정', null),
        (GroupMenuAction.addCategory, Icons.add, '이 그룹에 카테고리 추가', null),
        (
          GroupMenuAction.archive,
          Icons.inventory_2_outlined,
          '보관',
          '카테고리·할 일까지 함께 숨겨요',
        ),
        (
          GroupMenuAction.delete,
          Icons.delete_outline,
          "'${group.label}' 그룹 삭제",
          null,
        ),
      ],
      destructive: GroupMenuAction.delete,
      keyPrefix: 'group-menu',
    );
    switch (picked) {
      case null:
        return;
      case GroupMenuAction.open:
        onOpen?.call();
      case GroupMenuAction.edit:
        await editGroup(group);
      case GroupMenuAction.addCategory:
        if (_context.mounted) {
          await AddCategoryDialog.show(_context, initialGroupId: group.id);
        }
      case GroupMenuAction.archive:
        await archiveGroup(group);
      case GroupMenuAction.delete:
        await deleteGroup(group);
    }
  }

  Future<T?> _pick<T extends Enum>({
    required Offset? position,
    required List<(T, IconData, String, String?)> entries,
    required T destructive,
    required String keyPrefix,
  }) async {
    if (!_context.mounted) return null;
    final error = Theme.of(_context).colorScheme.error;
    if (position != null) {
      final overlay =
          Overlay.of(_context).context.findRenderObject()! as RenderBox;
      return showMenu<T>(
        context: _context,
        position: RelativeRect.fromRect(
          position & const Size(1, 1),
          Offset.zero & overlay.size,
        ),
        items: [
          for (final (value, icon, label, _) in entries)
            PopupMenuItem<T>(
              key: ValueKey('$keyPrefix-${value.name}'),
              value: value,
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: value == destructive ? error : null,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    label,
                    style: value == destructive
                        ? TextStyle(color: error)
                        : null,
                  ),
                ],
              ),
            ),
        ],
      );
    }
    return showModalBottomSheet<T>(
      context: _context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (value, icon, label, subtitle) in entries)
                ListTile(
                  key: ValueKey('$keyPrefix-${value.name}'),
                  leading: Icon(
                    icon,
                    color: value == destructive ? error : null,
                  ),
                  title: Text(
                    label,
                    style: value == destructive
                        ? TextStyle(color: error)
                        : null,
                  ),
                  subtitle: subtitle == null ? null : Text(subtitle),
                  onTap: () => Navigator.of(ctx).pop(value),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────────────── 카테고리 ─────────────────────────

  Future<void> editCategory(Category category) async {
    if (!_context.mounted) return;
    await AddCategoryDialog.showEdit(_context, category);
  }

  /// 그룹 고르기 시트 → 이동 + 되돌리기. 같은 그룹을 고르면 아무것도 안 한다.
  Future<void> moveCategory(Category category) async {
    if (!_context.mounted) return;
    final groups =
        _container.read(activeGroupsProvider).asData?.value ?? const <Group>[];
    final picked = await showModalBottomSheet<_GroupChoice>(
      context: _context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const ValueKey('move-category-to-none'),
                leading: const Icon(Icons.layers_clear_outlined),
                title: const Text('미분류'),
                selected: category.groupId == null,
                trailing: category.groupId == null
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(ctx).pop(const _GroupChoice(null)),
              ),
              for (final g in groups)
                ListTile(
                  key: ValueKey('move-category-to-${g.id}'),
                  leading: Icon(Icons.circle, size: 14, color: g.color),
                  title: Text(g.label),
                  selected: category.groupId == g.id,
                  trailing: category.groupId == g.id
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.of(ctx).pop(_GroupChoice(g.id)),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    await moveCategoryToGroup(category, picked.groupId, groups: groups);
  }

  /// 카테고리를 [groupId] 그룹(null = 미분류)으로 옮기고 되돌리기 스낵바.
  /// 드래그 드롭도 이 길을 쓴다.
  Future<void> moveCategoryToGroup(
    Category category,
    String? groupId, {
    List<Group>? groups,
  }) async {
    final before = category.groupId;
    if (before == groupId) return;
    await _categories.moveToGroup(category.id, groupId);
    final all =
        groups ??
        _container.read(activeGroupsProvider).asData?.value ??
        const <Group>[];
    String nameOf(String? id) {
      if (id == null) return '미분류';
      for (final g in all) {
        if (g.id == id) return g.label;
      }
      return '미분류';
    }

    final messenger = _messenger;
    if (messenger == null || !messenger.mounted) return;
    showUndoSnackbarOn(
      messenger,
      message: "'${category.label}' → ${nameOf(groupId)}(으)로 옮겼어요.",
      onUndo: () => _categories.moveToGroup(category.id, before),
    );
  }

  Future<void> archiveCategory(Category category) async {
    await _categories.archive(category.id);
    final messenger = _messenger;
    if (messenger == null || !messenger.mounted) return;
    showUndoSnackbarOn(
      messenger,
      message: '${category.label} 카테고리를 보관했어요.',
      onUndo: () => _categories.unarchive(category.id),
    );
  }

  /// 삭제 확인 → 삭제. 할 일이 남아 있어 막히면 "대신 보관" 을 제안한다.
  /// 반환: 실제로 삭제됐는지.
  Future<bool> deleteCategory(Category category) async {
    if (!_context.mounted) return false;
    final confirmed =
        await showDialog<bool>(
          context: _context,
          builder: (ctx) => AlertDialog(
            title: Text('${category.label} 카테고리 삭제'),
            content: const Text('이 카테고리를 정말 삭제할까요? 되돌릴 수 없어요.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                key: const ValueKey('confirm-delete-category'),
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                ),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return false;

    final result = await _categories.delete(category.id);
    if (result.isOk) {
      final messenger = _messenger;
      if (messenger != null && messenger.mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('${category.label} 카테고리가 삭제되었어요.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return true;
    }

    final count = await _container
        .read(categoriesRepositoryProvider)
        .countTodosOfCategory(category.id);
    if (!_context.mounted) return false;
    final archiveInstead =
        await showDialog<bool>(
          context: _context,
          builder: (ctx) => AlertDialog(
            title: const Text('삭제할 수 없어요'),
            content: Text(
              '이 카테고리에 할 일이 $count개 있어요.\n'
              '할 일을 다른 카테고리로 옮긴 뒤 삭제하거나, 대신 보관할 수 있어요.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('닫기'),
              ),
              FilledButton.tonal(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('대신 보관'),
              ),
            ],
          ),
        ) ??
        false;
    if (archiveInstead) await archiveCategory(category);
    return false;
  }

  // ───────────────────────── 그룹 ─────────────────────────

  Future<void> editGroup(Group group) async {
    if (!_context.mounted) return;
    await AddGroupDialog.showEdit(_context, group);
  }

  Future<void> archiveGroup(Group group) async {
    await _groups.archive(group.id);
    final messenger = _messenger;
    if (messenger == null || !messenger.mounted) return;
    showUndoSnackbarOn(
      messenger,
      message: "'${group.label}' 그룹을 보관했어요. (카테고리·할 일 포함)",
      onUndo: () => _groups.unarchive(group.id),
    );
  }

  /// 그룹 삭제 — 확인 후 삭제. 속한 카테고리는 미분류로 옮겨진다(데이터 무손실).
  Future<bool> deleteGroup(Group group) async {
    if (!_context.mounted) return false;
    final confirmed =
        await showDialog<bool>(
          context: _context,
          builder: (ctx) => AlertDialog(
            title: Text("'${group.label}' 그룹 삭제"),
            content: const Text(
              '그룹을 삭제하면 속한 카테고리는 \'미분류\'로 이동돼요. 카테고리와 할 일은 그대로 남아요.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                key: const ValueKey('confirm-delete-group'),
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                ),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return false;
    await _groups.delete(group.id);
    final messenger = _messenger;
    if (messenger != null && messenger.mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text("'${group.label}' 그룹이 삭제됐어요. 카테고리는 미분류로 이동했어요."),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return true;
  }
}

/// 그룹 선택 결과 (미분류 = null).
class _GroupChoice {
  const _GroupChoice(this.groupId);
  final String? groupId;
}
