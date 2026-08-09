import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/theme.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/in_progress_triangle.dart';
import '../add_todo/add_todo_sheet.dart';
import '../category/categories_controller.dart';
import '../category/groups_controller.dart';
import '../move_todo/move_todo_sheet.dart';
import '../todo_actions/todo_actions_controller.dart';
import '../todo_detail/todo_detail_screen.dart';
import 'tree_providers.dart';

/// 전체 트리 view — **그룹 → 카테고리 → 태스크** 계층으로 펼침/접힘 표시.
///
/// v1.4 (Task D) — 상단 탭 2개로 분리:
///   - **체크리스트**: task root 만 (note 제외). 그룹 헤더 → 카테고리 root 목록.
///     root 탭 → 상세 화면(TodoDetailScreen) 으로 드릴다운 (인라인 펼침 대체).
///   - **메모**: note 만 그룹 → 카테고리 섹션으로 평탄 나열 (체크 개념 없음).
///
/// 작업 3 (L) — 카테고리만 평면 나열하던 것을 그룹 계층으로 확장. '미분류' 카테고리는
/// 별도 섹션. 그룹/카테고리 모두 sortOrder 순. 그룹이 하나도 없으면 그룹 헤더 없이
/// 카테고리만 (기존 평면 모양과 동일) 표시한다.
class OutlineScreen extends ConsumerWidget {
  const OutlineScreen({super.key, this.group, this.showHeader = true});

  /// non-null = 이 그룹의 카테고리만 평면으로 (그룹 헤더 없이) 보여 준다 (A안 — 그룹별
  /// '전체보기' 탭). null = 전역 (그룹 → 카테고리 계층).
  final Group? group;

  /// 큰 '전체보기' 헤더 표시 여부 (그룹 탭 임베드 시 false, 체크리스트/메모 탭만 노출).
  final bool showHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // v1.2 — 동적 카테고리 (보관 제외). loading / error 시 builtin 5종 fallback.
    final allCategories =
        ref.watch(activeCategoriesProvider).asData?.value ??
        Category.builtinSeeds;
    // 작업 3 (L) — 그룹 계층 (보관 제외). loading / error 시 빈 목록 (= 평면).
    final allGroups =
        ref.watch(activeGroupsProvider).asData?.value ?? const <Group>[];

