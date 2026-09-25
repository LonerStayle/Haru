import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/ui_prefs.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/add_entity_buttons.dart';
import '../category/categories_controller.dart';
import '../category/category_actions.dart';
import '../category/groups_controller.dart';
import '../outline/tree_providers.dart';

/// 모바일 하단 네비 4번째 칸 "카테고리" — 그룹 → 카테고리 목록 화면.
///
/// UX 개선 Phase 2: 예전엔 이 칸이 관리 Drawer 를 열었고, Drawer 와 사이드바가 각자
/// 메뉴·다이얼로그를 복제해 들고 있었다. 이제 이동(카테고리 열기)과 관리(메뉴·순서)를
/// 이 화면 하나가 맡고, 메뉴는 [CategoryActions] 를 데스크탑 사이드바와 공유한다.
///
/// 제스처 (할 일 목록과 같은 규칙):
/// - 행 탭 → 그 카테고리 화면.
/// - 행 길게 누르기 / ⋮ → 메뉴 (수정 · 그룹 이동 · 보관 · 삭제).
/// - ⠿ 끌기 → 다른 행 위에 놓으면 그 자리로(그룹이 달라도), 그룹 머리에 놓으면 그 그룹
///   맨 뒤로, "미분류" 에 놓으면 그룹에서 뺀다. 드래그는 ⠿ 하나로 순서와 그룹을 모두.
/// - 그룹 머리 탭 → 펼치기/접기 (여러 그룹 동시에, 앱을 다시 켜도 유지).
///   길게 누르기 / ⋮ → 그룹 메뉴 (전체보기에서 보기 · 수정 · 카테고리 추가 · 보관 · 삭제).
///   그룹 머리의 ⠿ → 그룹 순서 변경.
class CategoryListScreen extends ConsumerStatefulWidget {
  const CategoryListScreen({
    super.key,
    required this.onSelectCategory,
    required this.onOpenGroup,
  });

  /// 카테고리 행 탭 — 그 카테고리 화면으로.
  final ValueChanged<Category> onSelectCategory;

  /// 그룹 메뉴 "전체보기에서 보기" — 전체보기 + 그 그룹 필터로.
  final ValueChanged<Group> onOpenGroup;

  /// 접힌 그룹 id 집합의 저장 키.
  static const collapsedKey = 'categories.collapsedGroups';

  @override
  ConsumerState<CategoryListScreen> createState() => _CategoryListScreenState();
}

class _CategoryListScreenState extends ConsumerState<CategoryListScreen> {
  /// 드래그 중인 카테고리가 올라가 있는 그룹 머리(id) 또는 미분류([_ungroupedKey]).
  Object? _hoverTarget;

  static const Object _ungroupedKey = Object();

  CategoryActions get _actions => CategoryActions.of(context);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final categories =
        ref.watch(activeCategoriesProvider).asData?.value ??
        Category.builtinSeeds;
    final groups =
        ref.watch(activeGroupsProvider).asData?.value ?? const <Group>[];
    final collapsed = ref.watch(
      persistedIdSetProvider(CategoryListScreen.collapsedKey),
    );
    final undoneByCategory = _undoneCounts(
      ref.watch(allTodosProvider).asData?.value ?? const <Todo>[],
    );

    // 카테고리를 그룹별로. 없는 그룹을 가리키는 카테고리는 미분류로.
    final groupIds = {for (final g in groups) g.id};
    final ungrouped = <Category>[];
    final byGroup = <String, List<Category>>{};
    for (final c in categories) {
      final gid = c.groupId;
      if (gid == null || !groupIds.contains(gid)) {
        ungrouped.add(c);
      } else {
        byGroup.putIfAbsent(gid, () => <Category>[]).add(c);
      }
    }

