import '../../domain/policies/stale_backlog_policy.dart';
import '../../domain/todo.dart';
import 'ai_json.dart';

/// 할 일 여러 건 → AI 입력 (정리 제안·물어보기 공용).
///
/// 실제 id 대신 1부터 붙인 짧은 번호 `n` 을 보내고, 화면은 [nToId] 로 응답을 되짚는다.
/// 응답의 `n` 이 [nToId] 에 없으면 버린다(id 화이트리스트).
///
/// 한 항목 모양 — 값이 없으면 키를 뺀다:
/// `{"n":3,"t":"제목","c":"회사 할일","k":"task","s":"undone","d":"2026-10-12",
///   "age":41,"kids":2,"p":1,"desc":"앞 300자"}`
/// - `c` 카테고리 **이름**(id 아님), `k` task|note, `s` undone|doing|done.
/// - `d` 로컬 날짜(종일 `YYYY-MM-DD`, 시각 있으면 `YYYY-MM-DD HH:mm`, 기간 `시작~끝`).
///   UTC ISO 를 보내면 한국 종일 항목이 전날로 보인다.
/// - `age` 만든 지 며칠([includeAge]), `kids` 하위 수([childCounts]), `p` 부모의 n
///   ([includeParent], 부모가 함께 보내질 때만).
/// - `desc` 설명 앞 [descriptionLimit] 자 — [sendDescription] 이 true 일 때만(설정 토글).
///
/// 제외: 반복 마스터(숨김 템플릿), 보관 카테고리([archivedCategoryIds]).
class AiTodoPayload {
  AiTodoPayload._(this.items, this.nToId);

  static const descriptionLimit = 300;
  static const titleLimit = 120;

  /// 보낼 항목들 — 호출자가 키를 더 붙일 수 있게 변경 가능한 Map.
  final List<Map<String, Object>> items;

  /// 번호 → 실제 todo id.
  final Map<int, String> nToId;

  bool get isEmpty => items.isEmpty;

  /// [todos] 순서 그대로 번호를 붙인다(화면 순서). [sortByOrder] 면 순서 키
  /// (sortOrder → createdAt 최신 → id)로 먼저 정렬한다 — updatedAt 은 정렬 키가 아니다
  /// (체크·동기화만으로 자리가 바뀌면 같은 질문에 다른 번호가 붙는다).
  factory AiTodoPayload.build(
    Iterable<Todo> todos, {
    required DateTime now,
    required bool sendDescription,
    Set<String> archivedCategoryIds = const {},
    Map<String, int>? childCounts,
    bool includeAge = false,
    bool includeParent = false,
    bool sortByOrder = false,
  }) {
    final picked = [
      for (final t in todos)
        if (!t.isSeriesMaster && !archivedCategoryIds.contains(t.category.id))
          t,
    ];
    if (sortByOrder) picked.sort(compareByOrder);

    final idToN = <String, int>{
      for (var i = 0; i < picked.length; i++) picked[i].id: i + 1,
    };
    final items = <Map<String, Object>>[];
    for (final t in picked) {
      final n = idToN[t.id]!;
      final date = dateLabel(t);
      final parentN = includeParent && t.parentId != null
          ? idToN[t.parentId]
          : null;
      final desc = sendDescription ? _description(t.description) : null;
      items.add({
        'n': n,
        't': _cut(t.title.trim(), titleLimit),
        'c': t.category.label,
        'k': t.type == TodoType.note ? 'note' : 'task',
        's': switch (t.status) {
          TodoStatus.done => 'done',
          TodoStatus.inProgress => 'doing',
          TodoStatus.undone => 'undone',
        },
        'd': ?date,
        if (includeAge) 'age': StaleBacklogPolicy.ageInDays(t, now),
        if (childCounts != null) 'kids': childCounts[t.id] ?? 0,
        'p': ?parentN,
        'desc': ?desc,
      });
    }
    return AiTodoPayload._(items, {
      for (final e in idToN.entries) e.value: e.key,
    });
  }

  /// 순서 키 — sortOrder 오름차순 → createdAt 최신 먼저 → id. 목록 화면과 같은 규칙.
  static int compareByOrder(Todo a, Todo b) {
    final s = a.sortOrder.compareTo(b.sortOrder);
    if (s != 0) return s;
    final c = b.createdAt.compareTo(a.createdAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  }

  /// AI 로 보내는 날짜 — 없으면 null. 언제나 로컬 날짜로 변환한 뒤 적는다.
  static String? dateLabel(Todo t) {
    final due = t.dueAt;
    if (due == null) return null;
    final start = AiJson.localDate(due, allDay: t.isAllDay);
    final end = t.endAt;
    if (end == null) return start;
    return '$start~${AiJson.localDate(end, allDay: t.isAllDay)}';
  }

  static String? _description(String? raw) {
    final d = raw?.trim();
    if (d == null || d.isEmpty) return null;
    return _cut(d, descriptionLimit);
  }

  static String _cut(String s, int max) =>
      s.length > max ? s.substring(0, max) : s;
}