    // 그룹 스코프면 그 그룹 카테고리만 + 그룹 헤더 제거 (groups 를 비워 평면 렌더).
    final categories = group == null
        ? allCategories
        : allCategories.where((c) => c.groupId == group!.id).toList();
    final groups = group == null ? allGroups : const <Group>[];
    final layout = _OutlineLayout.from(categories: categories, groups: groups);

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          if (showHeader)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.space24,
                AppTokens.space32,
                AppTokens.space24,
                AppTokens.space12,
              ),
              child: _Header(),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppTokens.space16),
            child: TabBar(
              key: ValueKey('outline-tabs'),
              tabs: [
                Tab(text: '체크리스트'),
                Tab(text: '메모'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _ChecklistTab(layout: layout),
                _NotesTab(layout: layout),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 작업 3 (L) — 그룹 → 카테고리 배치를 한 번 계산해 두 탭이 공유.
///
/// '미분류'(groupId == null) 는 [ungrouped] 로, 그룹별 카테고리는 [sections] 로.
/// 존재하지 않는 그룹에 매인 카테고리는 미분류로 흡수한다. 카테고리는 입력
/// (categoriesProvider) 이 이미 sortOrder 순이므로 그 순서를 보존한다. 그룹도 입력
/// (groupsProvider) 의 sortOrder 순.
class _OutlineLayout {
  const _OutlineLayout({
    required this.groups,
    required this.ungrouped,
    required this.byGroup,
  });

  /// 그룹 헤더를 그릴지 여부 — 그룹이 하나라도 있으면 true.
  final List<Group> groups;

  /// 미분류 카테고리들 (sortOrder 순).
  final List<Category> ungrouped;

  /// groupId → 그 그룹의 카테고리들 (sortOrder 순).
  final Map<String, List<Category>> byGroup;

  bool get hasGroups => groups.isNotEmpty;

  static _OutlineLayout from({
    required List<Category> categories,
    required List<Group> groups,
  }) {
    final ungrouped = <Category>[];
    final byGroup = <String, List<Category>>{};
    for (final c in categories) {
      final gid = c.groupId;
      if (gid == null) {
        ungrouped.add(c);
      } else {
        byGroup.putIfAbsent(gid, () => <Category>[]).add(c);
      }
    }
    // 존재하지 않는 그룹에 매인 카테고리는 미분류로 흡수.
    final groupIds = groups.map((g) => g.id).toSet();
    for (final entry in byGroup.entries.toList()) {
      if (!groupIds.contains(entry.key)) {
        ungrouped.addAll(entry.value);
        byGroup.remove(entry.key);
      }
    }
    return _OutlineLayout(
      groups: groups,
      ungrouped: ungrouped,
      byGroup: byGroup,
    );
  }
}

/// 그룹 헤더 (접힘 토글) — 전체보기 공통. 색 dot + label + chevron + 접힘 상태.
class _OutlineGroupHeader extends StatelessWidget {
  const _OutlineGroupHeader({
    required this.group,
    required this.isExpanded,
    required this.onToggle,
  });

  final Group group;
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
              // 그룹 색 막대 — 섹션 정체성을 강하게.
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

/// '미분류' 섹션 라벨 (그룹 헤더보다 약한 시각 강조). 그룹이 있을 때만 노출.
class _OutlineUngroupedLabel extends StatelessWidget {
  const _OutlineUngroupedLabel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: const ValueKey('outline-ungrouped-label'),
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space12,
        AppTokens.space12,
        AppTokens.space12,
        AppTokens.space4,
      ),
      child: Text(
        '미분류',
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurface.withValues(alpha: 0.55),
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '전체보기',
          style: theme.textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: AppTokens.space4),
        Text('체크리스트는 트리로, 메모는 메모별로', style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

// ───────────────────────── 체크리스트 탭 (task 트리) ─────────────────────────

/// 체크리스트 탭 — 그룹 → 카테고리 task root + task 자식 트리. note 는 모두 제외.
/// 펼침/접힘 상태는 이 탭이 자체 보유 (탭 전환해도 유지).
class _ChecklistTab extends ConsumerStatefulWidget {
  const _ChecklistTab({required this.layout});

  final _OutlineLayout layout;

  @override
  ConsumerState<_ChecklistTab> createState() => _ChecklistTabState();
}

class _ChecklistTabState extends ConsumerState<_ChecklistTab>
    with AutomaticKeepAliveClientMixin {
  /// "접힌" 섹션 id 모음 — default 가 펼침 상태. id 가 set 에 있으면 접힌 상태.
  /// 그룹 헤더는 `grp:<id>`, 카테고리 헤더는 `cat:work`. (task 노드는 인라인 펼침
  /// 대신 상세 화면 드릴다운으로 이동하므로 더 이상 토글 대상이 아니다.)
  final Set<String> _collapsed = {};

  bool _expanded(String id) => !_collapsed.contains(id);
  void _toggle(String id) {
    setState(() {
      if (_collapsed.contains(id)) {
        _collapsed.remove(id);
      } else {
        _collapsed.add(id);
      }
    });
  }

  /// "완료 접기" 섹션이 펼쳐진 카테고리 id 모음 — 기본은 **접힘**(완료를 감춤).
  /// id 가 set 에 있으면 그 카테고리의 완료 항목이 펼쳐져 보인다. 세션 한정(비영속) —
  /// 저장 인프라 없이 매 세션 기본 접힘으로 시작해 브라우징 노이즈를 최소화한다.
  final Set<String> _doneShown = {};
  bool _isDoneShown(String catId) => _doneShown.contains(catId);
  void _toggleDoneShown(String catId) {
    setState(() {
      if (!_doneShown.add(catId)) _doneShown.remove(catId);
    });
  }

  @override
  bool get wantKeepAlive => true;

  /// 한 카테고리 트리 위젯 (그룹 안/미분류 공통).
  Widget _category(Category c) => _OutlineCategory(
    category: c,
    expanded: _expanded,
    onToggle: _toggle,
    doneShown: _isDoneShown,
    onToggleDone: _toggleDoneShown,
  );

  /// 체크리스트(= task root) 가 하나라도 있는 카테고리 id 집합만 통과시킨다.
  /// 메모만 있거나 완전히 빈 카테고리는 체크리스트 탭에서 숨긴다 (사용자 요청).
  /// 그 결과 카테고리가 0개가 된 그룹 헤더 / '미분류' 라벨도 함께 숨겨진다.
  List<Widget> _buildChildren(Set<String> withTaskRoot) {
    final layout = widget.layout;
    final children = <Widget>[];
    // 미분류 — 체크리스트 있는 카테고리만.
    final ungrouped = layout.ungrouped
        .where((c) => withTaskRoot.contains(c.id))
        .toList();
    if (ungrouped.isNotEmpty) {
      if (layout.hasGroups) children.add(const _OutlineUngroupedLabel());
      for (final c in ungrouped) {
        children.add(_category(c));
      }
    }
    // 그룹별 섹션 — 체크리스트 있는 카테고리가 하나라도 있을 때만 헤더 노출.
    for (final g in layout.groups) {
      final items = (layout.byGroup[g.id] ?? const <Category>[])
          .where((c) => withTaskRoot.contains(c.id))
          .toList();
      if (items.isEmpty) continue;
      final groupExpanded = _expanded('grp:${g.id}');
      children.add(
        _OutlineGroupHeader(
          group: g,
          isExpanded: groupExpanded,
          onToggle: () => _toggle('grp:${g.id}'),
        ),
      );
      if (groupExpanded) {
        for (final c in items) {
          children.add(_category(c));
        }
      }
    }
    return children;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 전체 todos 에서 카테고리별 "체크리스트 관련 root" 보유 여부를 한 번에 계산.
    // (taskRootsOfCategoryProvider 와 같은 의미 — task root 또는 task 자손 보유 note 헤딩.)
    final allTodos =
        ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
    final withTaskRoot = <String>{};
    for (final t in allTodos) {
      if (t.parentId == null &&
          (t.type == TodoType.task || hasTaskDescendant(t, allTodos))) {
        withTaskRoot.add(t.category.id);
      }
    }

    final children = _buildChildren(withTaskRoot);
    if (children.isEmpty) {
      return const CustomScrollView(
        key: PageStorageKey('outline-checklist'),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.checklist_rounded,
              title: '체크리스트가 없어요',
              subtitle: '할 일을 추가하면 카테고리별로 여기에 모여요.',
            ),
          ),
        ],
      );
    }

    return CustomScrollView(
      key: const PageStorageKey('outline-checklist'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space16,
            AppTokens.space12,
            AppTokens.space16,
            AppTokens.space48,
          ),
          sliver: SliverList(delegate: SliverChildListDelegate(children)),
        ),
      ],
    );
  }
}

