import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/todo_repository.dart';
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

  /// v1.2 — 기존 todo 의 필드 수정 (title / description / category / dueAt / type).
  /// updatedAt 은 자동으로 [_now] 의 호출 시점 값으로 갱신 — LWW 동기화 호환.
  ///
  /// Task B — 대표님 요구: 시트 편집 시 그 항목을 **맨 위로** (수정 기준 최신 위로).
  /// 같은 형제(현재 category+parentId) min sortOrder - 1 로 bump. 형제가 자기 자신뿐이면
  /// 그대로 유지된다 (min == 자기 sortOrder → min-1 로 살짝 위, 무해).
  Future<Todo> update(Todo updated) async {
    final minSibling = await _repo.minSiblingSortOrder(
      categoryId: updated.category.id,
      parentId: updated.parentId,
    );
    final bumped = (minSibling ?? updated.sortOrder) - 1;
    final synced = updated.copyWith(updatedAt: _now(), sortOrder: bumped);
    await _repo.upsert(synced);
    return synced;
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
