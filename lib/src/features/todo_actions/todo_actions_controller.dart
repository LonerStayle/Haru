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
  Future<Todo> update(Todo updated) async {
    final before = await _repo.getById(updated.id);
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
    if (before != null && before.category.id != synced.category.id) {
      await _syncSubtreeCategory(synced, now);
    }
    return synced;
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