class _OutlineCategory extends ConsumerWidget {
  const _OutlineCategory({
    required this.category,
    required this.expanded,
    required this.onToggle,
    required this.doneShown,
    required this.onToggleDone,
  });

  final Category category;
  final bool Function(String id) expanded;
  final void Function(String id) onToggle;

  /// 이 카테고리의 "완료 접기" 섹션이 펼쳐졌는지 (기본 접힘).
  final bool Function(String catId) doneShown;
  final void Function(String catId) onToggleDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 체크리스트 탭 — task root 만 (note root 제외).
    final roots = ref
        .watch(taskRootsOfCategoryProvider(category))
        .asData
        ?.value;
    final allTodos = ref.watch(allTodosProvider).asData?.value;
    final isExpanded = expanded('cat:${category.id}');

    // 카테고리 전체 진척률 — root 의 자기 자신 (task 면) + 각 root 의 subtree.
    var done = 0;
    var total = 0;
    if (roots != null && allTodos != null) {
      for (final r in roots) {
        if (r.type == TodoType.task) {
          total++;
          if (r.isDone) done++;
        }
        final p = computeSubtreeProgress(r, allTodos);
        total += p.taskCount;
        done += p.doneCount;
      }
    }

    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.space12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(AppTokens.radiusL),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
            width: AppTokens.hairline,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CategoryRow(
              category: category,
              done: done,
              total: total,
              isExpanded: isExpanded,
              onTap: () => onToggle('cat:${category.id}'),
            ),
            if (isExpanded && roots != null && roots.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.space12,
                  0,
                  AppTokens.space8,
                  AppTokens.space8,
                ),
                child: _CategoryRoots(
                  roots: roots,
                  category: category,
                  doneShown: doneShown(category.id),
                  onToggleDone: () => onToggleDone(category.id),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 한 카테고리의 root 목록 — 미완료 root 는 그대로, 완료(체크된 task root)는 "완료 N개"
/// 접기 행 아래로 모은다. 기본 접힘이라 완료가 브라우징 화면에 쌓이지 않는다 (사용자 요청).
class _CategoryRoots extends StatelessWidget {
  const _CategoryRoots({
    required this.roots,
    required this.category,
    required this.doneShown,
    required this.onToggleDone,
  });

  final List<Todo> roots;
  final Category category;
  final bool doneShown;
  final VoidCallback onToggleDone;

  @override
  Widget build(BuildContext context) {
    // 완료 = 체크된 task root. note 헤딩(체크 개념 없음)은 항상 활성 목록에 남는다.
    final active = <Todo>[];
    final done = <Todo>[];
    for (final r in roots) {
      if (r.type == TodoType.task && r.isDone) {
        done.add(r);
      } else {
        active.add(r);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in active) _OutlineNode(node: r),
        if (done.isNotEmpty) ...[
          _DoneCollapseRow(
            catId: category.id,
            count: done.length,
            expanded: doneShown,
            accent: category.color,
            onTap: onToggleDone,
          ),
          if (doneShown)
            for (final r in done) _OutlineNode(node: r),
        ],
      ],
    );
  }
}

/// "✓ 완료 N개" 접기 행 — 낮은 강조(muted)로 완료 항목 진입점을 제공한다.
/// 탭하면 그 카테고리의 완료 항목만 펼쳐진다 (기본 접힘). 진척 배지는 별도 유지.
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
          horizontal: AppTokens.space4,
          vertical: AppTokens.space8,
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

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.done,
    required this.total,
    required this.isExpanded,
    required this.onTap,
  });

  final Category category;
  final int done;
  final int total;
  final bool isExpanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      key: ValueKey('outline-category-${category.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.radiusL),
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space12),
        child: Row(
          children: [
            // 카테고리 정체성 — 색 타일 + 아이콘 (가독성·스캔성 강화).
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: category.color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppTokens.radiusM),
              ),
              child: Icon(category.icon, size: 21, color: category.color),
            ),
            const SizedBox(width: AppTokens.space12),
            Expanded(
              child: Text(
                category.label,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                ),
              ),
            ),
            if (total > 0) ...[
              _ProgressBadge(done: done, total: total, accent: category.color),
              const SizedBox(width: AppTokens.space8),
            ],
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
    );
  }
}

