import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui_prefs.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../ui/destination.dart';

/// 새 할일 추가 시 기본 카테고리 = "지금 보고 있는 화면" 과 동일한 규칙으로 결정.
///
/// 우선순위:
///   1. 그룹 화면(존재하는 [selectedGroupId]) → 마지막에 쓴 카테고리가 그 그룹 안이면 그것,
///      아니면 그 그룹의 (sortOrder 상) 첫 카테고리
///   2. 카테고리 화면 → 그 카테고리 (`destinations[safeIndex].category`)
///   3. 오늘/전체보기/타임라인 등 컨텍스트 없음 → 마지막에 쓴 카테고리([lastUsedId]),
///      없거나 보관·삭제됐으면 **사이드바 표시 순서**의 첫 카테고리
///
/// 예전 3번은 `categories.first`(sortOrder 최소)였다. 그룹이 생긴 뒤로 sortOrder 최소가
/// 사이드바 첫 항목과 달라져, 오늘 화면에서 ⌘N 하면 거의 안 쓰는 카테고리로 시작했다.
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
  String? lastUsedId,
}) {
  final ordered = categoriesInSidebarOrder(categories, groups);
  final fallback = ordered.isNotEmpty
      ? ordered.first
      : Category.builtinSeeds.first;
  final lastUsed = lastUsedId == null
      ? null
      : categories.where((c) => c.id == lastUsedId).firstOrNull;

  // build 의 selectedGroup 판정과 동일 — 이미 삭제된 그룹 id 면 그룹 화면으로 보지 않는다.
  final onGroup =
      selectedGroupId != null && groups.any((g) => g.id == selectedGroupId);
  if (onGroup) {
    if (lastUsed != null && lastUsed.groupId == selectedGroupId) {
      return lastUsed;
    }
    // categories 는 sortOrder 순이므로 firstWhere 가 그룹의 첫 카테고리.
    return categories.firstWhere(
      (c) => c.groupId == selectedGroupId,
      orElse: () => fallback,
    );
  }

  if (destinations.isEmpty) return lastUsed ?? fallback;
  final safeIndex = index >= 0 && index < destinations.length ? index : 0;
  return destinations[safeIndex].category ?? lastUsed ?? fallback;
}

/// 사이드바와 같은 순서 — 그룹(sortOrder) 안의 카테고리(sortOrder) 먼저, 그룹 없는
/// 카테고리(또는 목록에 없는 그룹을 가리키는 카테고리)는 맨 아래.
List<Category> categoriesInSidebarOrder(
  List<Category> categories,
  List<Group> groups,
) {
  final sortedGroups = [...groups]
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  final byCategoryOrder = [...categories]
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  final known = {for (final g in sortedGroups) g.id};
  return [
    for (final g in sortedGroups)
      ...byCategoryOrder.where((c) => c.groupId == g.id),
    ...byCategoryOrder.where((c) => !known.contains(c.groupId)),
  ];
}

/// 새 할 일을 마지막으로 넣은 카테고리 id — 다음 ⌘N 의 기본값. 기기별 로컬 설정.
///
/// 앱 시작 직후 비동기로 복원된다. 복원 전에 새로 기록되면 그 값이 이긴다.
class LastUsedCategoryNotifier extends Notifier<String?> {
  static const key = 'add.lastCategory';

  bool _recorded = false;
  bool _disposed = false;

  /// 복원이 끝나는 Future — 테스트 대기용.
  late Future<void> restored;

  @override
  String? build() {
    _recorded = false;
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    restored = _restore();
    return null;
  }

  Future<void> _restore() async {
    try {
      final ids = await ref.read(uiPrefsStoreProvider).loadIds(key);
      if (!_disposed && !_recorded && ids.isNotEmpty) state = ids.first;
    } catch (_) {
      // 복원 실패 — 사이드바 첫 카테고리로 시작한다.
    }
  }

  Future<void> record(String categoryId) async {
    _recorded = true;
    if (state == categoryId) return;
    state = categoryId;
    try {
      await ref.read(uiPrefsStoreProvider).saveIds(key, {categoryId});
    } catch (_) {
      // 저장 실패 — 이번 세션 동안은 유지된다.
    }
  }
}

final lastUsedCategoryProvider =
    NotifierProvider<LastUsedCategoryNotifier, String?>(
      LastUsedCategoryNotifier.new,
    );
