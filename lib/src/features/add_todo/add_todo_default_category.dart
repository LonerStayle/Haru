import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../ui/destination.dart';

/// 새 할일 추가 시 기본 카테고리 = "지금 보고 있는 화면" 과 동일한 규칙으로 결정.
///
/// 우선순위:
///   1. 그룹 화면(존재하는 [selectedGroupId]) → 그 그룹의 (sortOrder 상) 첫 카테고리
///   2. 카테고리 화면 → 그 카테고리 (`destinations[safeIndex].category`)
///   3. 오늘/전체보기/타임라인 등 컨텍스트 없음 → 카테고리 목록의 첫 항목
///
/// 목록이 비면 [Category.builtinSeeds] 의 첫 항목으로 fallback.
///
/// [index] 가 [destinations] 범위를 벗어나면 `AppShell` build 의 `safeIndex` 와 동일하게
/// 0(오늘)으로 클램프한다 — 비동기 카테고리 리로드로 index 가 잠깐 어긋나도 "표시 중인
/// 화면" 과 항상 일치시켜, 보던 카테고리와 다른 값이 기본 선택되던 문제를 막는다.
Category resolveAddTodoDefaultCategory({
  required List<Category> categories,
  required List<Group> groups,
  required List<AppDestination> destinations,
  required int index,
  required String? selectedGroupId,
}) {
  final fallback = categories.isNotEmpty
      ? categories.first
      : Category.builtinSeeds.first;

  // build 의 selectedGroup 판정과 동일 — 이미 삭제된 그룹 id 면 그룹 화면으로 보지 않는다.
  final onGroup =
      selectedGroupId != null && groups.any((g) => g.id == selectedGroupId);
  if (onGroup) {
    // categories 는 sortOrder 순이므로 firstWhere 가 그룹의 첫 카테고리.
    return categories.firstWhere(
      (c) => c.groupId == selectedGroupId,
      orElse: () => fallback,
    );
  }

  if (destinations.isEmpty) return fallback;
  final safeIndex = index >= 0 && index < destinations.length ? index : 0;
  return destinations[safeIndex].category ?? fallback;
}
