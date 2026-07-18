import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../category/categories_controller.dart';
import '../category/groups_controller.dart';

/// 보관함 — 보관된 그룹/카테고리를 모아 보고 복원하는 화면 (설정 > 보관함).
///
/// 그룹을 보관하면 소속 카테고리도 함께 보관(cascade)되므로, 보관된 그룹에 이미
/// 포함된 카테고리는 '카테고리' 섹션에서 제외한다 (그룹 복원으로 함께 살아남).
/// '카테고리' 섹션에는 개별 보관됐거나 활성 그룹/미분류에 속한 보관 카테고리만.
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

    final archivedGroups =
        ref.watch(archivedGroupsProvider).asData?.value ?? const <Group>[];
    final archivedCats =
        ref.watch(archivedCategoriesProvider).asData?.value ??
        const <Category>[];
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
                    _GroupRow(
                      group: g,
                      categoryCount: archivedCats
                          .where((c) => c.groupId == g.id)
                          .length,
                      onRestore: () => _restoreGroup(context, ref, g),
                    ),
                ],
                if (standaloneCats.isNotEmpty) ...[
                  _sectionHeader(theme, '카테고리'),
                  for (final c in standaloneCats)
                    _CategoryRow(
                      category: c,
                      onRestore: () => _restoreCategory(context, ref, c),
                    ),
                ],
              ],
            ),
    );
  }

  Future<void> _restoreGroup(
    BuildContext context,
    WidgetRef ref,
    Group group,
  ) async {
    await ref.read(groupsControllerProvider).unarchive(group.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("'${group.label}' 그룹을 복원했어요. (카테고리 포함)"),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _restoreCategory(
    BuildContext context,
    WidgetRef ref,
    Category category,
  ) async {
    await ref.read(categoriesControllerProvider).unarchive(category.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${category.label} 카테고리를 복원했어요.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
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

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.group,
    required this.categoryCount,
    required this.onRestore,
  });

  final Group group;
  final int categoryCount;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(Icons.circle, size: 14, color: group.color),
      title: Text(group.label),
      subtitle: categoryCount > 0 ? Text('카테고리 $categoryCount개') : null,
      trailing: TextButton.icon(
        key: ValueKey('restore-group-${group.id}'),
        onPressed: onRestore,
        icon: const Icon(Icons.unarchive_outlined, size: 18),
        label: const Text('복원'),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.category, required this.onRestore});

  final Category category;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(category.icon, size: 20, color: category.color),
      title: Text(category.label),
      trailing: TextButton.icon(
        key: ValueKey('restore-cat-${category.id}'),
        onPressed: onRestore,
        icon: const Icon(Icons.unarchive_outlined, size: 18),
        label: const Text('복원'),
      ),
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
            '그룹·카테고리를 길게 눌러 "보관"하면 여기 모여요.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }
}