    Widget rows(List<Category> siblings, String? groupId) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in siblings)
          _CategoryDropRow(
            key: ValueKey('manage-cat-${c.id}'),
            target: c,
            targetGroupId: groupId,
            siblings: siblings,
            onMoveInto: (dragged, gid, ordered, at) => ref
                .read(categoriesControllerProvider)
                .moveCategoryInto(dragged, gid, ordered, at),
            child: _CategoryRow(
              category: c,
              undone: undoneByCategory[c.id] ?? 0,
              onTap: () => widget.onSelectCategory(c),
              onMenu: () => _actions.showCategoryMenu(c),
            ),
          ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            key: const PageStorageKey('category-list'),
            padding: const EdgeInsets.only(
              top: AppTokens.space8,
              bottom: AppTokens.space8,
            ),
            children: [
              // 그룹들 — 머리의 ⠿ 로 그룹 순서 변경.
              if (groups.isNotEmpty)
                ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  onReorder: (o, n) =>
                      ref.read(groupsControllerProvider).reorder(groups, o, n),
                  proxyDecorator: (child, index, animation) =>
                      Material(color: Colors.transparent, child: child),
                  children: [
                    for (var i = 0; i < groups.length; i++)
                      Column(
                        key: ValueKey('manage-group-${groups[i].id}'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _GroupHeader(
                            group: groups[i],
                            reorderIndex: i,
                            count: byGroup[groups[i].id]?.length ?? 0,
                            collapsed: collapsed.contains(groups[i].id),
                            hovering: _hoverTarget == groups[i].id,
                            onToggle: () => ref
                                .read(
                                  persistedIdSetProvider(
                                    CategoryListScreen.collapsedKey,
                                  ).notifier,
                                )
                                .toggle(groups[i].id),
                            onMenu: () => _actions.showGroupMenu(
                              groups[i],
                              onOpen: () => widget.onOpenGroup(groups[i]),
                            ),
                            onHover: (h) => setState(
                              () => _hoverTarget = h ? groups[i].id : null,
                            ),
                            onAccept: (cat) {
                              setState(() => _hoverTarget = null);
                              _actions.moveCategoryToGroup(cat, groups[i].id);
                            },
                          ),
                          if (!collapsed.contains(groups[i].id))
                            (byGroup[groups[i].id] ?? const []).isEmpty
                                ? const _EmptyHint(
                                    text: '카테고리를 ⠿ 로 끌어다 놓으면 이 그룹에 들어가요',
                                  )
                                : rows(byGroup[groups[i].id]!, groups[i].id),
                        ],
                      ),
                  ],
                ),
              // 미분류 — 그룹 아래. 그룹이 없으면 제목 없이 목록만.
              _UngroupedZone(
                showLabel: groups.isNotEmpty,
                hovering: _hoverTarget == _ungroupedKey,
                onHover: (h) =>
                    setState(() => _hoverTarget = h ? _ungroupedKey : null),
                onAccept: (cat) {
                  setState(() => _hoverTarget = null);
                  _actions.moveCategoryToGroup(cat, null);
                },
                child: ungrouped.isEmpty
                    ? (groups.isNotEmpty
                          ? const _EmptyHint(text: '여기로 끌어 놓으면 그룹에서 빠져요')
                          : const SizedBox.shrink())
                    : rows(ungrouped, null),
              ),
            ],
          ),
        ),
        Divider(height: AppTokens.hairline, color: scheme.outlineVariant),
        const AddEntityButtons(),
        const SizedBox(height: AppTokens.space4),
      ],
    );
  }

  /// 카테고리별 남은 할 일(미완료 task) 수.
  static Map<String, int> _undoneCounts(List<Todo> todos) {
    final counts = <String, int>{};
    for (final t in todos) {
      if (t.type != TodoType.task || t.isDone) continue;
      counts[t.category.id] = (counts[t.category.id] ?? 0) + 1;
    }
    return counts;
  }
}

