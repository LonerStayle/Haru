import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/categories_repository.dart';
import '../../data/providers.dart';
import '../../domain/category.dart';
import '../../domain/policies/category_delete_policy.dart';

/// 카테고리 한 건에 대한 도메인 액션 (add / delete).
///
/// v1.2 — Categories 는 DB row 로 저장되어 사용자가 추가 / 삭제 가능. builtin 도
/// 삭제 가능하지만 카테고리에 속한 todos 가 ≥1 이면 [CategoryDeletePolicy] 가
/// 차단한다 — UI 는 [DeleteCheck.blockedByTodos] 결과로 차단 dialog 를 띄운다.
///
/// Repository abstraction (LocalCategoriesRepository / SyncingCategoriesRepository)
/// 위에 동작 — production 에선 outbox + Supabase push 까지 자동.
class CategoriesController {
  CategoriesController(this._repo);

  final CategoriesRepository _repo;

  /// 새 카테고리 추가 (또는 기존 id 면 update — label / color / icon / sortOrder 갱신).
  Future<void> add(Category category) => _repo.upsert(category);

  /// 카테고리를 그룹으로 이동 (또는 [groupId] == null 이면 미분류로). 사이드바의
  /// '그룹 이동' 메뉴가 호출. 대상 카테고리가 없으면 no-op.
  Future<void> moveToGroup(String categoryId, String? groupId) async {
    final category = await _repo.getById(categoryId);
    if (category == null) return;
    await _repo.upsert(category.copyWith(groupId: groupId));
  }

  /// 작업 2 (K) — 같은 그룹(또는 미분류) 안에서 카테고리 순서를 드래그로 변경.
  ///
  /// [siblings] 는 현재 화면 표시 순서(작은 sortOrder = 위)의 같은 그룹 카테고리들.
  /// ReorderableList 의 ([oldIndex], [newIndex]) 시맨틱을 받아 그 집합에 **연속
  /// 오름차순** sortOrder 를 재부여하고, 값이 바뀐 카테고리만 [repo.upsert]
  /// (동기화 포함). 그룹 소속(groupId)은 바꾸지 않는다 — 순서만.
  ///
  /// 기준값은 집합의 기존 min sortOrder (없으면 0) — 그룹의 화면 위치가 유지된다.
  Future<void> reorderInGroup(
    List<Category> siblings,
    int oldIndex,
    int newIndex,
  ) async {
    if (siblings.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= siblings.length) return;
    // ReorderableList 의 newIndex 는 제거 전 인덱스 기준 → oldIndex 보다 크면 -1 보정.
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= siblings.length) target = siblings.length - 1;
    if (target == oldIndex) return; // 변화 없음.

    final reordered = List<Category>.of(siblings);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(target, moved);

