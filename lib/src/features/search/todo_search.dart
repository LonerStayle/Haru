import '../../domain/todo.dart';

/// 검색 결과 한 건 — 매칭된 항목 + 목록에 함께 보여줄 소속 경로와 발췌.
class TodoSearchHit {
  const TodoSearchHit({
    required this.todo,
    required this.breadcrumb,
    this.snippet,
  });

  final Todo todo;

  /// `회사 › 넥서스` 형태의 소속 경로 (카테고리 라벨 + 상위 항목 제목들).
  /// 검색 결과는 화면/트리 경계를 넘어 평탄하게 나열되므로 항목마다 위치를 함께 보여준다.
  final String breadcrumb;

  /// 메모 본문에서 매칭된 부분의 한 줄 발췌. 제목에서만 매칭됐으면 null
  /// (제목은 이미 타일에 그대로 보이므로 발췌가 중복이 된다).
  final String? snippet;
}

/// 제목과 메모 본문(description)을 대소문자 무시 부분일치로 훑어 매칭 항목을 반환한다.
///
/// DAO 에 LIKE 쿼리를 추가하지 않고 [all] 을 in-memory 로 훑는다 — 1인 사용자 규모
/// (~수백 건) 에서 충분히 빠르고, 스키마·동기화 계층을 전혀 건드리지 않는다
/// (`watchToday` / 전체보기 탭 필터와 같은 방식).
///
/// [excludedCategoryIds] 에 속한 항목과 반복 시리즈 마스터는 제외한다.
/// 완료 항목은 **포함** 한다 — 지난 기록을 다시 찾는 것이 검색의 주 용도다.
List<TodoSearchHit> searchTodos({
  required List<Todo> all,
  required String query,
  Set<String> excludedCategoryIds = const <String>{},
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const <TodoSearchHit>[];

  final byId = {for (final t in all) t.id: t};
  final ranked = <_RankedHit>[];

  for (var i = 0; i < all.length; i++) {
    final todo = all[i];
    // 반복 규칙을 담은 숨김 템플릿은 모든 목록에서 빠지는 불변 규칙 — 검색도 동일.
    if (todo.isSeriesMaster) continue;
    if (excludedCategoryIds.contains(todo.category.id)) continue;

    final description = todo.description ?? '';
    final titleIndex = todo.title.toLowerCase().indexOf(q);
    final descriptionIndex = description.toLowerCase().indexOf(q);
    if (titleIndex < 0 && descriptionIndex < 0) continue;

    ranked.add(
      _RankedHit(
        // 제목 앞부분 일치를 가장 위로, 그 다음 제목 중간 일치, 메모만 일치는 아래로.
        rank: titleIndex == 0
            ? 0
            : titleIndex > 0
            ? 1
            : 2,
        order: i,
        hit: TodoSearchHit(
          todo: todo,
          breadcrumb: breadcrumbOf(todo, byId),
          snippet: descriptionIndex < 0 ? null : buildSnippet(description, q),
        ),
      ),
    );
  }

  // List.sort 는 불안정 정렬이라 원본 순서를 tie-breaker 로 명시한다. 이렇게 해야
  // 같은 순위 안에서 목록 원래 순서(미체크 우선 + 사용자 정렬)가 그대로 유지된다.
  ranked.sort((a, b) {
    final byRank = a.rank.compareTo(b.rank);
    return byRank != 0 ? byRank : a.order.compareTo(b.order);
  });
  return [for (final r in ranked) r.hit];
}

/// [todo] 의 소속 경로 문자열 — `카테고리 › 상위 › 그 하위`.
///
/// dangling parentId (동기화 race) 나 사이클을 만나면 거기서 walk 를 멈춘다.
String breadcrumbOf(Todo todo, Map<String, Todo> byId) {
  final titles = <String>[];
  final visited = <String>{todo.id};
  final parentId = todo.parentId;
  var current = parentId == null ? null : byId[parentId];
  while (current != null) {
    if (!visited.add(current.id)) break;
    titles.insert(0, current.title);
    final pid = current.parentId;
    current = pid == null ? null : byId[pid];
  }
  return [todo.category.label, ...titles].join(' › ');
}

/// 메모 본문에서 [query] 주변만 잘라낸 한 줄 발췌.
///
/// 줄바꿈·연속 공백은 한 칸으로 눌러 한 줄에 담고, 잘려나간 쪽에 줄임표를 붙인다.
/// [context] 는 매칭 앞뒤로 남길 글자 수.
String buildSnippet(String text, String query, {int context = 24}) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final index = flat.toLowerCase().indexOf(query.toLowerCase());
  if (index < 0) {
    // 호출측 실수 방지용 안전망 — 매칭이 없으면 앞부분만 잘라 돌려준다.
    final limit = context * 2;
    return flat.length <= limit ? flat : '${flat.substring(0, limit)}…';
  }

  final start = index - context < 0 ? 0 : index - context;
  final rawEnd = index + query.length + context;
  final end = rawEnd > flat.length ? flat.length : rawEnd;

  final buffer = StringBuffer();
  if (start > 0) buffer.write('…');
  buffer.write(flat.substring(start, end));
  if (end < flat.length) buffer.write('…');
  return buffer.toString();
}

class _RankedHit {
  const _RankedHit({
    required this.rank,
    required this.order,
    required this.hit,
  });

  final int rank;
  final int order;
  final TodoSearchHit hit;
}
