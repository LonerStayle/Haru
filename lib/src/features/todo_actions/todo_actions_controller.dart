import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/todo_repository.dart';
import '../../domain/category.dart';
import '../../domain/policies/move_policy.dart';
import '../../domain/todo.dart';

/// Todo 한 건에 대한 도메인 액션 (체크 토글 / 삭제 / 카테고리 변경 등).
///
/// 로컬 Drift 의존이므로 upsert/delete 는 거의 즉시 완료된다 (수 ms).
/// Drift watch stream 이 자동으로 UI 갱신 — 별도 optimistic state 관리 불필요.
/// 비전상 "낙관적 업데이트 (UI 먼저)" 는 추후 원격 (Supabase) 으로 확장될 때
/// 의미가 커진다.
class TodoActionsController {
  TodoActionsController(this._repo, this._now);

  final TodoRepository _repo;
  final DateTime Function() _now;

  /// 체크 상태를 토글. 미체크 → 체크, 체크 → 미체크. updatedAt + doneAt 만 갱신.
  ///
  /// Task B 불변식 — **toggle 은 sortOrder 를 절대 바꾸지 않는다** (체크해도 자리 안 바뀜).
  /// [Todo.toggleDone] 이 doneAt/updatedAt 만 copyWith 하므로 sortOrder 는 그대로 보존된다.
  Future<Todo> toggle(Todo todo) async {
    final updated = todo.toggleDone(now: _now);
    await _repo.upsert(updated);
    return updated;
  }

  /// 진행중 상태를 토글. 미완료/완료 → 진행중, 진행중 → 미완료.
  ///
  /// Task B 불변식 — toggle 과 마찬가지로 **sortOrder 는 절대 바꾸지 않는다**
  /// ([Todo.toggleInProgress] 가 startedAt/doneAt/updatedAt 만 copyWith).
  Future<Todo> toggleInProgress(Todo todo) async {
    final updated = todo.toggleInProgress(now: _now);
    await _repo.upsert(updated);
    return updated;
  }

  /// id 기준 삭제. 호출자가 [restore] 로 되돌릴 수 있도록 원본은 호출자가 보관.
  Future<void> delete(Todo todo) => _repo.deleteById(todo.id);

  /// [delete] 로 지워진 Todo 를 그대로 복원 (id 동일, updatedAt 보존).
  /// Undo SnackBar 의 "되돌리기" 액션이 호출한다.
  Future<void> restore(Todo todo) => _repo.upsert(todo);

  /// [restore] 의 다건 버전 — 이동 직전 스냅샷(본인 + 자손)을 그대로 되돌려 쓴다.
  /// parentId / category / sortOrder / updatedAt 이 모두 원본 값으로 복구된다.
  Future<void> restoreAll(List<Todo> snapshot) async {
    for (final t in snapshot) {
      await _repo.upsert(t);
    }
  }

  /// v1.2 — 기존 todo 의 필드 수정 (title / description / category / dueAt / type).
  /// updatedAt 은 자동으로 [_now] 의 호출 시점 값으로 갱신 — LWW 동기화 호환.
  ///
  /// Task B — 대표님 요구: 시트 편집 시 그 항목을 **맨 위로** (수정 기준 최신 위로).
  /// 같은 형제(현재 category+parentId) min sortOrder - 1 로 bump. 형제가 자기 자신뿐이면
  /// 그대로 유지된다 (min == 자기 sortOrder → min-1 로 살짝 위, 무해).
  ///
  /// **단, 진짜 바뀐 게 있을 때만 올린다.** 목록에서 항목을 탭하면 편집 시트가 열리므로
  /// (= 열람 경로), 아무것도 고치지 않고 저장만 눌러도 bump 되면 조회만으로 자리가 튄다.
  /// 내용이 그대로면 [_isUnchanged] 가 잡아내 아무것도 쓰지 않는다 (updatedAt 도 보존).
  Future<Todo> update(Todo updated) async {
    final current = await _repo.getById(updated.id);
    if (current != null && _isUnchanged(current, updated)) return current;

    final minSibling = await _repo.minSiblingSortOrder(
      categoryId: updated.category.id,
      parentId: updated.parentId,
    );
    final bumped = (minSibling ?? updated.sortOrder) - 1;
    final now = _now();
    final synced = updated.copyWith(updatedAt: now, sortOrder: bumped);
    await _repo.upsert(synced);
    // 카테고리를 바꿨으면 자손도 통째로 따라간다. 이 앱은 자식이 부모 카테고리를
    // 상속하는 구조라, 본인만 옮기면 자손이 옛 카테고리 화면·집계에 남아 "카테고리를
    // 바꿨는데 절반만 옮겨간" 상태가 된다.
    if (current != null && current.category.id != synced.category.id) {
      await _syncSubtreeCategory(synced, now);
    }
    return synced;
  }