/// 한 task root / note 헤딩 행. (home / 카테고리 화면과 동일한 "기능 M" 패턴.)
///
/// - **하위가 있는 노드** → 탭 시 상세 화면(TodoDetailScreen) 으로 드릴다운
///   (인라인으로 펼치지 않고 상세에서 자식 체크리스트를 본다).
/// - **하위 없는 leaf** → 탭 시 편집 바텀시트(AddTodoSheet) 를 연다.
class _OutlineNode extends ConsumerWidget {
  const _OutlineNode({required this.node});

  final Todo node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 자손 보유 여부 — 드릴다운/진척 배지 판단용 (task 자식 + task 자손 보유 note §14).
    final children = ref.watch(childTasksOfProvider(node.id)).asData?.value;
    final allTodos = ref.watch(allTodosProvider).asData?.value;
    final isFolder = children != null && children.isNotEmpty;
    final progress = isFolder && allTodos != null
        ? computeSubtreeProgress(node, allTodos)
        : null;

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDone = node.isDone;
    final isInProgress = node.isInProgress;
    // §14 — note 헤딩은 체크 개념이 없어 체크박스 대신 카테고리색 메모 글리프로 표시.
    final isNote = node.type == TodoType.note;
    // 날짜가 지정된 체크리스트 항목은 제목 아래에 날짜 라벨을 노출 (TodoTile 과 동일 출처).
    final dateLabel = isNote ? null : TodoDateLabel.format(node);

