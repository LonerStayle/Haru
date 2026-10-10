import 'dart:convert';

import '../../../domain/todo.dart';
import '../ai_json.dart';

/// T5 물어보기 — 할 일 목록을 AI 입력 한 덩어리로.
///
/// 실제 id 대신 1부터 붙인 짧은 번호 `n` 을 보내고, 답의 `[#n]` 을 [nToId] 로 되돌린다.
/// (T3·T4 공용 직렬화가 생기면 그쪽으로 합칠 수 있게 형식은 계획서 §2-4 그대로.)
class AiAskPayload {
  const AiAskPayload({required this.input, required this.nToId});

  /// 게이트웨이에 넘길 JSON 문자열.
  final String input;

  /// 보낸 번호 → 할 일 id. 답의 인용을 검증·역매핑하는 화이트리스트.
  final Map<int, String> nToId;

  int get count => nToId.length;
}

/// 완료 항목은 최근 이 기간(오늘 포함 앞쪽 14일)에 끝낸 것만 보낸다.
const int aiAskDoneWindowDays = 14;

/// 한 번에 보내는 상한 — 넘으면 오래된 완료부터 뺀다.
const int aiAskMaxTodos = 600;

/// 설명은 앞 300자만.
const int aiAskDescriptionMax = 300;

/// [all] 에서 물어보기 대상만 골라 직렬화한다.
///
/// - 대상: 미완료 전부(메모 포함) + 최근 [aiAskDoneWindowDays]일 안에 완료한 것.
/// - 제외: 반복 마스터(숨김 템플릿), 보관된 카테고리([archivedCategoryIds]).
/// - [sendDescription] 이 꺼져 있으면 `desc` 키를 아예 넣지 않는다.
/// - 순서: 트리(부모 바로 뒤에 자식). 형제 사이는 sortOrder → createdAt 최신 → id.
///   **updatedAt 은 쓰지 않는다** — 체크·동기화만으로 순서가 흔들리면 안 된다.
/// - 날짜는 로컬 표기(`YYYY-MM-DD` / `YYYY-MM-DD HH:mm`). UTC ISO 금지.
AiAskPayload buildAskPayload({
  required String question,
  required List<Todo> all,
  required Set<String> archivedCategoryIds,
  required bool sendDescription,
  required DateTime now,
  int limit = aiAskMaxTodos,
}) {
  final local = now.toLocal();
  final cutoff = DateTime(
    local.year,
    local.month,
    local.day - aiAskDoneWindowDays,
  );

  final undone = <Todo>[];
  final done = <Todo>[];
  for (final t in all) {
    if (t.isSeriesMaster) continue;
    if (archivedCategoryIds.contains(t.category.id)) continue;
    if (t.isDone) {
      if (!t.doneAt!.toLocal().isBefore(cutoff)) done.add(t);
    } else {
      undone.add(t);
    }
  }

  // 상한 — 완료부터(오래 전에 끝낸 것부터) 뺀다. 그래도 넘치면 미완료를 화면 순서 뒤에서.
  if (undone.length + done.length > limit) {
    done.sort((a, b) => b.doneAt!.compareTo(a.doneAt!));
    final room = (limit - undone.length).clamp(0, done.length);
    done.removeRange(room, done.length);
    if (undone.length > limit) {
      final kept = _treeOrder(undone).take(limit).toSet();
      undone.retainWhere(kept.contains);
    }
  }

  final ordered = _treeOrder([...undone, ...done]);
  final nOf = <String, int>{};
  final nToId = <int, String>{};
  for (var i = 0; i < ordered.length; i++) {
    nOf[ordered[i].id] = i + 1;
    nToId[i + 1] = ordered[i].id;
  }

  final todos = [
    for (final t in ordered)
      {
        'n': nOf[t.id],
        't': t.title,
        'c': t.category.label,
        'k': t.type == TodoType.note ? 'note' : 'task',
        's': switch (t.status) {
          TodoStatus.undone => 'undone',
          TodoStatus.inProgress => 'doing',
          TodoStatus.done => 'done',
        },
        'd': ?_localDue(t),
        if (t.isDone) 'doneOn': AiJson.localDate(t.doneAt!, allDay: true),
        'p': ?nOf[t.parentId],
        if (sendDescription) 'desc': ?_desc(t.description),
      },
  ];

  return AiAskPayload(
    input: jsonEncode({
      'today': AiJson.today(local),
      'question': question,
      'todos': todos,
    }),
    nToId: nToId,
  );
}

/// 일정의 로컬 표기 — 종일 `YYYY-MM-DD`, 시각 `YYYY-MM-DD HH:mm`, 기간 `시작~끝`.
String? _localDue(Todo t) {
  final due = t.dueAt;
  if (due == null) return null;
  final start = AiJson.localDate(due, allDay: t.isAllDay);
  final end = t.endAt;
  return end == null
      ? start
      : '$start~${AiJson.localDate(end, allDay: t.isAllDay)}';
}

String? _desc(String? raw) {
  final d = raw?.trim();
  if (d == null || d.isEmpty) return null;
  return d.length > aiAskDescriptionMax
      ? d.substring(0, aiAskDescriptionMax)
      : d;
}

/// 형제 정렬 — sortOrder asc → createdAt desc → id asc (목록 화면과 같은 키).
int _sibling(Todo a, Todo b) {
  final bySort = a.sortOrder.compareTo(b.sortOrder);
  if (bySort != 0) return bySort;
  final byCreated = b.createdAt.compareTo(a.createdAt);
  if (byCreated != 0) return byCreated;
  return a.id.compareTo(b.id);
}

/// 부모 바로 뒤에 자식이 오는 깊이 우선 순서. 부모가 빠진 항목은 최상위로 본다.
/// 최상위는 카테고리 순서(sortOrder → id)로 모은다.
List<Todo> _treeOrder(List<Todo> items) {
  final ids = {for (final t in items) t.id};
  final roots = <Todo>[];
  final kids = <String, List<Todo>>{};
  for (final t in items) {
    final p = t.parentId;
    if (p != null && ids.contains(p)) {
      (kids[p] ??= []).add(t);
    } else {
      roots.add(t);
    }
  }
  roots.sort((a, b) {
    final byCat = a.category.sortOrder.compareTo(b.category.sortOrder);
    if (byCat != 0) return byCat;
    final byCatId = a.category.id.compareTo(b.category.id);
    return byCatId != 0 ? byCatId : _sibling(a, b);
  });
  final out = <Todo>[];
  final seen = <String>{};
  void walk(Todo t) {
    if (!seen.add(t.id)) return; // 순환 데이터 방어
    out.add(t);
    final children = kids[t.id];
    if (children == null) return;
    children.sort(_sibling);
    children.forEach(walk);
  }

  roots.forEach(walk);
  // 순환으로 어느 뿌리에도 닿지 않은 항목도 빠뜨리지 않는다.
  for (final t in items) {
    if (!seen.contains(t.id)) walk(t);
  }
  return out;
}
