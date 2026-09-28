import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../core/ui_prefs.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../domain/todo.dart';
import '../../ui/shell_state.dart';
import '../../ui/widgets/dismissible_todo_tile.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/group_scope_chips.dart';
import '../../ui/widgets/todo_status_filter.dart';
import '../add_todo/add_todo_controller.dart';
import '../backlog/stale_backlog_screen.dart';
import '../category/categories_controller.dart';
import '../category/groups_controller.dart';
import '../move_todo/move_todo_sheet.dart';
import '../recurrence/recurrence_actions.dart';
import '../todo_actions/todo_actions_controller.dart';
import '../todo_actions/todo_row_actions.dart';
import '../todo_actions/toggle_with_undo.dart';
import 'tree_providers.dart';

/// 전체보기 — **그룹 → 카테고리 → 할 일** 전체 계층을 보는 유일한 화면.
///
/// UX 개선 Phase 2:
/// - [체크리스트|메모] 탭을 없애고 상태 칩 한 줄(`전체 · 미완료 · 진행중 · 완료 · 메모`)로.
///   칩을 고르면 트리 대신 조건에 맞는 항목만 카테고리별로 평탄하게 보여 준다.
/// - 위쪽 그룹 칩(`[전체] [회사] [개인]`)이 예전 그룹 화면을 대신한다 (오늘과 공유).
/// - 행은 오늘·카테고리 화면과 같은 할 일 행 — 체크·메뉴·스와이프·탭(=상세)이 같다.
/// - 카테고리 머리를 누르면 그 카테고리 화면, 오른쪽 ⌄ 는 접기. 접힘은 저장된다.
/// - 할 일이 없는 카테고리도 흐리게 보여 준다(어디에 무엇이 비었는지 보이게).
/// - 미분류 카테고리는 그룹들 **아래**.
class OutlineScreen extends ConsumerStatefulWidget {
  const OutlineScreen({super.key});

  /// 접힌 섹션 id(`grp:<id>` / `cat:<id>`)의 저장 키.
  static const collapsedKey = 'outline.collapsed';

  @override
  ConsumerState<OutlineScreen> createState() => _OutlineScreenState();
}

class _OutlineScreenState extends ConsumerState<OutlineScreen> {
  TodoStatusFilter _filter = TodoStatusFilter.all;

  /// "완료 N개" 를 펼친 카테고리 — 기본 접힘, 세션 한정.
  final Set<String> _doneShown = {};

  PersistedIdSet get _collapse =>
      ref.read(persistedIdSetProvider(OutlineScreen.collapsedKey).notifier);

