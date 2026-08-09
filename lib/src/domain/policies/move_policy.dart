import '../todo.dart';

/// 할 일 계층 이동(parentId 변경) 규칙.
///
/// 지원하는 이동은 두 가지뿐이다:
///  - **다른 항목의 하위로** — 하위 → 다른 하위, 상위 → 다른 항목의 하위 모두 이 경로.
///  - **최상위로** — 부모에서 떼어내 카테고리 직속 root 로.
///
/// 옮겨지는 것은 항목 하나가 아니라 그 **서브트리 전체**다. 자손은 [Todo.parentId] 로
/// 따라오므로 부모를 갈아끼우는 것만으로 위치는 옮겨지지만, `category` 는 row 마다
/// 따로 들고 있어 함께 갱신해야 한다 — 이 앱은 자식이 부모 카테고리를 상속하는 구조
/// (하위 추가 시 부모 category 로 프리셋)라, 안 맞추면 자손이 옛 카테고리 화면·집계에
/// 남아 "이동했는데 절반만 옮겨간" 상태가 된다.
class MovePolicy {
  const MovePolicy._();

  /// [rootId] 의 모든 자손 (재귀, 자기 자신 제외).
  ///
  /// dangling parentId (부모가 [all] 에 없음) 는 자연히 walk 대상에서 빠지고,
  /// 데이터가 이미 사이클을 이루고 있어도 방문 집합으로 무한 루프를 막는다.
  static List<Todo> descendants(String rootId, List<Todo> all) {
    final byParent = <String, List<Todo>>{};
    for (final t in all) {
      final pid = t.parentId;
      if (pid == null) continue;
      (byParent[pid] ??= []).add(t);
    }
    final result = <Todo>[];
    final visited = <String>{rootId};
    void walk(String id) {
      for (final child in byParent[id] ?? const <Todo>[]) {
        if (!visited.add(child.id)) continue;
        result.add(child);
        walk(child.id);
      }
    }

    walk(rootId);
    return result;
  }

  /// [item] 을 [newParentId] 의 하위로 옮길 수 있는가. (null = 최상위로 이동)
  ///
  /// 거부 조건:
  ///  - **자기 자신을 부모로** — 자기 밑으로 들어간 노드는 어느 root 에서도 도달할 수
  ///    없어 화면에서 통째로 사라진다.
  ///  - **자기 자손을 부모로** — 서브트리가 자기 자신을 참조하는 고리가 되어 마찬가지로
  ///    트리에서 떨어져 나간다.
  static bool canMove({
    required Todo item,
    required String? newParentId,
    required List<Todo> all,
  }) {
    if (newParentId == null) return true;
    if (newParentId == item.id) return false;
    return !descendants(item.id, all).any((d) => d.id == newParentId);
  }

  /// [item] 을 [newParent] 밑(또는 최상위)으로 옮길 때 실제로 위치가 바뀌는가.
  ///
  /// 부모도 카테고리도 그대로면 이동이 아니다 — 이때 upsert 를 하면 sortOrder 만
  /// 맨 위로 튀어 "아무것도 안 골랐는데 자리가 바뀌는" 사고가 난다.
  static bool isNoop({
    required Todo item,
    required String? newParentId,
    required String newCategoryId,
  }) => item.parentId == newParentId && item.category.id == newCategoryId;
}