/// 카테고리 한 행 — 아이콘 · 이름 · 남은 수 · ⋮ · ⠿.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.undone,
    required this.onTap,
    required this.onMenu,
  });

  final Category category;
  final int undone;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space12,
        vertical: AppTokens.space2,
      ),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        child: InkWell(
          onTap: onTap,
          onLongPress: onMenu,
          onSecondaryTap: onMenu,
          borderRadius: BorderRadius.circular(AppTokens.radiusM),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.only(left: AppTokens.space12),
              child: Row(
                children: [
                  Icon(category.icon, size: 20, color: category.color),
                  const SizedBox(width: AppTokens.space12),
                  Expanded(
                    child: Text(
                      category.label,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (undone > 0)
                    Text(
                      '$undone',
                      key: ValueKey('manage-cat-count-${category.id}'),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  IconButton(
                    key: ValueKey('manage-cat-menu-${category.id}'),
                    onPressed: onMenu,
                    tooltip: '메뉴',
                    icon: Icon(Icons.more_vert, size: 20, color: muted),
                  ),
                  // ⠿ — 끌어서 순서 변경·그룹 이동 (위 DragTarget 들이 받는다).
                  Draggable<Category>(
                    data: category,
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    feedback: _DragFeedback(category: category),
                    childWhenDragging: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(
                        Icons.drag_indicator,
                        color: scheme.onSurface.withValues(alpha: 0.2),
                      ),
                    ),
                    child: SizedBox(
                      key: ValueKey('manage-cat-drag-${category.id}'),
                      width: 44,
                      height: 44,
                      child: Icon(Icons.drag_indicator, color: muted),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 카테고리 행 — 다른 카테고리를 이 행 위에 놓으면 이 행 자리(앞)로 옮긴다
/// (다른 그룹에서 왔으면 그룹도 바뀐다). hover 중이면 윗변에 삽입선.
class _CategoryDropRow extends StatefulWidget {
  const _CategoryDropRow({
    super.key,
    required this.target,
    required this.targetGroupId,
    required this.siblings,
    required this.onMoveInto,
    required this.child,
  });

  final Category target;
  final String? targetGroupId;
  final List<Category> siblings;
  final void Function(
    Category dragged,
    String? targetGroupId,
    List<Category> orderedSiblings,
    int insertIndex,
  )
  onMoveInto;
  final Widget child;

  @override
  State<_CategoryDropRow> createState() => _CategoryDropRowState();
}

class _CategoryDropRowState extends State<_CategoryDropRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<Category>(
      onWillAcceptWithDetails: (details) {
        final ok = details.data.id != widget.target.id;
        if (ok && !_hovering) setState(() => _hovering = true);
        return ok;
      },
      onLeave: (_) => setState(() => _hovering = false),
      onAcceptWithDetails: (details) {
        setState(() => _hovering = false);
        final dragged = details.data;
        final others = widget.siblings
            .where((c) => c.id != dragged.id)
            .toList();
        var at = others.indexWhere((c) => c.id == widget.target.id);
        if (at < 0) at = others.length;
        widget.onMoveInto(dragged, widget.targetGroupId, others, at);
      },
      builder: (context, candidate, rejected) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: _hovering ? scheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: widget.child,
      ),
    );
  }
}

/// 그룹 머리 — 탭 = 펼치기/접기, 길게 누르기·⋮ = 그룹 메뉴, ⠿ = 그룹 순서.
/// 카테고리를 여기 놓으면 이 그룹 맨 뒤로 옮긴다.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.reorderIndex,
    required this.count,
    required this.collapsed,
    required this.hovering,
    required this.onToggle,
    required this.onMenu,
    required this.onHover,
    required this.onAccept,
  });

  final Group group;
  final int reorderIndex;
  final int count;
  final bool collapsed;
  final bool hovering;
  final VoidCallback onToggle;
  final VoidCallback onMenu;
  final ValueChanged<bool> onHover;
  final ValueChanged<Category> onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.6);
    return DragTarget<Category>(
      onWillAcceptWithDetails: (details) {
        final ok = details.data.groupId != group.id;
        onHover(ok);
        return ok;
      },
      onLeave: (_) => onHover(false),
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidate, rejected) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space8,
          AppTokens.space8,
          AppTokens.space8,
          AppTokens.space2,
        ),
        child: Material(
          color: hovering
              ? group.color.withValues(alpha: 0.18)
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusM),
            side: hovering
                ? BorderSide(color: group.color, width: 1.6)
                : BorderSide.none,
          ),
          child: InkWell(
            key: ValueKey('manage-group-header-${group.id}'),
            borderRadius: BorderRadius.circular(AppTokens.radiusM),
            onTap: onToggle,
            onLongPress: onMenu,
            onSecondaryTap: onMenu,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                children: [
                  const SizedBox(width: AppTokens.space8),
                  AnimatedRotation(
                    turns: collapsed ? 0 : 0.25,
                    duration: AppTokens.motionFast,
                    child: Icon(Icons.chevron_right, size: 20, color: muted),
                  ),
                  const SizedBox(width: AppTokens.space4),
                  Icon(Icons.circle, size: 12, color: group.color),
                  const SizedBox(width: AppTokens.space8),
                  Expanded(
                    child: Text(
                      group.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (collapsed && count > 0)
                    Text(
                      '카테고리 $count',
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                  IconButton(
                    key: ValueKey('manage-group-menu-${group.id}'),
                    onPressed: onMenu,
                    tooltip: '그룹 메뉴',
                    icon: Icon(Icons.more_vert, size: 20, color: muted),
                  ),
                  ReorderableDragStartListener(
                    index: reorderIndex,
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(Icons.drag_indicator, color: muted),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 미분류 구역 — 카테고리를 놓으면 그룹에서 뺀다.
class _UngroupedZone extends StatelessWidget {
  const _UngroupedZone({
    required this.showLabel,
    required this.hovering,
    required this.onHover,
    required this.onAccept,
    required this.child,
  });

  final bool showLabel;
  final bool hovering;
  final ValueChanged<bool> onHover;
  final ValueChanged<Category> onAccept;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DragTarget<Category>(
      onWillAcceptWithDetails: (details) {
        final ok = details.data.groupId != null;
        onHover(ok);
        return ok;
      },
      onLeave: (_) => onHover(false),
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidate, rejected) => Container(
        key: const ValueKey('manage-ungrouped'),
        margin: const EdgeInsets.fromLTRB(
          AppTokens.space4,
          AppTokens.space8,
          AppTokens.space4,
          0,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTokens.radiusM),
          color: hovering
              ? scheme.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          border: hovering
              ? Border.all(color: scheme.primary, width: 1.4)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showLabel)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.space16,
                  AppTokens.space8,
                  AppTokens.space16,
                  AppTokens.space4,
                ),
                child: Text(
                  '미분류',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space20,
        vertical: AppTokens.space8,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

/// 끄는 동안 손가락 아래 떠다니는 칩.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.category});

  final Category category;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space12,
          vertical: AppTokens.space8,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
          border: Border.all(color: category.color, width: 1.6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(category.icon, size: 16, color: category.color),
            const SizedBox(width: AppTokens.space8),
            Text(
              category.label,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
