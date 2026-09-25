import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/policies/stale_backlog_policy.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/undo_snackbar.dart';
import '../calendar_view/calendar_drag.dart';
import '../category/categories_controller.dart';
import '../outline/tree_providers.dart';
import '../todo_actions/todo_actions_controller.dart';
import '../todo_actions/todo_row_actions.dart';

/// 30일 넘게 남아 있는 미완료 최상위 할 일 — [StaleBacklogPolicy].
final staleBacklogProvider = Provider<List<Todo>>((ref) {
  final all = ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
  final active = ref.watch(activeCategoriesProvider).asData?.value;
  if (active == null) return const [];
  return StaleBacklogPolicy.select(
    all,
    activeCategoryIds: {for (final c in active) c.id},
    now: ref.watch(nowProvider)(),
  );
});

/// "오래된 할 일" 정리 화면 — 한 달 넘게 남은 백로그를 골라 한 번에 완료·날짜 지정·삭제.
///
/// 아무것도 자동으로 바꾸지 않는다. 고른 것만, 누른 동작만, 되돌리기(⌘Z)와 함께.
/// 항목을 누르면 상세(다른 목록과 같은 규칙).
class StaleBacklogScreen extends ConsumerStatefulWidget {
  const StaleBacklogScreen({super.key});

  static Future<void> show(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const StaleBacklogScreen()));

  @override
  ConsumerState<StaleBacklogScreen> createState() => _StaleBacklogScreenState();
}

class _StaleBacklogScreenState extends ConsumerState<StaleBacklogScreen> {
  final Set<String> _selected = {};

  List<Todo> _picked(List<Todo> items) => [
    for (final t in items)
      if (_selected.contains(t.id)) t,
  ];

  Future<void> _complete(List<Todo> picked) async {
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(todoActionsProvider);
    for (final t in picked) {
      await actions.toggle(t);
    }
    setState(_selected.clear);
    showUndoSnackbarOn(
      messenger,
      message: '${picked.length}개를 완료했어요.',
      onUndo: () => actions.restoreAll(picked),
    );
  }

  Future<void> _schedule(List<Todo> picked, DateTime day, String label) async {
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(todoActionsProvider);
    for (final t in picked) {
      await actions.updatePreservingOrder(applyDateDrop(t, day));
    }
    setState(_selected.clear);
    showUndoSnackbarOn(
      messenger,
      message: '${picked.length}개를 $label(으)로 옮겼어요.',
      onUndo: () => actions.restoreAll(picked),
    );
  }

  Future<void> _delete(List<Todo> picked) async {
    final all = ref.read(allTodosProvider).asData?.value;
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('${picked.length}개 삭제'),
            content: const Text('하위 항목도 함께 지워져요. 바로 되돌릴 수 있어요.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                key: const ValueKey('stale-confirm-delete'),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(todoActionsProvider);
    final snapshot = <Todo>[];
    for (final t in picked) {
      snapshot.addAll(await actions.deleteTree(t, all: all));
    }
    setState(_selected.clear);
    showUndoSnackbarOn(
      messenger,
      message: '${picked.length}개를 삭제했어요.',
      onUndo: () => actions.restoreDeleted(snapshot),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = ref.watch(staleBacklogProvider);
    final all = ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
    final now = ref.watch(nowProvider)();
    // 목록에서 사라진(다른 곳에서 완료·삭제된) 항목은 선택에서도 뺀다.
    _selected.retainAll({for (final t in items) t.id});
    final picked = _picked(items);
    final allSelected = items.isNotEmpty && picked.length == items.length;

    final childCounts = <String, int>{};
    for (final t in all) {
      final pid = t.parentId;
      if (pid != null) childCounts[pid] = (childCounts[pid] ?? 0) + 1;
    }

    final today = DateTime(now.year, now.month, now.day);
    // 다음 주 월요일.
    final nextMonday = today.add(Duration(days: 8 - today.weekday));

    return Scaffold(
      appBar: AppBar(
        title: const Text('오래된 할 일'),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              key: const ValueKey('stale-select-all'),
              onPressed: () => setState(() {
                allSelected
                    ? _selected.clear()
                    : _selected.addAll(items.map((t) => t.id));
              }),
              child: Text(allSelected ? '선택 해제' : '모두 선택'),
            ),
        ],
      ),
      body: items.isEmpty
          ? const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: '오래된 할 일이 없어요',
              subtitle: '한 달 넘게 남아 있는 할 일이 생기면 여기에 모여요.',
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.space8,
                    AppTokens.space8,
                    AppTokens.space8,
                    AppTokens.space48,
                  ),
                  itemCount: items.length + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppTokens.space12,
                          AppTokens.space4,
                          AppTokens.space12,
                          AppTokens.space12,
                        ),
                        child: Text(
                          '만든 지 ${StaleBacklogPolicy.defaultDays}일 넘은 미완료 '
                          '${items.length}개 · 오래된 순. 골라서 한 번에 정리하세요.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    }
                    final t = items[i - 1];
                    return _StaleRow(
                      todo: t,
                      age: StaleBacklogPolicy.ageInDays(t, now),
                      childCount: childCounts[t.id] ?? 0,
                      selected: _selected.contains(t.id),
                      onSelected: (v) => setState(() {
                        v ? _selected.add(t.id) : _selected.remove(t.id);
                      }),
                      onOpen: () => openTodoDetail(context, t),
                    );
                  },
                ),
              ),
            ),
      bottomNavigationBar: picked.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppTokens.space12),
                child: Wrap(
                  key: const ValueKey('stale-action-bar'),
                  alignment: WrapAlignment.center,
                  spacing: AppTokens.space8,
                  runSpacing: AppTokens.space8,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('stale-complete'),
                      onPressed: () => _complete(picked),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text('완료 ${picked.length}'),
                    ),
                    OutlinedButton(
                      key: const ValueKey('stale-today'),
                      onPressed: () => _schedule(picked, today, '오늘'),
                      child: const Text('오늘로'),
                    ),
                    OutlinedButton(
                      key: const ValueKey('stale-next-week'),
                      onPressed: () =>
                          _schedule(picked, nextMonday, '다음 주 월요일'),
                      child: const Text('다음 주 월'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('stale-delete'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      onPressed: () => _delete(picked),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('삭제'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _StaleRow extends StatelessWidget {
  const _StaleRow({
    required this.todo,
    required this.age,
    required this.childCount,
    required this.selected,
    required this.onSelected,
    required this.onOpen,
  });

  final Todo todo;
  final int age;
  final int childCount;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final meta = [
      todo.category.label,
      '$age일 전',
      if (childCount > 0) '하위 $childCount',
    ].join(' · ');
    return Material(
      key: ValueKey('stale-row-${todo.id}'),
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(AppTokens.radiusM),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppTokens.space4),
          child: Row(
            children: [
              Checkbox(
                key: ValueKey('stale-select-${todo.id}'),
                value: selected,
                onChanged: (v) => onSelected(v ?? false),
              ),
              Icon(todo.category.icon, size: 18, color: todo.category.color),
              const SizedBox(width: AppTokens.space8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      todo.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      meta,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppTokens.space8),
            ],
          ),
        ),
      ),
    );
  }
}