  /// v1.6 — 캘린더 드래그 전용 저장 경로. **sortOrder 를 보존**한다.
  ///
  /// [update] 는 "시트에서 편집하면 맨 위로" 규칙이라 sortOrder 를 형제 min-1 로
  /// bump 하는데, 달력에서 항목을 다른 날짜 칸으로 끄는 건 *순서* 조작이 아니라
  /// *일정* 조작이다. 그 경로에 bump 가 새면 날짜만 옮겼는데 '오늘'/'전체보기'
  /// 목록에서 맨 위로 튀어오른다 — 사용자가 시키지 않은 변화다.
  ///
  /// [moved] 는 `applyDateDrop` 이 만든 값이어야 한다 (날짜 외 필드는 원본과 동일).
  /// 저장된 값과 내용이 같으면 아무것도 쓰지 않는다 — updatedAt 도 보존된다.
  ///
  /// 저장된 sortOrder 를 우선 쓰는 이유: 드래그 중인 화면의 Todo 는 스트림 지연으로
  /// 살짝 옛 값일 수 있는데, 그걸 그대로 되쓰면 다른 화면의 재정렬을 되돌릴 수 있다.
  Future<Todo> setDueAt(Todo moved) async {
    final current = await _repo.getById(moved.id);
    if (current != null && _isUnchanged(current, moved)) return current;
    final synced = moved.copyWith(
      updatedAt: _now(),
      sortOrder: current?.sortOrder ?? moved.sortOrder,
    );
    await _repo.upsert(synced);
    return synced;
  }

  /// 저장 대상이 현재 저장된 값과 **내용상 동일**한지.
  ///
  /// 순서·동기화 메타(sortOrder / updatedAt)는 비교에서 제외한다 — 판정의 목적이
  /// "이 둘을 갱신할지" 이기 때문. 카테고리는 **id 만** 본다 (label/색/아이콘은 조회
  /// 시점의 categories join 으로 복원되는 표시 속성이라 내용 변경이 아니다).
  bool _isUnchanged(Todo current, Todo updated) {
    if (updated.category.id != current.category.id) return false;
    return updated.copyWith(
          sortOrder: current.sortOrder,
          updatedAt: current.updatedAt,
          category: current.category,
        ) ==
        current;
  }

  /// 할 일 이동 — [item] 을 [newParent] 의 하위로, [newParent] 가 null 이면
  /// [targetCategory] 의 최상위(root)로 옮긴다. 자손은 [Todo.parentId] 로 딸려오므로
  /// 서브트리가 통째로 따라간다.
  ///
  /// 지원 경로 (모두 이 한 메서드):
  ///  - 하위 → 다른 항목의 하위, 상위 → 다른 항목의 하위 ([newParent] 지정)
  ///  - 하위 → 상위 ([newParent] = null)
  ///
  /// [all] 은 사이클 판정·자손 수집용 전체 todo (호출자가 `allTodosProvider` 로 전달).
  /// 이동 후 위치는 새 형제들의 **맨 위** (min sortOrder - 1) — 방금 옮긴 항목을 바로
  /// 찾을 수 있게. 사이클이 되거나 위치 변화가 없으면 아무것도 쓰지 않고 false.
  Future<bool> moveTo(
    Todo item, {
    required Todo? newParent,
    required Category targetCategory,
    required List<Todo> all,
  }) async {
    final newParentId = newParent?.id;
    // 자식은 부모 카테고리를 상속 — 부모 밑으로 가면 부모의 카테고리가 곧 목적지다.
    final category = newParent?.category ?? targetCategory;
    if (!MovePolicy.canMove(item: item, newParentId: newParentId, all: all)) {
      return false;
    }
    if (MovePolicy.isNoop(
      item: item,
      newParentId: newParentId,
      newCategoryId: category.id,
    )) {
      return false;
    }

    final minSibling = await _repo.minSiblingSortOrder(
      categoryId: category.id,
      parentId: newParentId,
    );
    final now = _now();
    final moved = item.copyWith(
      parentId: newParentId,
      category: category,
      sortOrder: (minSibling ?? 0) - 1,
      updatedAt: now,
    );
    await _repo.upsert(moved);
    await _syncSubtreeCategory(moved, now, all: all);
    return true;
  }

