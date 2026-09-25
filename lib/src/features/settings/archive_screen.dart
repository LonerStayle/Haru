import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/skeleton.dart';
import '../category/categories_controller.dart';
import '../category/groups_controller.dart';
import '../outline/tree_providers.dart';

/// 보관함 — 보관된 그룹/카테고리를 모아 보고 복원·영구 삭제하는 화면.
///
/// 그룹을 보관하면 소속 카테고리도 함께 보관(cascade)되므로, 보관된 그룹의 카테고리는
/// 그 그룹을 펼쳐서 본다(그룹째 복원 / 카테고리 하나만 미분류로 꺼내기).
/// '카테고리' 섹션에는 개별 보관된 카테고리(활성 그룹·미분류 소속)만.
///
/// 영구 삭제는 기존 삭제 규칙을 그대로 따른다 — 할 일이 남은 카테고리는 지울 수 없다
/// (할 일을 조용히 잃지 않게). 비어 있을 때만, 확인을 받고 지운다.
class ArchiveScreen extends ConsumerWidget {
  const ArchiveScreen({super.key});

  static Future<void> show(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ArchiveScreen()));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    final groupsAsync = ref.watch(archivedGroupsProvider);
    final catsAsync = ref.watch(archivedCategoriesProvider);
    // 로딩 중엔 빈 상태 문구 대신 자리 표시 — "없음" 이 잠깐 보였다 바뀌지 않게.
    if (!groupsAsync.hasValue || !catsAsync.hasValue) {
      return Scaffold(
        appBar: AppBar(title: const Text('보관함')),
        body: const TodoListSkeleton(),
      );
    }
    final archivedGroups = groupsAsync.value ?? const <Group>[];
    final archivedCats = catsAsync.value ?? const <Category>[];
    final todos = ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
    final todoCount = <String, int>{};
    for (final t in todos) {
      if (t.isSeriesMaster) continue;
      todoCount.update(t.category.id, (v) => v + 1, ifAbsent: () => 1);
    }

    final archivedGroupIds = archivedGroups.map((g) => g.id).toSet();
    final standaloneCats = archivedCats
        .where(
          (c) => c.groupId == null || !archivedGroupIds.contains(c.groupId),
        )
        .toList();

    final isEmpty = archivedGroups.isEmpty && standaloneCats.isEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('보관함')),
      body: isEmpty
          ? _EmptyArchive(theme: theme)
          : ListView(
              padding: const EdgeInsets.only(bottom: AppTokens.space24),
              children: [
                if (archivedGroups.isNotEmpty) ...[
                  _sectionHeader(theme, '그룹'),
                  for (final g in archivedGroups)
                    _GroupTile(
                      group: g,
                      categories: archivedCats
                          .where((c) => c.groupId == g.id)
                          .toList(),
                      todoCount: todoCount,
                      onRestore: () => _restoreGroup(context, ref, g),
                      onRestoreCategory: (c) =>
                          _restoreCategoryOnly(context, ref, c),
                      onDelete: () => _deleteGroup(
                        context,
                        ref,
                        g,
                        archivedCats.where((c) => c.groupId == g.id).toList(),
                        todoCount,
                      ),
                    ),
                ],
                if (standaloneCats.isNotEmpty) ...[
                  _sectionHeader(theme, '카테고리'),
                  for (final c in standaloneCats)
                    _CategoryRow(
                      category: c,
                      todoCount: todoCount[c.id] ?? 0,
                      onRestore: () => _restoreCategory(context, ref, c),
                      onDelete: () => _deleteCategory(
                        context,
                        ref,
                        c,
                        todoCount[c.id] ?? 0,
                      ),
                    ),
                ],
              ],
            ),
    );
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _restoreGroup(
    BuildContext context,
    WidgetRef ref,
    Group group,
  ) async {
    await ref.read(groupsControllerProvider).unarchive(group.id);
    if (context.mounted) {
      _toast(context, "'${group.label}' 그룹을 복원했어요. (카테고리 포함)");
    }
  }

  Future<void> _restoreCategory(
    BuildContext context,
    WidgetRef ref,
    Category category,
  ) async {
    await ref.read(categoriesControllerProvider).unarchive(category.id);
    if (context.mounted) _toast(context, '${category.label} 카테고리를 복원했어요.');
  }

  /// 보관된 그룹에서 카테고리 하나만 — 미분류로 꺼낸다.
  Future<void> _restoreCategoryOnly(
    BuildContext context,
    WidgetRef ref,
    Category category,
  ) async {
    await ref
        .read(categoriesControllerProvider)
        .unarchiveToUngrouped(category.id);
    if (context.mounted) {
      _toast(context, '${category.label} 카테고리를 미분류로 복원했어요.');
    }
  }

  Future<bool> _confirmDelete(
    BuildContext context, {
    required String title,
    required String body,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            key: const ValueKey('archive-delete-confirm'),
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                key: const ValueKey('archive-delete-ok'),
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                ),
                child: const Text('영구 삭제'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _deleteCategory(
    BuildContext context,
    WidgetRef ref,
    Category category,
    int count,
  ) async {
    if (count > 0) {
      _toast(
        context,
        '${category.label}에 할 일 $count개가 남아 있어 지울 수 없어요. 복원해서 옮기거나 지운 뒤 다시 시도하세요.',
      );
      return;
    }
    final ok = await _confirmDelete(
      context,
      title: "'${category.label}' 카테고리를 영구 삭제할까요?",
      body: '비어 있는 카테고리예요. 삭제하면 되돌릴 수 없어요.',
    );
    if (!ok || !context.mounted) return;
    final result = await ref
        .read(categoriesControllerProvider)
        .delete(category.id);
    if (!context.mounted) return;
    _toast(
      context,
      result.isOk ? '${category.label} 카테고리를 삭제했어요.' : '할 일이 남아 있어 지울 수 없어요.',
    );
  }

  Future<void> _deleteGroup(
    BuildContext context,
    WidgetRef ref,
    Group group,
    List<Category> categories,
    Map<String, int> todoCount,
  ) async {
    final total = categories.fold<int>(
      0,
      (sum, c) => sum + (todoCount[c.id] ?? 0),
    );
    if (total > 0) {
      _toast(
        context,
        "'${group.label}' 그룹에 할 일 $total개가 남아 있어 지울 수 없어요. 복원해서 정리한 뒤 다시 시도하세요.",
      );
      return;
    }
    final ok = await _confirmDelete(
      context,
      title: "'${group.label}' 그룹을 영구 삭제할까요?",
      body: categories.isEmpty
          ? '삭제하면 되돌릴 수 없어요.'
          : '안의 빈 카테고리 ${categories.length}개도 함께 지워져요. 되돌릴 수 없어요.',
    );
    if (!ok || !context.mounted) return;
    final cats = ref.read(categoriesControllerProvider);
    for (final c in categories) {
      final result = await cats.delete(c.id);
      if (!result.isOk) {
        // 그사이 할 일이 생겼다(다른 기기 동기화 등) — 그룹은 남긴다.
        if (context.mounted) _toast(context, '할 일이 남아 있어 지울 수 없어요.');
        return;
      }
    }
    await ref.read(groupsControllerProvider).delete(group.id);
    if (context.mounted) _toast(context, "'${group.label}' 그룹을 삭제했어요.");
  }

  Widget _sectionHeader(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space16,
        AppTokens.space20,
        AppTokens.space16,
        AppTokens.space8,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _countLabel(int n) => n == 0 ? '비어 있음' : '할 일 $n개';

/// 보관된 그룹 — 펼치면 안의 카테고리를 보고 하나씩 꺼낼 수 있다.
class _GroupTile extends StatelessWidget {
  const _GroupTile({
    required this.group,
    required this.categories,
    required this.todoCount,
    required this.onRestore,
    required this.onRestoreCategory,
    required this.onDelete,
  });

  final Group group;
  final List<Category> categories;
  final Map<String, int> todoCount;
  final VoidCallback onRestore;
  final void Function(Category) onRestoreCategory;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final total = categories.fold<int>(
      0,
      (sum, c) => sum + (todoCount[c.id] ?? 0),
    );
    return ExpansionTile(
      key: ValueKey('archive-group-${group.id}'),
      leading: Icon(Icons.circle, size: 14, color: group.color),
      title: Text(group.label),
      subtitle: Text('카테고리 ${categories.length}개 · ${_countLabel(total)}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            key: ValueKey('restore-group-${group.id}'),
            onPressed: onRestore,
            icon: const Icon(Icons.unarchive_outlined, size: 18),
            label: const Text('복원'),
          ),
          _DeleteMenu(
            key: ValueKey('delete-group-${group.id}'),
            onDelete: onDelete,
          ),
        ],
      ),
      children: [
        for (final c in categories)
          ListTile(
            key: ValueKey('archive-group-cat-${c.id}'),
            contentPadding: const EdgeInsets.only(
              left: AppTokens.space48,
              right: AppTokens.space16,
            ),
            leading: Icon(c.icon, size: 18, color: c.color),
            title: Text(c.label),
            subtitle: Text(_countLabel(todoCount[c.id] ?? 0)),
            trailing: TextButton(
              key: ValueKey('restore-cat-only-${c.id}'),
              onPressed: () => onRestoreCategory(c),
              child: const Text('이것만 꺼내기'),
            ),
          ),
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.todoCount,
    required this.onRestore,
    required this.onDelete,
  });

  final Category category;
  final int todoCount;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(category.icon, size: 20, color: category.color),
      title: Text(category.label),
      subtitle: Text(_countLabel(todoCount)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            key: ValueKey('restore-cat-${category.id}'),
            onPressed: onRestore,
            icon: const Icon(Icons.unarchive_outlined, size: 18),
            label: const Text('복원'),
          ),
          _DeleteMenu(
            key: ValueKey('delete-cat-${category.id}'),
            onDelete: onDelete,
          ),
        ],
      ),
    );
  }
}

/// ⋮ → 영구 삭제. 버튼을 바로 두지 않는 건 복원 옆에서 잘못 누르지 않게.
class _DeleteMenu extends StatelessWidget {
  const _DeleteMenu({super.key, required this.onDelete});

  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: '더보기',
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (_) => onDelete(),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 0,
          child: Row(
            children: [
              Icon(
                Icons.delete_outline,
                size: 18,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: AppTokens.space8),
              const Text('영구 삭제'),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyArchive extends StatelessWidget {
  const _EmptyArchive({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 48,
              color: scheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: AppTokens.space16),
            Text(
              '보관된 항목이 없어요',
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: AppTokens.space8),
            Text(
              // 실제로 있는 통로만 가리킨다 (폰: 하단 '카테고리' 칸의 목록 화면 ⋮).
              AppPlatform.isDesktop
                  ? '사이드바에서 그룹·카테고리를 우클릭해 "보관"하면 여기 모여요.'
                  : '아래 "카테고리" 칸에서 카테고리의 ⋮ 를 눌러 "보관"하면 여기 모여요.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
