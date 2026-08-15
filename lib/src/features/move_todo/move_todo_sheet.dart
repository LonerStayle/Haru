import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/category.dart';
import '../../domain/policies/move_policy.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/undo_snackbar.dart';
import '../category/categories_controller.dart';
import '../outline/tree_providers.dart';
import '../todo_actions/todo_actions_controller.dart';

/// 할 일 이동 flow — 타일 ⋮ 메뉴 '이동' / 편집 시트 '위치 변경' 의 공통 진입점.
///
/// [MoveTodoSheet] 로 목적지를 고르게 한 뒤 실제 이동은
/// [TodoActionsController.moveTo] 에 맡기고, 되돌리기 SnackBar 까지 띄운다.
Future<void> showMoveTodoSheet(
  BuildContext context,
  WidgetRef ref, {
  required Todo item,
}) async {
  final destination = await showModalBottomSheet<MoveDestination>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => MoveTodoSheet(item: item),
  );
  if (destination == null || !context.mounted) return;

  final all = ref.read(allTodosProvider).asData?.value ?? const <Todo>[];
  // 시트를 여는 사이 그 row 가 바뀌었을 수 있다 (편집 시트의 '위치 변경' 은 닫히면서
  // 자동 저장을 돌린다). 화면이 들고 있던 스냅샷으로 옮기면 그 저장이 통째로 되돌아가고,
  // 판정(제자리/사이클)도 옛 값 기준이 되어 어긋난다 — 항상 최신 row 로 옮긴다.
  final live = all.firstWhere((t) => t.id == item.id, orElse: () => item);
  final actions = ref.read(todoActionsProvider);
  // 되돌리기 스냅샷 — 이동으로 바뀌는 row 는 본인 + (카테고리가 달라지면) 자손 전부.
  final snapshot = <Todo>[live, ...MovePolicy.descendants(live.id, all)];

  final moved = await actions.moveTo(
    live,
    newParent: destination.parent,
    targetCategory: destination.category,
    all: all,
  );
  if (!context.mounted) return;

  final parent = destination.parent;
  // 거부됐는데 아무 말도 안 하면 "눌렀는데 그대로" 로만 보인다 — 왜 안 옮겨졌는지 알린다.
  if (!moved) {
    final blocked = !MovePolicy.canMove(
      item: live,
      newParentId: parent?.id,
      all: all,
    );
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            blocked
                ? '자기 자신이나 그 하위로는 옮길 수 없어요'
                : (parent == null
                      ? '이미 ${destination.category.label} 최상위에 있어요'
                      : '이미 "${parent.title}" 하위에 있어요'),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    return;
  }

  showUndoSnackbar(
    context,
    message: parent == null
        ? '"${live.title}" → ${destination.category.label} 최상위로 이동'
        : '"${live.title}" → "${parent.title}" 하위로 이동',
    onUndo: () => actions.restoreAll(snapshot),
  );
}

/// [MoveTodoSheet] 가 돌려주는 목적지.
class MoveDestination {
  const MoveDestination({required this.parent, required this.category});

  /// 이동해 들어갈 상위 할 일. null 이면 [category] 의 최상위(root)로.
  final Todo? parent;

  /// 최상위 이동 시의 목적지 카테고리. [parent] 가 있으면 부모 카테고리가 이긴다.
  final Category category;
}

/// 이동 대상(상위 할 일 또는 최상위)을 고르는 시트.
///
/// - 카테고리 칩으로 어느 트리를 볼지 고르고, 그 아래 트리에서 목적지를 탭한다.
/// - 검색어를 넣으면 카테고리와 무관하게 전체에서 제목으로 찾고 경로를 함께 보여준다.
/// - 자기 자신과 자손은 목록에 남기되 비활성 — 왜 못 고르는지 보이는 편이 낫다.
class MoveTodoSheet extends ConsumerStatefulWidget {
  const MoveTodoSheet({super.key, required this.item});

  /// 이동할 항목 (서브트리 통째로 따라간다).
  final Todo item;

  @override
  ConsumerState<MoveTodoSheet> createState() => _MoveTodoSheetState();
}

class _MoveTodoSheetState extends ConsumerState<MoveTodoSheet> {
  /// 트리를 펼쳐 볼 카테고리 + 최상위 이동 시의 목적지.
  late Category _category;

  /// 선택된 목적지 부모 id. null = "최상위로".
  String? _parentId;

  late final TextEditingController _searchCtrl;
  String _query = '';