  /// [root] 의 자손 category 를 root 와 일치시킨다. 이미 같은 자손은 건너뛰어
  /// 불필요한 upsert(= outbox row)를 만들지 않는다.
  Future<void> _syncSubtreeCategory(
    Todo root,
    DateTime now, {
    List<Todo>? all,
  }) async {
    final snapshot = all ?? await _repo.watchAll().first;
    for (final d in MovePolicy.descendants(root.id, snapshot)) {
      if (d.category.id == root.category.id) continue;
      await _repo.upsert(d.copyWith(category: root.category, updatedAt: now));
    }
  }

  /// 오늘 화면의 **섹션 간 드래그** — [item] 을 [target] 카테고리의
  /// [targetSiblings] 중 [insertIndex] 자리로 옮긴다.
  ///
  /// [reorderSiblings] 와 [moveTo] 의 중간 경로다. 순서만 바꾸는 것도 아니고
  /// 부모를 고르는 것도 아니라, "다른 카테고리의 이 자리" 를 한 번에 처리한다:
  ///
  ///  - **부모에서 분리** — 카테고리가 바뀌면 부모에서 떼어 root 로 올린다. 이 앱은
  ///    자식이 부모 카테고리를 상속하는 구조라, 안 떼면 다른 카테고리 부모 밑에
  ///    남아 화면상 그 자리에 그대로 보인다 (편집 시트의 카테고리 변경과 같은 규칙).
  ///  - **자손 동기화** — 서브트리 category 를 함께 맞춘다. 안 맞추면 자손이 옛
  ///    카테고리 화면·집계에 남아 "절반만 옮겨간" 상태가 된다.
  ///  - **자리 배치** — 대상 형제들에 삽입한 뒤 연속 sortOrder 를 재부여한다.
  ///
  /// 같은 카테고리로의 호출은 아무것도 하지 않는다(그건 [reorderSiblings] 몫).
  Future<bool> moveToCategoryAt(
    Todo item, {
    required Category target,
    required List<Todo> targetSiblings,
    required int insertIndex,
    List<Todo>? all,
  }) async {
    if (item.category.id == target.id) return false;

    final moved = item.copyWith(parentId: null, category: target);
    final placed = [...targetSiblings.where((t) => t.id != item.id)];
    var at = insertIndex;
    if (at < 0) at = 0;
    if (at > placed.length) at = placed.length;
    placed.insert(at, moved);

    // 기준 min — 대상 집합의 최소 sortOrder (섹션의 맨 위 위치 유지).
    var base = 0;
    if (targetSiblings.isNotEmpty) {
      base = targetSiblings.first.sortOrder;
      for (final s in targetSiblings) {
        if (s.sortOrder < base) base = s.sortOrder;
      }
    }

    final now = _now();
    for (var i = 0; i < placed.length; i++) {
      final t = placed[i];
      final desired = base + i;
      // 옮겨온 항목은 category/parentId 도 바뀌므로 sortOrder 동률이어도 저장한다.
      if (t.id != moved.id && t.sortOrder == desired) continue;
      await _repo.upsert(t.copyWith(sortOrder: desired, updatedAt: now));
    }
    await _syncSubtreeCategory(moved.copyWith(category: target), now, all: all);
    return true;
  }

  /// Task B — 같은 부모의 형제들 사이 순서 재정렬 (within-sibling).
  ///
  /// [siblings] 는 현재 화면 표시 순서(작은 sortOrder = 위). [oldIndex] 의 항목을
  /// [newIndex] 위치로 옮긴 새 시각 순서를 만든 뒤, 그 집합 전체에 **연속 오름차순**
  /// sortOrder 를 재부여한다. 기준값은 집합의 기존 min (없으면 0) — 맨 위 위치가 유지된다.
  /// 변경된 항목만 repo.upsert (outbox 동기화). updatedAt 도 갱신.
  ///
  /// note/task 혼재 시에도 형제 집합 내에서만 이동하므로 타입 제약 없음.
  Future<void> reorderSiblings(
    List<Todo> siblings,
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

    final reordered = List<Todo>.of(siblings);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(target, moved);

    // 기준 min — 기존 집합의 최소 sortOrder (맨 위 위치 유지). 비어있을 수 없음.
    var base = siblings.first.sortOrder;
    for (final s in siblings) {
      if (s.sortOrder < base) base = s.sortOrder;
    }
    final now = _now();
    for (var i = 0; i < reordered.length; i++) {
      final desired = base + i;
      final t = reordered[i];
      if (t.sortOrder != desired) {
        await _repo.upsert(t.copyWith(sortOrder: desired, updatedAt: now));
      }
    }
  }
}

final todoActionsProvider = Provider<TodoActionsController>(
  (ref) => TodoActionsController(
    ref.watch(todoRepositoryProvider),
    ref.watch(nowProvider),
  ),
);
