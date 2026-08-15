import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../domain/todo.dart';
import 'dismissible_todo_tile.dart';

/// 오늘 화면 전용 — root todo 들을 **카테고리별 섹션**으로 묶어 그리는 sliver 목록.
///
/// 헤더와 항목이 **하나의 [SliverReorderableList]** 안에 섞여 있다. 섹션마다 독립
/// 리스트로 두면 섹션 경계를 넘는 드래그를 받아 줄 곳이 없어, 다른 카테고리로 끌어다
/// 놓아도 항목이 제자리로 되돌아간다 (실사용에서 "위아래 드래그가 사라졌다" 로 보였다).
/// 한 리스트로 합치면 드롭 지점이 어느 섹션인지 계산할 수 있고, 그래서:
///
///  - 같은 섹션 안에 놓으면 → [onReorderSiblings] (순서만 변경)
///  - 다른 섹션에 놓으면 → [onMoveToCategory] (그 카테고리로 이동 + 그 자리에 삽입)
///
/// 헤더는 드래그 리스너를 달지 않아 끌 수 없다 — 순서 계산에만 참여한다.
///
/// 자식 유무·드릴다운·＋하위추가·스와이프 삭제·체크 토글은 [DismissibleTodoTile] 의
/// 규칙을 그대로 유지한다.
///
/// 반환값은 `CustomScrollView.slivers` 에 `...spread` 로 펼쳐 넣는다.
List<Widget> todayCategorySectionSlivers({
  required List<Todo> roots,
  required List<Todo> allTodos,
  required List<Group> groups,
  required bool showGroupLabel,
  required void Function(Todo folder) onDrillDown,
  required void Function(Todo leaf) onEdit,
  required void Function(Todo) onToggle,
  void Function(Todo)? onToggleInProgress,
  required void Function(Todo parent) onAddChild,
  required void Function(Todo) onMove,
  required void Function(Todo) onCopy,
  required void Function(Todo) onDelete,
  required void Function(List<Todo> siblings, int oldIndex, int newIndex)
  onReorderSiblings,

  /// 섹션 간 드래그 — [item] 을 [target] 카테고리의 [targetItems] 중
  /// [insertIndex] 자리(제거 후 기준)로 옮긴다.
  required void Function(
    Todo item,
    Category target,
    List<Todo> targetItems,
    int insertIndex,
  )
  onMoveToCategory,
  Map<String, int> hiddenCountBySeries = const {},
  void Function(Todo)? onStopRecurrence,
}) {
  // parentId → 직속 자식 수 (드릴 배지 / 편집 분기 판정용).
  final childCounts = <String, int>{};
  for (final t in allTodos) {
    final pid = t.parentId;
    if (pid == null) continue;
    childCounts[pid] = (childCounts[pid] ?? 0) + 1;
  }

  // 카테고리별 묶음 — roots 순서(=dao sortOrder)를 보존한다.
  final orderedCatIds = <String>[];
  final byCat = <String, List<Todo>>{};
  final catOf = <String, Category>{};
  for (final t in roots) {
    final cid = t.category.id;
    if (!byCat.containsKey(cid)) {
      orderedCatIds.add(cid);
      byCat[cid] = [];
    }
    byCat[cid]!.add(t);
    catOf[cid] = t.category;
  }
  if (orderedCatIds.isEmpty) return const [];

  // 섹션 정렬: (그룹 sortOrder, 카테고리 sortOrder). 미분류(groupId==null)는 맨 위.
  final groupSort = {for (final g in groups) g.id: g.sortOrder};
  final groupLabel = {for (final g in groups) g.id: g.label};
  orderedCatIds.sort((a, b) {
    final ca = catOf[a]!, cb = catOf[b]!;
    final ga = ca.groupId == null ? -1 : (groupSort[ca.groupId] ?? 1 << 20);
    final gb = cb.groupId == null ? -1 : (groupSort[cb.groupId] ?? 1 << 20);
    if (ga != gb) return ga.compareTo(gb);
    if (ca.sortOrder != cb.sortOrder) {
      return ca.sortOrder.compareTo(cb.sortOrder);
    }
    return ca.label.compareTo(cb.label);
  });

  // 헤더 + 항목을 한 줄기로 편다. 드롭 지점이 어느 섹션인지 이 순서에서 역산한다.
  final entries = <_SectionEntry>[];
  for (final cid in orderedCatIds) {
    entries.add(_SectionEntry.header(cid));
    for (final t in byCat[cid]!) {
      entries.add(_SectionEntry.item(cid, t));
    }
  }

  void handleReorder(int oldIndex, int newIndex) {
    final dragged = entries[oldIndex].todo;
    if (dragged == null) return; // 헤더는 끌 수 없다 (리스너 미부착).

    // ReorderableList 규약 — newIndex 는 **제거 전** 기준. 제거 후 좌표로 바꾼다.
    final rest = [...entries]..removeAt(oldIndex);
    var pos = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (pos < 0) pos = 0;
    if (pos > rest.length) pos = rest.length;

    // 삽입 지점을 지배하는 헤더 = 그 앞의 마지막 헤더. 그 뒤로 센 항목 수가
    // 섹션 안에서의 자리다. 첫 헤더보다 위에 놓으면 첫 섹션의 맨 위로 본다.
    var destCid = orderedCatIds.first;
    var indexInDest = 0;
    for (var i = 0; i < pos; i++) {
      final e = rest[i];
      if (e.todo == null) {
        destCid = e.categoryId;
        indexInDest = 0;
      } else {
        indexInDest++;
      }
    }

    final destItems = byCat[destCid]!;
    if (destCid == dragged.category.id) {
      final oldInDest = destItems.indexWhere((t) => t.id == dragged.id);
      if (oldInDest < 0) return;
      // onReorderSiblings 도 "제거 전" 인덱스 규약 → 뒤로 가는 이동은 +1 보정.
      final newInDest = indexInDest >= oldInDest
          ? indexInDest + 1
          : indexInDest;
      onReorderSiblings(destItems, oldInDest, newInDest);
    } else {
      onMoveToCategory(dragged, catOf[destCid]!, destItems, indexInDest);
    }
  }

  return [
    SliverReorderableList(
      itemCount: entries.length,
      onReorder: handleReorder,
      itemBuilder: (context, i) {
        final entry = entries[i];
        final cat = catOf[entry.categoryId]!;
        final todo = entry.todo;

        if (todo == null) {
          final items = byCat[entry.categoryId]!;
          final tasks = items.where((t) => t.type == TodoType.task);
          final total = tasks.length;
          final done = tasks.where((t) => t.isDone).length;
          final gLabel = (showGroupLabel && cat.groupId != null)
              ? groupLabel[cat.groupId]
              : null;
          return Padding(
            key: ValueKey('today-section-${entry.categoryId}'),
            padding: EdgeInsets.fromLTRB(
              AppTokens.space24,
              i == 0 ? AppTokens.space8 : AppTokens.space24,
              AppTokens.space24,
              AppTokens.space12,
            ),
            child: _CategorySectionHeader(
              category: cat,
              groupLabel: gLabel,
              done: done,
              total: total,
            ),
          );
        }

        final childCount = childCounts[todo.id] ?? 0;
        final hasChildren = childCount > 0;
        return Padding(
          key: ValueKey('drill-node-${todo.id}'),
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space24,
            0,
            AppTokens.space24,
            AppTokens.space8,
          ),
          child: ReorderableDelayedDragStartListener(
            index: i,
            child: DismissibleTodoTile(
              todo: todo,
              onToggle: () => onToggle(todo),
              onToggleInProgress: onToggleInProgress == null
                  ? null
                  : () => onToggleInProgress(todo),
              onDelete: () => onDelete(todo),
              onTap: () => hasChildren ? onDrillDown(todo) : onEdit(todo),
              // §14 — note 도 자식(헤딩) 보유 가능 → 타입 무관 ＋하위 추가.
              onAddChild: () => onAddChild(todo),
              // 더보기(⋮) 메뉴 — 이동 / 복사 / 편집(이 항목 자체) / 삭제.
              onMove: () => onMove(todo),
              onCopy: () => onCopy(todo),
              onEditItem: () => onEdit(todo),
              drillChildCount: hasChildren ? childCount : null,
              childCount: childCount,
              hiddenSeriesCount: todo.seriesId == null
                  ? 0
                  : (hiddenCountBySeries[todo.seriesId] ?? 0),
              onStopRecurrence: onStopRecurrence == null
                  ? null
                  : () => onStopRecurrence(todo),
            ),
          ),
        );
      },
    ),
  ];
}