    // 하위가 있는 노드 → 상세 화면 드릴다운. 하위 없는 leaf → 편집 바텀시트.
    // (home / 카테고리 화면과 동일 — folder=드릴다운, leaf=편집.)
    void openDetail() => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => TodoDetailScreen(parent: node)),
    );
    Future<void> openEdit() => AddTodoSheet.show(
      context,
      initialCategory: node.category,
      initialTodo: node,
      onSubmit: (_) {},
      onUpdate: (updated) => ref.read(todoActionsProvider).update(updated),
      onRequestMove: (t) => showMoveTodoSheet(context, ref, item: t),
    );

    return InkWell(
      key: ValueKey('outline-node-${node.id}'),
      onTap: isFolder ? openDetail : openEdit,
      borderRadius: BorderRadius.circular(AppTokens.radiusM),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space4,
          vertical: AppTokens.space2,
        ),
        child: Row(
          children: [
            // task = 큰 원형 체크박스. note 헤딩 = 메모 글리프(체크 불가).
            if (isNote)
              Padding(
                key: ValueKey('outline-note-glyph-${node.id}'),
                padding: const EdgeInsets.all(AppTokens.space4),
                child: Icon(
                  Icons.sticky_note_2_outlined,
                  size: 22,
                  color: NoteVisual.accent(node.category),
                ),
              )
            else ...[
              // 진행중(세모) 버튼 — 완료 체크 원 왼쪽. task 만.
              InkWell(
                key: ValueKey('outline-progress-${node.id}'),
                onTap: () =>
                    ref.read(todoActionsProvider).toggleInProgress(node),
                customBorder: const CircleBorder(),
                child: Padding(
                  padding: const EdgeInsets.all(AppTokens.space4),
                  child: InProgressTriangle(
                    active: isInProgress,
                    color: node.category.color,
                    size: 20,
                  ),
                ),
              ),
              _CheckCircle(
                checkKey: ValueKey('outline-check-${node.id}'),
                done: isDone,
                color: node.category.color,
                onTap: () => ref.read(todoActionsProvider).toggle(node),
              ),
            ],
            const SizedBox(width: AppTokens.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.title,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      height: 1.3,
                      // note 헤딩은 굵게(섹션 제목). task 폴더 w600 / leaf w500.
                      fontWeight: isNote
                          ? FontWeight.w700
                          : (isFolder ? FontWeight.w600 : FontWeight.w500),
                      decoration: isDone ? TextDecoration.lineThrough : null,
                      color: isDone
                          ? scheme.onSurface.withValues(alpha: 0.4)
                          : scheme.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // 날짜가 있으면 제목 아래에 카테고리색 캘린더 글리프 + 날짜.
                  if (dateLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(top: AppTokens.space2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.event_rounded,
                            size: 13,
                            color: isDone
                                ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                                : node.category.color,
                          ),
                          const SizedBox(width: AppTokens.space4),
                          Text(
                            dateLabel,
                            key: ValueKey('outline-node-date-${node.id}'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w400,
                              color: isDone
                                  ? scheme.onSurface.withValues(alpha: 0.4)
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (progress != null && progress.taskCount > 0) ...[
              const SizedBox(width: AppTokens.space8),
              _ProgressBadge(
                done: progress.doneCount,
                total: progress.taskCount,
                accent: node.category.color,
              ),
            ],
            // 상세 드릴다운 표시 — 하위가 있는 노드에만 chevron. leaf 는 표시 없음.
            if (isFolder)
              Padding(
                padding: const EdgeInsets.only(left: AppTokens.space4),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 큰 원형 체크박스 — 미완료는 외곽선, 완료는 카테고리 색 채움 + 흰 체크.
/// [checkKey] 는 InkWell 에 부여되어 테스트/탭 타깃 식별에 쓰인다.
class _CheckCircle extends StatelessWidget {
  const _CheckCircle({
    required this.checkKey,
    required this.done,
    required this.color,
    required this.onTap,
  });

  final Key checkKey;
  final bool done;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: checkKey,
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space4),
        child: AnimatedContainer(
          duration: AppTokens.motionFast,
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? color : Colors.transparent,
            // §13 — 미완료 ring 도 카테고리색(0.55) 으로 — TodoTile task 와 일관
            // ("체크 가능" 카테고리색 힌트). 완료는 카테고리색 채움 + 흰 체크.
            border: Border.all(
              color: done ? color : color.withValues(alpha: 0.55),
              width: 2,
            ),
          ),
          child: done
              ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}

// ───────────────────────── 메모 탭 (note 평탄 목록) ─────────────────────────

/// 메모 탭 — 그룹 → 카테고리 섹션으로 note 를 평탄 나열. 체크 개념 없이 정적 표시.
///
/// 작업 3 (L) — 체크리스트 탭과 일관되게 그룹 헤더(접힘) + '미분류' 섹션 구조.
/// note 가 0건인 카테고리 섹션은 [_NoteCategorySection] 이 스스로 hide 한다.
class _NotesTab extends StatefulWidget {
  const _NotesTab({required this.layout});

  final _OutlineLayout layout;

  @override
  State<_NotesTab> createState() => _NotesTabState();
}

class _NotesTabState extends State<_NotesTab>
    with AutomaticKeepAliveClientMixin {
  final Set<String> _collapsedGroups = {};

  bool _expanded(String groupId) => !_collapsedGroups.contains(groupId);
  void _toggle(String groupId) {
    setState(() {
      if (!_collapsedGroups.remove(groupId)) _collapsedGroups.add(groupId);
    });
  }

  @override
  bool get wantKeepAlive => true;

  List<Widget> _buildChildren() {
    final layout = widget.layout;
    final children = <Widget>[];
    if (layout.ungrouped.isNotEmpty) {
      if (layout.hasGroups) children.add(const _OutlineUngroupedLabel());
      for (final c in layout.ungrouped) {
        children.add(_NoteCategorySection(category: c));
      }
    }
    for (final g in layout.groups) {
      final items = layout.byGroup[g.id] ?? const <Category>[];
      final groupExpanded = _expanded(g.id);
      children.add(
        _OutlineGroupHeader(
          group: g,
          isExpanded: groupExpanded,
          onToggle: () => _toggle(g.id),
        ),
      );
      if (groupExpanded) {
        for (final c in items) {
          children.add(_NoteCategorySection(category: c));
        }
      }
    }
    return children;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return CustomScrollView(
      key: const PageStorageKey('outline-notes'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space16,
            AppTokens.space12,
            AppTokens.space16,
            AppTokens.space48,
          ),
          sliver: SliverList(
            delegate: SliverChildListDelegate(_buildChildren()),
          ),
        ),
      ],
    );
  }
}

/// 한 카테고리의 note 섹션. note 가 0건이면 통째로 hide (빈 헤더 노이즈 방지).
class _NoteCategorySection extends ConsumerWidget {
  const _NoteCategorySection({required this.category});

  final Category category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(notesOfCategoryProvider(category)).asData?.value;
    if (notes == null || notes.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      key: ValueKey('outline-note-section-${category.id}'),
      padding: const EdgeInsets.only(bottom: AppTokens.space16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.space8,
              vertical: AppTokens.space8,
            ),
            child: Row(
              children: [
                Icon(category.icon, size: 18, color: category.color),
                const SizedBox(width: AppTokens.space8),
                Expanded(
                  child: Text(
                    category.label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${notes.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: category.color,
                  ),
                ),
              ],
            ),
          ),
          for (final n in notes) _NoteCard(note: n),
        ],
      ),
    );
  }
}

/// 단일 메모 카드 — 제목 + (있으면) 본문 미리보기. 체크 토글 없음.
///
/// 탭 시 편집/상세 시트(AddTodoSheet)를 연다 — 체크리스트 탭의 leaf 와 동일 패턴.
/// (메모 탭 note 는 `!hasTaskDescendant` = 하위 task 없는 순수 메모이므로 leaf 취급.)
class _NoteCard extends ConsumerWidget {
  const _NoteCard({required this.note});

  final Todo note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final desc = note.description;

    // 체크리스트 leaf 의 openEdit 과 동일 — edit 모드 시트로 전체 메모를 조회/편집.
    Future<void> openEdit() => AddTodoSheet.show(
      context,
      initialCategory: note.category,
      initialTodo: note,
      onSubmit: (_) {},
      onUpdate: (updated) => ref.read(todoActionsProvider).update(updated),
      onRequestMove: (t) => showMoveTodoSheet(context, ref, item: t),
    );

    // §13 — TodoTile note 와 동일한 NoteVisual 토큰을 공유해 시각 언어 통일.
    // 틴트 배경 + 좌측 accent 보더 + 카테고리색 글리프 + non-italic 제목.
    // (메모 탭은 전체가 메모라 per-card "메모" 라벨은 맥락상 중복 → 생략.)
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space4,
        vertical: AppTokens.space4,
      ),
      child: InkWell(
        onTap: openEdit,
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        child: Container(
          key: ValueKey('outline-note-${note.id}'),
          padding: const EdgeInsets.all(AppTokens.space12),
          decoration: BoxDecoration(
            color: NoteVisual.tint(note.category, theme.brightness),
            borderRadius: BorderRadius.circular(AppTokens.radiusM),
            border: Border(
              left: BorderSide(
                color: NoteVisual.accent(note.category),
                width: NoteVisual.accentWidth,
              ),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.sticky_note_2_outlined,
                size: 16,
                color: NoteVisual.accent(note.category),
              ),
              const SizedBox(width: AppTokens.space8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (desc != null && desc.trim().isNotEmpty) ...[
                      const SizedBox(height: AppTokens.space4),
                      Text(
                        desc,
                        style: theme.textTheme.bodySmall,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `done/total` 진척 pill. 완료(done==total)면 체크 아이콘 + 진한 배경으로 강조.
/// note 는 카운트에서 이미 제외됨. 텍스트 `$done/$total` 는 그대로 노출(테스트 계약).
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