    // base = 기존 집합의 최소 sortOrder (그룹 화면 위치 유지). 비어있을 수 없음.
    var base = siblings.first.sortOrder;
    for (final s in siblings) {
      if (s.sortOrder < base) base = s.sortOrder;
    }
    for (var i = 0; i < reordered.length; i++) {
      final desired = base + i;
      final c = reordered[i];
      if (c.sortOrder != desired) {
        await _repo.upsert(c.copyWith(sortOrder: desired));
      }
    }
  }

  /// 드래그→드롭 통합 — [dragged] 를 [targetGroupId] 그룹의 [insertIndex] 위치로 옮긴다.
  /// 그룹 이동(⠿ 를 그룹 헤더/미분류로)과 순서변경(다른 행 위로)을 한 메서드로 처리한다.
  ///
  /// [orderedSiblings] 는 **대상 그룹의 현재 화면 순서**(작은 sortOrder = 위)에서 [dragged]
  /// 자신을 제외한 카테고리들. [insertIndex] 는 그 리스트 기준 삽입 위치(0 = 맨 위,
  /// length = 맨 아래). 대상 그룹 전체에 연속 sortOrder 를 재부여하고, groupId/sortOrder 가
  /// 실제 바뀐 카테고리만 upsert (동기화 포함).
  Future<void> moveCategoryInto(
    Category dragged,
    String? targetGroupId,
    List<Category> orderedSiblings,
    int insertIndex,
  ) async {
    final list = List<Category>.of(orderedSiblings);
    var idx = insertIndex;
    if (idx < 0) idx = 0;
    if (idx > list.length) idx = list.length;
    list.insert(idx, dragged);

    // base = 대상 그룹 기존 최소 sortOrder (그룹의 상대 위치 유지). 비어있으면 0.
    var base = 0;
    if (orderedSiblings.isNotEmpty) {
      base = orderedSiblings.first.sortOrder;
      for (final s in orderedSiblings) {
        if (s.sortOrder < base) base = s.sortOrder;
      }
    }
    for (var i = 0; i < list.length; i++) {
      final c = list[i];
      final desiredSort = base + i;
      if (c.groupId != targetGroupId || c.sortOrder != desiredSort) {
        await _repo.upsert(
          c.copyWith(groupId: targetGroupId, sortOrder: desiredSort),
        );
      }
    }
  }

  /// 카테고리 보관 — 활성 화면(사이드바/탭/오늘/타임라인/전체보기)에서 숨긴다.
  /// 데이터는 보존되며, 삭제와 달리 안 todos 가 있어도 허용된다 (그게 보관의 목적).
  /// 대상이 없거나 이미 보관 상태면 no-op (idempotent).
  Future<void> archive(String id) => _setArchived(id, true);

  /// 카테고리 복원 — 보관 해제. 원래 그룹/순서 그대로 활성 화면에 되돌아온다.
  Future<void> unarchive(String id) => _setArchived(id, false);

  Future<void> _setArchived(String id, bool archived) async {
    final category = await _repo.getById(id);
    if (category == null || category.archived == archived) return;
    await _repo.upsert(category.copyWith(archived: archived));
  }

  /// id 기준 삭제 시도.
  ///
  /// 반환값:
  /// - [DeleteCheck.ok] — 정책 통과 + delete 완료 (또는 이미 없어서 idempotent).
  /// - [DeleteCheck.blockedByTodos] — 안 todos 가 N건 있어 차단됨. 호출자는
  ///   안내 dialog 를 띄우고 todos 처리를 요청한다.
  Future<DeleteCheck> delete(String id) async {
    final category = await _repo.getById(id);
    if (category == null) {
      // 이미 없으면 ok 반환 (idempotent — 같은 명령 두 번 실행해도 안전).
      return const DeleteCheck.ok();
    }
    final count = await _repo.countTodosOfCategory(id);
    final check = CategoryDeletePolicy.canDelete(category, count);
    if (check.isOk) {
      await _repo.deleteById(id);
    }
    return check;
  }
}

/// 전체 카테고리 stream (보관 포함) — [activeCategoriesProvider] /
/// [archivedCategoriesProvider] 파생의 단일 원본이자 테스트 override 지점.
final categoriesProvider = StreamProvider<List<Category>>((ref) {
  return ref.watch(categoriesRepositoryProvider).watchAll();
});

/// 활성 카테고리 (보관 제외) — 사이드바/탭/오늘/타임라인/전체보기의 단일 출처.
/// 보관된 카테고리는 여기서 걸러져 활성 화면 어디에도 나타나지 않는다.
final activeCategoriesProvider = Provider<AsyncValue<List<Category>>>((ref) {
  return ref
      .watch(categoriesProvider)
      .whenData((list) => list.where((c) => !c.archived).toList());
});

/// 보관된 카테고리 — 설정 > 보관함 (복원 대상).
final archivedCategoriesProvider = Provider<AsyncValue<List<Category>>>((ref) {
  return ref
      .watch(categoriesProvider)
      .whenData((list) => list.where((c) => c.archived).toList());
});

/// 보관된 카테고리 id 집합 — 오늘/타임라인에서 그 카테고리의 todo 를 숨길 때 사용.
///
/// "활성 집합에 든 것만 남긴다"(화이트리스트)가 아니라 "보관된 것만 뺀다"(블랙리스트)
/// 방식이라, 카테고리가 아직 로딩 전이거나 orphan(삭제된 카테고리를 참조) 인 todo 는
/// 그대로 보인다 — 명시적으로 보관된 카테고리의 todo 만 사라진다. 로딩 중엔 빈 집합.
final archivedCategoryIdsProvider = Provider<Set<String>>((ref) {
  final archived = ref.watch(archivedCategoriesProvider).asData?.value;
  return archived == null
      ? const <String>{}
      : archived.map((c) => c.id).toSet();
});

final categoriesControllerProvider = Provider<CategoriesController>((ref) {
  return CategoriesController(ref.watch(categoriesRepositoryProvider));
});