  @override
  void initState() {
    super.initState();
    // 호출자가 넘긴 스냅샷은 화면이 들고 있던 옛 값일 수 있다 (편집 시트의 '위치 변경'
    // 은 닫히면서 자동 저장을 돌린다). 초기 선택·판정 모두 최신 row 기준이어야
    // 확정 버튼은 켜져 있는데 실제로는 제자리라 아무 일도 안 일어나는 어긋남이 없다.
    final live = _live();
    _category = live.category;
    // 처음 열었을 때는 현재 부모가 선택된 상태 — "어디에 있는지" 부터 보여준다.
    _parentId = live.parentId;
    _searchCtrl = TextEditingController();
  }

  /// 이동 대상의 최신 상태. 아직 목록에 없으면 넘겨받은 스냅샷 그대로.
  Todo _live([List<Todo>? all]) {
    final list =
        all ?? ref.read(allTodosProvider).asData?.value ?? const <Todo>[];
    return list.firstWhere(
      (t) => t.id == widget.item.id,
      orElse: () => widget.item,
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 목록·트리 정렬 — TodosDao 의 정렬 키와 같은 순서 (화면에서 보던 순서 유지).
  static int _compare(Todo a, Todo b) {
    final s = a.sortOrder.compareTo(b.sortOrder);
    if (s != 0) return s;
    final u = b.updatedAt.compareTo(a.updatedAt);
    if (u != 0) return u;
    final c = b.createdAt.compareTo(a.createdAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  }

  /// 이동 대상이 될 수 없는 id — 자기 자신 + 자손 (사이클 방지, [MovePolicy] 와 동일 규칙).
  Set<String> _blockedIds(List<Todo> all) => {
    widget.item.id,
    ...MovePolicy.descendants(widget.item.id, all).map((t) => t.id),
  };

  /// 지금 선택이 실제 이동인가 (아무 변화 없으면 확정 버튼 비활성).
  ///
  /// 판정 기준은 **최신 row** — 호출자 스냅샷으로 재면 "버튼은 켜졌는데 눌러도
  /// 제자리라 아무 일도 안 일어나는" 상태가 된다.
  bool _canConfirmWith(List<Todo> all, Todo live) {
    final dest = _destination(all);
    final parentId = dest.parent?.id;
    final categoryId = dest.parent?.category.id ?? dest.category.id;
    if (!MovePolicy.canMove(item: live, newParentId: parentId, all: all)) {
      return false;
    }
    return !MovePolicy.isNoop(
      item: live,
      newParentId: parentId,
      newCategoryId: categoryId,
    );
  }

  /// 선택 카테고리의 트리를 DFS 로 평탄화한 행 목록.
  List<_TargetRow> _treeRows(List<Todo> all) {
    final blocked = _blockedIds(all);
    final byParent = <String, List<Todo>>{};
    final roots = <Todo>[];
    for (final t in all) {
      // 반복 시리즈 마스터는 어느 목록에도 안 보이는 숨김 템플릿 — 대상에서 제외.
      if (t.isSeriesMaster) continue;
      final pid = t.parentId;
      if (pid == null) {
        if (t.category.id == _category.id) roots.add(t);
      } else {
        (byParent[pid] ??= []).add(t);
      }
    }
    roots.sort(_compare);

    final rows = <_TargetRow>[];
    // 손상 데이터(사이클)에서도 무한 재귀에 빠지지 않도록 방문 집합을 둔다.
    final visited = <String>{};
    void walk(Todo node, int depth) {
      if (!visited.add(node.id)) return;
      final children = [...?byParent[node.id]]..sort(_compare);
      rows.add(
        _TargetRow(
          todo: node,
          depth: depth,
          childCount: children.length,
          disabled: blocked.contains(node.id),
        ),
      );
      for (final c in children) {
        walk(c, depth + 1);
      }
    }

    for (final r in roots) {
      walk(r, 0);
    }
    return rows;
  }

  /// 검색 모드 — 카테고리 무관 전체에서 제목 매칭. 경로를 함께 보여 준다.
  List<_TargetRow> _searchRows(List<Todo> all) {
    final blocked = _blockedIds(all);
    final q = _query.trim().toLowerCase();
    final counts = <String, int>{};
    for (final t in all) {
      final pid = t.parentId;
      if (pid != null) counts[pid] = (counts[pid] ?? 0) + 1;
    }
    final matched =
        all
            .where(
              (t) => !t.isSeriesMaster && t.title.toLowerCase().contains(q),
            )
            .toList()
          ..sort(_compare);
    return [
      for (final t in matched)
        _TargetRow(
          todo: t,
          depth: 0,
          childCount: counts[t.id] ?? 0,
          disabled: blocked.contains(t.id),
          path: computeTodoPath(t, all).map((p) => p.title).toList(),
        ),
    ];
  }

  /// 확정 시 돌려줄 목적지. 선택한 부모가 목록에서 사라졌으면 최상위로 안전 fallback.
  MoveDestination _destination(List<Todo> all) {
    final pid = _parentId;
    if (pid == null) return MoveDestination(parent: null, category: _category);
    final parent = all.where((t) => t.id == pid).firstOrNull;
    return parent == null
        ? MoveDestination(parent: null, category: _category)
        : MoveDestination(parent: parent, category: parent.category);
  }

  void _selectCategory(Category c) {
    setState(() {
      _category = c;
      // 다른 트리로 넘어가면 이전 선택은 의미가 없다 → 그 카테고리 최상위로 리셋.
      _parentId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final all = ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
    final categories =
        ref.watch(activeCategoriesProvider).asData?.value ??
        Category.builtinSeeds;
    final searching = _query.trim().isNotEmpty;
    final rows = searching ? _searchRows(all) : _treeRows(all);
    final live = _live(all);
    final canConfirm = _canConfirmWith(all, live);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Material(
        color: scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppTokens.radiusL),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Shortcuts(
            shortcuts: <ShortcutActivator, Intent>{
              const SingleActivator(LogicalKeyboardKey.escape):
                  const _CloseIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                _CloseIntent: CallbackAction<_CloseIntent>(
                  onInvoke: (_) {
                    Navigator.of(context).maybePop();
                    return null;
                  },
                ),
              },
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: AppTokens.space12),
                    _Grabber(color: scheme.outline),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppTokens.space24,
                        AppTokens.space16,
                        AppTokens.space24,
                        0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '이동',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: AppTokens.space4),
                          _MovingItemLine(item: live),
                          const SizedBox(height: AppTokens.space12),
                          TextField(
                            key: const ValueKey('move-search'),
                            controller: _searchCtrl,
                            onChanged: (v) => setState(() => _query = v),
                            textInputAction: TextInputAction.search,
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '대상 찾기',
                              prefixIcon: const Icon(Icons.search, size: 18),
                              suffixIcon: searching
                                  ? IconButton(
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 18,
                                      ),
                                      tooltip: '검색 비우기',
                                      onPressed: () {
                                        _searchCtrl.clear();
                                        setState(() => _query = '');
                                      },
                                    )
                                  : null,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          if (!searching) ...[
                            const SizedBox(height: AppTokens.space12),
                            _CategoryChipRow(
                              categories: categories,
                              selected: _category,
                              onSelect: _selectCategory,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: AppTokens.space8),
                    const Divider(height: 1),
                    Flexible(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppTokens.space8,
                        ),
                        children: [
                          // 검색 중에도 "최상위로" 는 항상 고를 수 있게 맨 위에 둔다.
                          _RootRow(
                            category: _category,
                            selected: _parentId == null,
                            onTap: () => setState(() => _parentId = null),
                          ),
                          if (rows.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(AppTokens.space24),
                              child: Text(
                                searching
                                    ? '"${_query.trim()}" 와 맞는 항목이 없어요'
                                    : '${_category.label} 에 아직 항목이 없어요',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          else
                            for (final row in rows)
                              _TargetTile(
                                row: row,
                                selected: _parentId == row.todo.id,
                                onTap: row.disabled
                                    ? null
                                    : () => setState(
                                        () => _parentId = row.todo.id,
                                      ),
                              ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppTokens.space24,
                        AppTokens.space12,
                        AppTokens.space24,
                        AppTokens.space16,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _DestinationSummary(
                              destination: _destination(all),
                            ),
                          ),
                          const SizedBox(width: AppTokens.space12),
                          TextButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            child: const Text('취소'),
                          ),
                          const SizedBox(width: AppTokens.space8),
                          FilledButton(
                            key: const ValueKey('move-confirm'),
                            onPressed: canConfirm
                                ? () => Navigator.of(
                                    context,
                                  ).pop(_destination(all))
                                : null,
                            child: const Text('여기로 이동'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CloseIntent extends Intent {
  const _CloseIntent();
}

/// 평탄화된 이동 대상 한 줄.
class _TargetRow {
  const _TargetRow({
    required this.todo,
    required this.depth,
    required this.childCount,
    required this.disabled,
    this.path = const [],
  });

  final Todo todo;

  /// 트리 들여쓰기 단계 (검색 모드에서는 항상 0, 대신 [path] 로 위치를 보여 준다).
  final int depth;
  final int childCount;

  /// 자기 자신·자손이라 목적지가 될 수 없는 행.
  final bool disabled;

  /// 검색 모드의 상위 경로 제목들 (root → 직속 부모).
  final List<String> path;
}

/// "이동할 항목: ○○" 한 줄 — 지금 무엇을 옮기는지 계속 보이게.
class _MovingItemLine extends StatelessWidget {
  const _MovingItemLine({required this.item});

  final Todo item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Icon(
          Icons.drag_indicator_rounded,
          size: 16,
          color: item.category.color,
        ),
        const SizedBox(width: AppTokens.space4),
        Expanded(
          child: Text(
            item.title,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// 카테고리 선택 칩 — 가로 스크롤 한 줄. 어느 트리에서 대상을 고를지 + 최상위 목적지.
class _CategoryChipRow extends StatelessWidget {
  const _CategoryChipRow({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final List<Category> categories;
  final Category selected;
  final ValueChanged<Category> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final c in categories)
            Padding(
              padding: const EdgeInsets.only(right: AppTokens.space8),
              child: Material(
                color: c.id == selected.id
                    ? c.color.withValues(alpha: 0.22)
                    : theme.colorScheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                  side: c.id == selected.id
                      ? BorderSide(color: c.color, width: 1.6)
                      : BorderSide.none,
                ),
                child: InkWell(
                  key: ValueKey('move-category-${c.id}'),
                  onTap: () => onSelect(c),
                  borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTokens.space12,
                      vertical: AppTokens.space8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(c.icon, size: 16, color: c.color),
                        const SizedBox(width: AppTokens.space8),
                        Text(
                          c.label,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: c.id == selected.id
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "⤴ 최상위로" 행 — 하위 → 상위 이동 경로.
class _RootRow extends StatelessWidget {
  const _RootRow({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final Category category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      key: const ValueKey('move-target-root'),
      onTap: onTap,
      child: Container(
        color: selected ? category.color.withValues(alpha: 0.12) : null,
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space24,
          vertical: AppTokens.space12,
        ),
        child: Row(
          children: [
            Icon(
              Icons.north_west_rounded,
              size: 18,
              color: selected ? category.color : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppTokens.space12),
            Expanded(
              child: Text(
                '최상위로 (${category.label} 직속)',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? category.color : null,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check_circle_rounded, size: 18, color: category.color),
          ],
        ),
      ),
    );
  }
}

/// 이동 대상 한 줄 — 들여쓰기 + 제목 + 하위 개수. 자기 자신·자손은 비활성.
class _TargetTile extends StatelessWidget {
  const _TargetTile({required this.row, required this.selected, this.onTap});

  final _TargetRow row;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final todo = row.todo;
    final accent = todo.category.color;
    final isNote = todo.type == TodoType.note;
    final muted = row.disabled;

    return InkWell(
      key: ValueKey('move-target-${todo.id}'),
      onTap: onTap,
      child: Opacity(
        opacity: muted ? 0.4 : 1,
        child: Container(
          color: selected ? accent.withValues(alpha: 0.12) : null,
          padding: EdgeInsets.fromLTRB(
            AppTokens.space24 + row.depth * AppTokens.space16,
            AppTokens.space12,
            AppTokens.space24,
            AppTokens.space12,
          ),
          child: Row(
            children: [
              Icon(
                isNote
                    ? Icons.sticky_note_2_outlined
                    : (row.childCount > 0
                          ? Icons.folder_outlined
                          : Icons.check_circle_outline_rounded),
                size: 18,
                color: selected ? accent : accent.withValues(alpha: 0.7),
              ),
              const SizedBox(width: AppTokens.space12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      todo.title,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: selected ? accent : null,
                      ),
                    ),
                    // 검색 결과는 들여쓰기로 위치를 알 수 없으니 경로를 함께 보여 준다.
                    if (row.path.isNotEmpty)
                      Text(
                        '${todo.category.label} › ${row.path.join(' › ')}',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    if (muted)
                      Text(
                        '이동할 항목 자신이거나 그 하위예요',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (row.childCount > 0)
                Padding(
                  padding: const EdgeInsets.only(left: AppTokens.space8),
                  child: Text(
                    '${row.childCount}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(left: AppTokens.space8),
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: 18,
                    color: accent,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 하단 요약 — 지금 고른 목적지를 확정 전에 문장으로 한 번 더 보여 준다.
class _DestinationSummary extends StatelessWidget {
  const _DestinationSummary({required this.destination});

  final MoveDestination destination;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final parent = destination.parent;
    final text = parent == null
        ? '${destination.category.label} 최상위'
        : '"${parent.title}" 하위';
    return Text(
      text,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        ),
      ),
    );
  }
}
