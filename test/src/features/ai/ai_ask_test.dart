import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/ai/ask/ai_ask.dart';
import 'package:solo_todo/src/features/ai/ask/ai_ask_payload.dart';

import 'fake_ai_gateway.dart';

/// T5 물어보기 — 직렬화·인용 파서.
void main() {
  final now = DateTime(2026, 10, 10, 14);

  Todo make(
    String id, {
    String? title,
    Category? category,
    String? parentId,
    DateTime? doneAt,
    DateTime? startedAt,
    DateTime? dueAt,
    DateTime? endAt,
    bool isAllDay = false,
    String? description,
    int sortOrder = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
    TodoType type = TodoType.task,
    bool isSeriesMaster = false,
  }) => Todo(
    id: id,
    title: title ?? '제목-$id',
    category: category ?? Category.work,
    parentId: parentId,
    doneAt: doneAt,
    startedAt: startedAt,
    dueAt: dueAt,
    endAt: endAt,
    isAllDay: isAllDay,
    description: description,
    sortOrder: sortOrder,
    createdAt: createdAt ?? DateTime(2026, 9, 1),
    updatedAt: updatedAt ?? DateTime(2026, 9, 1),
    type: type,
    isSeriesMaster: isSeriesMaster,
  );

  ({Map<String, dynamic> json, AiAskPayload payload}) build(
    List<Todo> all, {
    Set<String> archived = const {},
    bool sendDescription = true,
    int limit = aiAskMaxTodos,
  }) {
    final payload = buildAskPayload(
      question: '이번 주 뭐 해?',
      all: all,
      archivedCategoryIds: archived,
      sendDescription: sendDescription,
      now: now,
      limit: limit,
    );
    return (
      json: jsonDecode(payload.input) as Map<String, dynamic>,
      payload: payload,
    );
  }

  List<Map<String, dynamic>> todosOf(Map<String, dynamic> json) =>
      (json['todos'] as List).cast<Map<String, dynamic>>();

  group('buildAskPayload', () {
    test('머리에 오늘·질문, 항목은 n·제목·카테고리 이름·종류·상태', () {
      final r = build([
        make('a', title: '회의 준비'),
        make('b', startedAt: now, category: Category.daily),
        make('c', type: TodoType.note),
      ]);
      expect(r.json['today'], '2026-10-10(토)');
      expect(r.json['question'], '이번 주 뭐 해?');
      final todos = todosOf(r.json);
      final a = todos.firstWhere((t) => t['t'] == '회의 준비');
      expect(a['c'], Category.work.label);
      expect(a['k'], 'task');
      expect(a['s'], 'undone');
      final b = todos.firstWhere((t) => r.payload.nToId[t['n']] == 'b');
      expect(b['s'], 'doing');
      expect(b['c'], Category.daily.label);
      final c = todos.firstWhere((t) => r.payload.nToId[t['n']] == 'c');
      expect(c['k'], 'note');
      expect(r.payload.nToId.keys, [1, 2, 3]);
      expect(r.payload.nToId.values.toSet(), {'a', 'b', 'c'});
    });

    test('날짜는 로컬 표기 — 종일·시각·기간, UTC ISO 아님', () {
      final r = build([
        // 한국 종일 항목을 UTC 로 저장해 둔 모양 — 로컬로 읽어야 같은 날.
        make('allday', dueAt: DateTime(2026, 10, 12).toUtc(), isAllDay: true),
        make('timed', dueAt: DateTime(2026, 10, 13, 9, 5)),
        make(
          'range',
          dueAt: DateTime(2026, 10, 14),
          endAt: DateTime(2026, 10, 16),
          isAllDay: true,
        ),
        make('none'),
      ]);
      String? d(String id) =>
          todosOf(r.json).firstWhere((t) => r.payload.nToId[t['n']] == id)['d']
              as String?;
      expect(d('allday'), '2026-10-12');
      expect(d('timed'), '2026-10-13 09:05');
      expect(d('range'), '2026-10-14~2026-10-16');
      expect(d('none'), isNull);
      expect(r.payload.input, isNot(contains('Z"')));
    });

    test('완료는 최근 14일만 + doneOn, 15일 전 완료는 뺀다', () {
      final r = build([
        make('recent', doneAt: DateTime(2026, 9, 26, 23)),
        make('old', doneAt: DateTime(2026, 9, 25, 23)),
        make('open'),
      ]);
      expect(r.payload.nToId.values.toSet(), {'recent', 'open'});
      final recent = todosOf(
        r.json,
      ).firstWhere((t) => r.payload.nToId[t['n']] == 'recent');
      expect(recent['s'], 'done');
      expect(recent['doneOn'], '2026-09-26');
    });

    test('보관 카테고리·반복 마스터는 빠진다', () {
      final r = build(
        [
          make('kept'),
          make('archived', category: Category.daily),
          make('master', isSeriesMaster: true),
        ],
        archived: {Category.daily.id},
      );
      expect(r.payload.nToId.values, ['kept']);
    });

    test('설명은 토글 켬일 때만, 앞 300자', () {
      final long = '가' * 400;
      final on = build([make('a', description: long)]);
      expect(todosOf(on.json).single['desc'], '가' * 300);

      final off = build([make('a', description: long)], sendDescription: false);
      expect(todosOf(off.json).single.containsKey('desc'), isFalse);

      final blank = build([make('a', description: '   ')]);
      expect(todosOf(blank.json).single.containsKey('desc'), isFalse);
    });

    test('트리 — 부모 바로 뒤에 자식, p 는 부모의 n. 부모가 빠지면 p 없음', () {
      final r = build([
        make('child', parentId: 'root'),
        make('root'),
        make('orphan', parentId: 'gone-parent'),
      ]);
      final ids = [for (final t in todosOf(r.json)) r.payload.nToId[t['n']]];
      expect(ids.indexOf('child'), ids.indexOf('root') + 1);
      final child = todosOf(
        r.json,
      ).firstWhere((t) => r.payload.nToId[t['n']] == 'child');
      final root = todosOf(
        r.json,
      ).firstWhere((t) => r.payload.nToId[t['n']] == 'root');
      expect(child['p'], root['n']);
      final orphan = todosOf(
        r.json,
      ).firstWhere((t) => r.payload.nToId[t['n']] == 'orphan');
      expect(orphan.containsKey('p'), isFalse);
    });

    test('순서는 sortOrder → createdAt 최신 → id, updatedAt 은 무시', () {
      final r = build([
        make('late', sortOrder: 2, updatedAt: DateTime(2026, 10, 10)),
        make('old', sortOrder: 1, createdAt: DateTime(2026, 8, 1)),
        make('new', sortOrder: 1, createdAt: DateTime(2026, 9, 1)),
      ]);
      expect(
        [for (final t in todosOf(r.json)) r.payload.nToId[t['n']]],
        ['new', 'old', 'late'],
      );
    });

    test('상한을 넘으면 오래 전에 끝낸 완료부터 뺀다', () {
      final r = build([
        make('u1'),
        make('u2'),
        make('d-old', doneAt: DateTime(2026, 9, 28)),
        make('d-new', doneAt: DateTime(2026, 10, 9)),
      ], limit: 3);
      expect(r.payload.nToId.values.toSet(), {'u1', 'u2', 'd-new'});

      final tight = build([
        make('u1', sortOrder: 1),
        make('u2', sortOrder: 2),
        make('u3', sortOrder: 3),
        make('d', doneAt: DateTime(2026, 10, 9)),
      ], limit: 2);
      expect(tight.payload.nToId.values.toList(), ['u1', 'u2']);
    });
  });

  group('parseCitations', () {
    const nToId = {1: 'a', 2: 'b', 3: 'c'};

    test('보낸 번호만 칩, 첫 등장 순 번호로 바꾼다', () {
      final r = parseCitations('- 회의 준비 [#2]\n- 장보기 [#1]\n- 다시 회의 [#2]', nToId);
      expect(r.text, '- 회의 준비 [1]\n- 장보기 [2]\n- 다시 회의 [1]');
      expect(r.citations, const [
        AiAskCitation(index: 1, n: 2, todoId: 'b'),
        AiAskCitation(index: 2, n: 1, todoId: 'a'),
      ]);
    });

    test('없는 번호는 본문에서 지운다', () {
      final r = parseCitations('지어낸 일 [#99]. 진짜 일 [#3]', nToId);
      expect(r.text, '지어낸 일. 진짜 일 [1]');
      expect(r.citations.single.todoId, 'c');
    });

    test('스트림 끝의 덜 온 표식은 숨긴다', () {
      expect(parseCitations('회의 준비 [#1', nToId).text, '회의 준비');
      expect(parseCitations('회의 준비 [#', nToId).text, '회의 준비');
      expect(parseCitations('회의 준비 [', nToId).text, '회의 준비');
      expect(parseCitations('회의 준비 [#1', nToId).citations, isEmpty);
      expect(parseCitations('회의 준비 [#1]', nToId).text, '회의 준비 [1]');
    });

    test('칩은 최대 10개, 넘는 인용은 본문에서도 지운다', () {
      final many = {for (var i = 1; i <= 12; i++) i: 'id$i'};
      final raw = [for (var i = 1; i <= 12; i++) '일$i [#$i]'].join(' ');
      final r = parseCitations(raw, many);
      expect(r.citations, hasLength(aiAskMaxCitations));
      expect(r.text, contains('일10 [10]'));
      expect(r.text, isNot(contains('[11]')));
      expect(r.text, endsWith('일11 일12'));
    });
  });

  test('AiAskService.ask — 지시문·입력을 스트림으로 보내고 역매핑표를 준다', () async {
    final ai = FakeAiGateway()..streamChunks.addAll(['답 ', '[#1]']);
    final req = const AiAskService().ask(
      ai,
      question: '뭐 해?',
      all: [make('a')],
      archivedCategoryIds: const {},
      sendDescription: true,
      now: now,
    );
    expect(req.nToId, {1: 'a'});
    expect(await req.stream.join(), '답 [#1]');
    expect(ai.calls.single.instructions, AiAskService.instructions);
    expect(jsonDecode(ai.calls.single.input)['question'], '뭐 해?');
  });
}