/// 평탄화된 한 줄 — 카테고리 헤더([todo] 가 null) 또는 그 카테고리의 항목.
class _SectionEntry {
  const _SectionEntry.header(this.categoryId) : todo = null;
  const _SectionEntry.item(this.categoryId, this.todo);

  final String categoryId;
  final Todo? todo;
}

/// 카테고리 섹션 헤더 — 아이콘 배지 + 카테고리 라벨 + (선택) 그룹 라벨 + 진척.
class _CategorySectionHeader extends StatelessWidget {
  const _CategorySectionHeader({
    required this.category,
    required this.groupLabel,
    required this.done,
    required this.total,
  });

  final Category category;
  final String? groupLabel;
  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = category.color;
    final ratio = total == 0 ? 0.0 : done / total;
    final allDone = total > 0 && done >= total;

    return Row(
      children: [
        // 카테고리 아이콘 배지 — soft tint 배경 + 카테고리 색 아이콘.
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(AppTokens.radiusM),
          ),
          child: Icon(category.icon, size: 17, color: color),
        ),
        const SizedBox(width: AppTokens.space12),
        Flexible(
          child: Text(
            category.label,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (groupLabel != null) ...[
          const SizedBox(width: AppTokens.space8),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.space8,
              vertical: AppTokens.space2,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppTokens.radiusFull),
            ),
            child: Text(
              groupLabel!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.75),
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        const Spacer(),
        // 진척 — task 가 있을 때만. mini 바 + 분수.
        if (total > 0) ...[
          Container(
            width: 40,
            height: 5,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(AppTokens.radiusFull),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: ratio.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppTokens.space8),
          Text(
            '$done/$total',
            style: theme.textTheme.labelMedium?.copyWith(
              color: allDone ? color : scheme.onSurface.withValues(alpha: 0.7),
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}