  @override
  Widget build(BuildContext context) {
    final categories =
        ref.watch(activeCategoriesProvider).asData?.value ??
        Category.builtinSeeds;
    final groups =
        ref.watch(activeGroupsProvider).asData?.value ?? const <Group>[];
    final scoped = ref.watch(scopedGroupProvider);
    final allTodos =
        ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
    final collapsed = ref.watch(
      persistedIdSetProvider(OutlineScreen.collapsedKey),
    );

    final layout = _OutlineLayout.from(
      categories: categories,
      groups: groups,
      scope: scoped,
    );
    final visibleIds = {for (final c in layout.allCategories) c.id};
    // 반복 시리즈 마스터는 규칙 보관용 — 목록에 보이지 않는다(검색·이동 시트와 같은 규칙).
    final pool = [
      for (final t in allTodos)
        if (visibleIds.contains(t.category.id) && !t.isSeriesMaster) t,
    ];
    // 부모 id → 직속 하위 수 — 행마다 전체를 훑지 않게 한 번만 센다.
    final childCounts = <String, int>{};
    for (final t in allTodos) {
      final pid = t.parentId;
      if (pid != null && !t.isSeriesMaster) {
        childCounts[pid] = (childCounts[pid] ?? 0) + 1;
      }
    }
    final counts = TodoStatusCounts.of(pool);
    // 필터로 고른 상태가 비면(마지막 메모를 지우는 등) 전체로 돌아간다.
    final filter = counts.countOf(_filter) == 0
        ? TodoStatusFilter.all
        : _filter;

    // 모두 접기/펼치기의 대상 — 실제로 접을 수 있는(할 일이 있는) 카테고리.
    final withItems = {for (final t in pool) t.category.id};
    final catKeys = [
      for (final c in layout.allCategories)
        if (withItems.contains(c.id)) 'cat:${c.id}',
    ];
    final grpKeys = [
      for (final sec in layout.sections)
        if (sec.group != null) 'grp:${sec.group!.id}',
    ];
    // 지금 화면에 펼쳐져 보이는 카드가 하나라도 있으면 "모두 접기".
    final anyExpanded = layout.sections.any(
      (sec) =>
          (sec.group == null || !collapsed.contains('grp:${sec.group!.id}')) &&
          sec.categories.any(
            (c) =>
                withItems.contains(c.id) && !collapsed.contains('cat:${c.id}'),
          ),
    );

    // 한 달 넘게 남은 할 일 — 있을 때만 정리 화면 입구를 띄운다.
    final staleCount = ref.watch(staleBacklogProvider).length;

    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: _Toolbar(
          showTitle: !AppPlatform.isMobile,
          hasGroups: groups.isNotEmpty,
          canToggleAll: filter == TodoStatusFilter.all && catKeys.isNotEmpty,
          anyExpanded: anyExpanded,
          // 펼칠 때는 접힌 그룹도 함께 연다 — 눌렀는데 그대로인 일이 없게.
          onToggleAll: () => _collapse.replace(
            anyExpanded
                ? {...collapsed, ...catKeys}
                : ({...collapsed}
                    ..removeAll(catKeys)
                    ..removeAll(grpKeys)),
          ),
        ),
      ),
      if (staleCount > 0)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space16,
            0,
            AppTokens.space16,
            AppTokens.space12,
          ),
          sliver: SliverToBoxAdapter(
            child: _StaleBacklogEntry(count: staleCount),
          ),
        ),
      if (pool.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space16,
            0,
            AppTokens.space16,
            AppTokens.space12,
          ),
          sliver: SliverToBoxAdapter(
            child: TodoStatusFilterBar(
              counts: counts,
              selected: filter,
              onSelected: (f) => setState(() => _filter = f),
              accent: scoped?.color ?? Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
    ];

    if (layout.allCategories.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.account_tree_outlined,
            title: '카테고리가 없어요',
            subtitle: '카테고리를 추가하면 할 일이 여기에 모여요.',
          ),
        ),
      );
    } else if (filter == TodoStatusFilter.all) {
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space16,
            0,
            AppTokens.space16,
            88,
          ),
          sliver: SliverList(
            delegate: SliverChildListDelegate(
              _treeChildren(layout, collapsed, allTodos, childCounts),
            ),
          ),
        ),
      );
    } else {
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space16,
            0,
            AppTokens.space16,
            88,
          ),
          sliver: SliverList(
            delegate: SliverChildListDelegate(
              _filteredChildren(layout, pool, allTodos, filter, childCounts),
            ),
          ),
        ),
      );
    }

    return CustomScrollView(
      key: const PageStorageKey('outline'),
      slivers: slivers,
    );
  }

  /// 트리 모드 — 그룹 머리 + 카테고리 카드들, 맨 아래 미분류.
  List<Widget> _treeChildren(
    _OutlineLayout layout,
    Set<String> collapsed,
    List<Todo> allTodos,
    Map<String, int> childCounts,
  ) {
    Widget card(Category c) => _OutlineCategoryCard(
      key: ValueKey('outline-card-${c.id}'),
      category: c,
      allTodos: allTodos,
      childCounts: childCounts,
      expanded: !collapsed.contains('cat:${c.id}'),
      onToggle: () => _collapse.toggle('cat:${c.id}'),
      doneShown: _doneShown.contains(c.id),
      onToggleDone: () => setState(() {
        if (!_doneShown.add(c.id)) _doneShown.remove(c.id);
      }),
    );

    final children = <Widget>[];
    for (final section in layout.sections) {
      final g = section.group;
      if (g != null) {
        final open = !collapsed.contains('grp:${g.id}');
        children.add(
          _OutlineGroupHeader(
            group: g,
            count: section.categories.length,
            isExpanded: open,
            onToggle: () => _collapse.toggle('grp:${g.id}'),
          ),
        );
        if (!open) continue;
        if (section.categories.isEmpty) {
          children.add(const _MutedLine(text: '이 그룹엔 카테고리가 없어요'));
        }
      } else if (section.labelUngrouped) {
        children.add(const _OutlineUngroupedLabel());
      }
      children.addAll(section.categories.map(card));
    }
    return children;
  }

  /// 상태 칩 모드 — 카테고리별로 조건에 맞는 항목만 (하위 항목 포함, 경로 표시).
  List<Widget> _filteredChildren(
    _OutlineLayout layout,
    List<Todo> pool,
    List<Todo> allTodos,
    TodoStatusFilter filter,
    Map<String, int> childCounts,
  ) {
    final byId = {for (final t in allTodos) t.id: t};
    // 트리 순서(부모 → 자식, 형제는 sortOrder 순)로 훑는다 — 자식이 부모보다 먼저
    // 나오지 않게. 상세 화면의 상태 칩 목록과 같은 순서.
    final byParent = <String?, List<Todo>>{};
    for (final t in pool) {
      byParent.putIfAbsent(t.parentId, () => []).add(t);
    }
    for (final list in byParent.values) {
      list.sort((a, b) {
        final so = a.sortOrder.compareTo(b.sortOrder);
        if (so != 0) return so;
        final cr = b.createdAt.compareTo(a.createdAt);
        return cr != 0 ? cr : a.id.compareTo(b.id);
      });
    }
    List<Todo> depthFirst(String categoryId) {
      final out = <Todo>[];
      final seen = <String>{};
      void walk(String? pid) {
        for (final t in byParent[pid] ?? const <Todo>[]) {
          if (t.category.id != categoryId || !seen.add(t.id)) continue;
          out.add(t);
          walk(t.id);
        }
      }

      walk(null);
      // 부모가 목록에 없는 항목(부모가 다른 카테고리 등)도 빠뜨리지 않는다.
      for (final t in pool) {
        if (t.category.id == categoryId && seen.add(t.id)) out.add(t);
      }
      return out;
    }

    final children = <Widget>[];
    for (final c in layout.allCategories) {
      final matched = [
        for (final t in depthFirst(c.id))
          if (filter.matches(t)) t,
      ];
      if (matched.isEmpty) continue;
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: AppTokens.space12),
          child: _CardFrame(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _CategoryHeaderRow(
                  category: c,
                  progress: null,
                  empty: false,
                  expanded: null,
                  onToggle: null,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.space8,
                    0,
                    AppTokens.space8,
                    AppTokens.space8,
                  ),
                  child: Column(
                    children: [
                      for (final t in matched)
                        OutlineTodoRow(
                          todo: t,
                          childCount: childCounts[t.id] ?? 0,
                          breadcrumb: _breadcrumbOf(t, byId),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (children.isEmpty) {
      children.add(_MutedLine(text: '${filter.label} 항목이 없어요'));
    }
    return children;
  }

  static String? _breadcrumbOf(Todo todo, Map<String, Todo> byId) {
    final titles = <String>[];
    final visited = <String>{todo.id};
    var pid = todo.parentId;
    while (pid != null) {
      final p = byId[pid];
      if (p == null || !visited.add(p.id)) break;
      titles.insert(0, p.title);
      pid = p.parentId;
    }
    return titles.isEmpty ? null : titles.join(' › ');
  }
}

/// 그룹 → 카테고리 배치. 그룹 필터가 켜져 있으면 그 그룹 카테고리만(머리 없이).
class _OutlineLayout {
  const _OutlineLayout(this.sections);

  factory _OutlineLayout.from({
    required List<Category> categories,
    required List<Group> groups,
    required Group? scope,
  }) {
    if (scope != null) {
      return _OutlineLayout([
        _Section(
          group: null,
          labelUngrouped: false,
          categories: [
            for (final c in categories)
              if (c.groupId == scope.id) c,
          ],
        ),
      ]);
    }
    final groupIds = {for (final g in groups) g.id};
    final byGroup = <String, List<Category>>{};
    final ungrouped = <Category>[];
    for (final c in categories) {
      final gid = c.groupId;
      if (gid == null || !groupIds.contains(gid)) {
        ungrouped.add(c);
      } else {
        byGroup.putIfAbsent(gid, () => []).add(c);
      }
    }
    return _OutlineLayout([
      for (final g in groups)
        _Section(
          group: g,
          labelUngrouped: false,
          categories: byGroup[g.id] ?? const [],
        ),
      if (ungrouped.isNotEmpty)
        _Section(
          group: null,
          labelUngrouped: groups.isNotEmpty,
          categories: ungrouped,
        ),
    ]);
  }

  final List<_Section> sections;

  List<Category> get allCategories => [
    for (final s in sections) ...s.categories,
  ];
}

class _Section {
  const _Section({
    required this.group,
    required this.labelUngrouped,
    required this.categories,
  });

  final Group? group;
  final bool labelUngrouped;
  final List<Category> categories;
}

/// 제목 줄 + 그룹 칩. 데스크탑은 큰 제목 아래 칩, 폰은 앱바가 제목이라 칩 줄 끝에
/// 접기 버튼을 붙여 한 줄로.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.showTitle,
    required this.hasGroups,
    required this.canToggleAll,
    required this.anyExpanded,
    required this.onToggleAll,
  });

  final bool showTitle;
  final bool hasGroups;
  final bool canToggleAll;
  final bool anyExpanded;
  final VoidCallback onToggleAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = anyExpanded ? '모두 접기' : '모두 펼치기';
    final icon = anyExpanded ? Icons.unfold_less_rounded : Icons.unfold_more;
    if (!showTitle) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          0,
          AppTokens.space8,
          AppTokens.space4,
          AppTokens.space8,
        ),
        child: Row(
          children: [
            Expanded(
              child: hasGroups
                  ? const GroupScopeChips()
                  : const SizedBox.shrink(),
            ),
            if (canToggleAll)
              IconButton(
                key: const ValueKey('outline-toggle-all'),
                tooltip: label,
                onPressed: onToggleAll,
                icon: Icon(icon),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space24,
        AppTokens.space32,
        AppTokens.space16,
        AppTokens.space12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '전체보기',
                      style: theme.textTheme.displayMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppTokens.space4),
                    Text(
                      '그룹 · 카테고리별 할 일과 메모를 한눈에',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              if (canToggleAll)
                TextButton.icon(
                  key: const ValueKey('outline-toggle-all'),
                  onPressed: onToggleAll,
                  icon: Icon(icon, size: 18),
                  label: Text(label),
                ),
            ],
          ),
          if (hasGroups) ...[
            const SizedBox(height: AppTokens.space12),
            const GroupScopeChips(padding: EdgeInsets.zero),
          ],
        ],
      ),
    );
  }
}

/// "30일 넘은 할 일 N개 · 정리하기" — 오래된 할 일 정리 화면 입구.
class _StaleBacklogEntry extends StatelessWidget {
  const _StaleBacklogEntry({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(AppTokens.radiusM),
      child: InkWell(
        key: const ValueKey('outline-stale-entry'),
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        onTap: () => StaleBacklogScreen.show(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space12,
            vertical: AppTokens.space8,
          ),
          child: Row(
            children: [
              Icon(Icons.history_rounded, size: 18, color: muted),
              const SizedBox(width: AppTokens.space8),
              Expanded(
                child: Text(
                  '한 달 넘게 남은 할 일 $count개',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              Text(
                '정리하기',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 그룹 머리 — 탭 = 접기/펼치기.
class _OutlineGroupHeader extends StatelessWidget {
  const _OutlineGroupHeader({
    required this.group,
    required this.count,
    required this.isExpanded,
    required this.onToggle,
  });

  final Group group;
  final int count;
  final bool isExpanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(
        top: AppTokens.space8,
        bottom: AppTokens.space4,
      ),
      child: InkWell(
        key: ValueKey('outline-group-${group.id}'),
        onTap: onToggle,
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space8,
            vertical: AppTokens.space8,
          ),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: group.color,
                  borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                ),
              ),
              const SizedBox(width: AppTokens.space12),
              Expanded(
                child: Text(
                  group.label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!isExpanded && count > 0)
                Padding(
                  padding: const EdgeInsets.only(right: AppTokens.space8),
                  child: Text(
                    '카테고리 $count개',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              AnimatedRotation(
                turns: isExpanded ? 0 : -0.25,
                duration: AppTokens.motionFast,
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 24,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// '미분류' 섹션 라벨 (그룹 머리보다 약하게). 그룹이 있을 때만.
class _OutlineUngroupedLabel extends StatelessWidget {
  const _OutlineUngroupedLabel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('outline-ungrouped-label'),
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space12,
        AppTokens.space16,
        AppTokens.space12,
        AppTokens.space8,
      ),
      child: Text(
        '미분류',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _MutedLine extends StatelessWidget {
  const _MutedLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space12,
        vertical: AppTokens.space12,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

class _CardFrame extends StatelessWidget {
  const _CardFrame({required this.child, this.muted = false});

  final Widget child;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: muted
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.35)
            : scheme.surface,
        borderRadius: BorderRadius.circular(AppTokens.radiusL),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.6),
          width: AppTokens.hairline,
        ),
      ),
      child: child,
    );
  }
}

/// 카테고리 카드 — 머리(탭 = 카테고리 화면, ⌄ = 접기) + 최상위 항목들 + 완료 접기.
class _OutlineCategoryCard extends ConsumerWidget {
  const _OutlineCategoryCard({
    super.key,
    required this.category,
    required this.allTodos,
    required this.childCounts,
    required this.expanded,
    required this.onToggle,
    required this.doneShown,
    required this.onToggleDone,
  });

  final Category category;
  final List<Todo> allTodos;
  final Map<String, int> childCounts;
  final bool expanded;
  final VoidCallback onToggle;
  final bool doneShown;
  final VoidCallback onToggleDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 반복 시리즈 마스터는 목록에 보이지 않는다.
    final roots = [
      for (final r
          in ref.watch(rootsOfCategoryProvider(category)).asData?.value ??
              const <Todo>[])
        if (!r.isSeriesMaster) r,
    ];

    // 카테고리 진척 = 보이는 항목들(최상위 + 그 하위)의 task. 부모 없이 남은 유령이나
    // 시리즈 마스터는 세지 않는다 — 배지 숫자와 눈에 보이는 항목이 어긋나지 않게.
    var done = 0;
    var total = 0;
    for (final r in roots) {
      if (r.type == TodoType.task) {
        total++;
        if (r.isDone) done++;
      }
      final p = computeSubtreeProgress(r, allTodos);
      total += p.taskCount;
      done += p.doneCount;
    }
    final empty = roots.isEmpty;

    final active = <Todo>[];
    final doneRoots = <Todo>[];
    for (final r in roots) {
      if (r.type == TodoType.task && r.isDone) {
        doneRoots.add(r);
      } else {
        active.add(r);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.space12),
      child: _CardFrame(
        muted: empty,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CategoryHeaderRow(
              category: category,
              progress: total > 0 ? (done, total) : null,
              empty: empty,
              expanded: empty ? null : expanded,
              onToggle: empty ? null : onToggle,
            ),
            if (expanded && roots.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.space8,
                  0,
                  AppTokens.space8,
                  AppTokens.space8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final r in active)
                      OutlineTodoRow(
                        todo: r,
                        childCount: childCounts[r.id] ?? 0,
                      ),
                    if (doneRoots.isNotEmpty) ...[
                      _DoneCollapseRow(
                        catId: category.id,
                        count: doneRoots.length,
                        expanded: doneShown,
                        accent: category.color,
                        onTap: onToggleDone,
                      ),
                      if (doneShown)
                        for (final r in doneRoots)
                          OutlineTodoRow(
                            todo: r,
                            childCount: childCounts[r.id] ?? 0,
                          ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 카테고리 머리 줄. 본문 탭 = 카테고리 화면으로, 오른쪽 ⌄ = 접기([onToggle] 있을 때).
class _CategoryHeaderRow extends ConsumerWidget {
  const _CategoryHeaderRow({
    required this.category,
    required this.progress,
    required this.empty,
    required this.expanded,
    required this.onToggle,
  });

  final Category category;
  final (int, int)? progress;
  final bool empty;
  final bool? expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fade = empty ? 0.55 : 1.0;
    return InkWell(
      key: ValueKey('outline-category-${category.id}'),
      onTap: () => ref
          .read(shellLocationProvider.notifier)
          .openCategory(category.id, from: ShellLocation.outline),
      borderRadius: BorderRadius.circular(AppTokens.radiusL),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space12,
          AppTokens.space8,
          AppTokens.space4,
          AppTokens.space8,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: category.color.withValues(alpha: 0.14 * fade),
                borderRadius: BorderRadius.circular(AppTokens.radiusM),
              ),
              child: Icon(
                category.icon,
                size: 20,
                color: category.color.withValues(alpha: fade),
              ),
            ),
            const SizedBox(width: AppTokens.space12),
            Expanded(
              child: Text(
                category.label,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                  color: scheme.onSurface.withValues(alpha: fade),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (empty)
              Padding(
                padding: const EdgeInsets.only(right: AppTokens.space12),
                child: Text(
                  '비어 있음',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
            if (progress case (final d, final t))
              Padding(
                padding: const EdgeInsets.only(right: AppTokens.space4),
                child: _ProgressBadge(
                  done: d,
                  total: t,
                  accent: category.color,
                ),
              ),
            if (expanded != null)
              IconButton(
                key: ValueKey('outline-collapse-${category.id}'),
                tooltip: expanded! ? '접기' : '펼치기',
                onPressed: onToggle,
                icon: AnimatedRotation(
                  turns: expanded! ? 0 : -0.25,
                  duration: AppTokens.motionFast,
                  child: Icon(
                    Icons.expand_more_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else if (!empty)
              const SizedBox(width: AppTokens.space8),
          ],
        ),
      ),
    );
  }
}

/// 전체보기의 할 일 한 줄 — 오늘·카테고리 화면과 같은 행([DismissibleTodoTile]).
///
/// 탭 = 상세, 체크 = 완료(되돌리기), 폰 길게 누르기 / 데스크탑 우클릭·⋮ = 메뉴,
/// 폰 오른쪽 밀기 = 완료, 왼쪽 밀기 = 삭제(되돌리기).
class OutlineTodoRow extends ConsumerWidget {
  const OutlineTodoRow({
    super.key,
    required this.todo,
    required this.childCount,
    this.breadcrumb,
  });

  final Todo todo;

  /// 직속 하위 수 — 화면이 한 번에 세어 넘긴다.
  final int childCount;
  final String? breadcrumb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTask = todo.type == TodoType.task;
    return Padding(
      key: ValueKey('outline-node-${todo.id}'),
      padding: const EdgeInsets.only(bottom: AppTokens.space4),
      child: DismissibleTodoTile(
        todo: todo,
        onToggle: isTask
            ? () => toggleWithUndo(context, ref.read(todoActionsProvider), todo)
            : null,
        onToggleInProgress: isTask
            ? () => ref.read(todoActionsProvider).toggleInProgress(todo)
            : null,
        onTap: () => openTodoDetail(context, todo),
        onDelete: () => deleteTodoWithUndo(context, ref, todo),
        onAddChild: () => showAddChildSheet(context, ref, parent: todo),
        onMove: () => showMoveTodoSheet(context, ref, item: todo),
        onCopy: () => showCopyTodoSheet(context, ref, original: todo),
        onEditItem: () => openTodoEdit(context, ref, todo),
        onStopRecurrence: () => confirmStopRecurrence(context, ref, todo),
        drillChildCount: childCount > 0 ? childCount : null,
        childCount: childCount,
        breadcrumb: breadcrumb,
      ),
    );
  }
}

/// "✓ 완료 N개" 접기 행 — 기본 접힘.
class _DoneCollapseRow extends StatelessWidget {
  const _DoneCollapseRow({
    required this.catId,
    required this.count,
    required this.expanded,
    required this.accent,
    required this.onTap,
  });

  final String catId;
  final int count;
  final bool expanded;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      key: ValueKey('outline-done-toggle-$catId'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.radiusM),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space8,
          vertical: AppTokens.space12,
        ),
        child: Row(
          children: [
            Icon(
              Icons.check_circle_rounded,
              size: 18,
              color: accent.withValues(alpha: 0.7),
            ),
            const SizedBox(width: AppTokens.space8),
            Text(
              '완료 $count개',
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: AppTokens.motionFast,
              child: Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `done/total` 진척 pill. 다 끝났으면 체크 + 진한 배경.
class _ProgressBadge extends StatelessWidget {
  const _ProgressBadge({
    required this.done,
    required this.total,
    required this.accent,
  });

  final int done;
  final int total;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final complete = total > 0 && done == total;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space8,
        vertical: AppTokens.space2,
      ),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: complete ? 0.20 : 0.11),
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (complete) ...[
            Icon(Icons.check_circle_rounded, size: 13, color: accent),
            const SizedBox(width: AppTokens.space4),
          ],
          Text(
            '$done/$total',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}
