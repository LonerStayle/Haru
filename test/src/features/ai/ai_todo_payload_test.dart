import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/ai/ai_todo_payload.dart';

void main() {
  final now = DateTime(2026, 10, 10, 9);

  Todo make(
    String id, {
    String? title,
    Category category = Category.work,
    DateTime? created,
    DateTime? updated,
    DateTime? due,
    DateTime? end,
    bool allDay = false,
    String? description,
    String? parentId,
    TodoType type = TodoType.task,
    DateTime? startedAt,
    int sortOrder = 0,
    bool master = false,
  }) => Todo(
    id: id,
    title: title ?? '제목-$id',
    category: category,
    createdAt: created ?? DateTime(2026, 8, 30),
    updatedAt: updated ?? DateTime(2026, 8, 30),
    dueAt: due,
    endAt: end,
    isAllDay: allDay,
    description: description,
    parentId: parentId,
    type: type,
    startedAt: startedAt,
    sortOrder: sortOrder,
    isSeriesMaster: master,
    seriesId: master ? id : null,
  );

  test('n 은 1부터 화면 순서대로, nToId 로 되짚는다', () {
    final p = AiTodoPayload.build(
      [make('x'), make('y')],
      now: now,
      sendDescription: true,
    );
    expect(p.items.map((e) => e['n']), [1, 2]);
    expect(p.nToId, {1: 'x', 2: 'y'});
  });

  test('카테고리는 이름, 종류·상태, 값 없는 키는 뺀다', () {
    final p = AiTodoPayload.build(
      [
        make('a', category: Category.idea, startedAt: DateTime(2026, 10, 1)),
        make('b', type: TodoType.note),
      ],
      now: now,
      sendDescription: true,
    );
    expect(p.items[0], {
      'n': 1,
      't': '제목-a',
      'c': '아이디어',
      'k': 'task',
      's': 'doing',
    });
    expect(p.items[1]['k'], 'note');
    expect(p.items[1]['s'], 'undone');
  });

  test('날짜는 로컬 — UTC 로 저장된 종일 항목도 그날로 (전날 15:00Z 아님)', () {
    final p = AiTodoPayload.build(
      [
        make('a', due: DateTime(2026, 10, 12).toUtc(), allDay: true),
        make('b', due: DateTime(2026, 10, 12, 14, 30).toUtc()),
        make(
          'c',
          due: DateTime(2026, 10, 12),
          end: DateTime(2026, 10, 14),
          allDay: true,
        ),
      ],
      now: now,
      sendDescription: true,
    );
    expect(p.items[0]['d'], '2026-10-12');
    expect(p.items[1]['d'], '2026-10-12 14:30');
    expect(p.items[2]['d'], '2026-10-12~2026-10-14');
  });

  test('설명은 토글이 켜졌을 때만, 앞 300자', () {
    final long = '가' * 500;
    final on = AiTodoPayload.build(
      [make('a', description: long), make('b', description: '   ')],
      now: now,
      sendDescription: true,
    );
    expect(on.items[0]['desc'], '가' * 300);
    expect(on.items[1].containsKey('desc'), isFalse, reason: '빈 설명은 키 없음');

    final off = AiTodoPayload.build(
      [make('a', description: long)],
      now: now,
      sendDescription: false,
    );
    expect(off.items[0].containsKey('desc'), isFalse);
  });

  test('반복 마스터·보관 카테고리는 빼고 번호를 붙인다', () {
    final p = AiTodoPayload.build(
      [
        make('m', master: true),
        make('arch', category: Category.daily),
        make('ok'),
      ],
      now: now,
      sendDescription: true,
      archivedCategoryIds: {Category.daily.id},
    );
    expect(p.nToId, {1: 'ok'});
  });

  test('age·kids·p 는 요청할 때만', () {
    final plain = AiTodoPayload.build(
      [make('a')],
      now: now,
      sendDescription: true,
    );
    expect(plain.items[0].keys, isNot(contains('age')));
    expect(plain.items[0].keys, isNot(contains('kids')));

    final p = AiTodoPayload.build(
      [
        make('a', created: DateTime(2026, 8, 30, 23)),
        make('a1', parentId: 'a'),
        make('z1', parentId: 'gone'),
      ],
      now: now,
      sendDescription: true,
      childCounts: {'a': 1},
      includeAge: true,
      includeParent: true,
    );
    expect(p.items[0]['age'], 41);
    expect(p.items[0]['kids'], 1);
    expect(p.items[1]['kids'], 0);
    expect(p.items[1]['p'], 1);
    expect(p.items[2].containsKey('p'), isFalse, reason: '부모가 안 보내졌으면 생략');
  });

  test('sortByOrder — sortOrder → createdAt 최신 → id, updatedAt 은 무시', () {
    final p = AiTodoPayload.build(
      [
        make('late', sortOrder: 1, updated: DateTime(2026, 10, 9)),
        make('old', created: DateTime(2026, 1, 1)),
        make('new', created: DateTime(2026, 9, 1)),
        make('b', created: DateTime(2026, 9, 1)),
      ],
      now: now,
      sendDescription: true,
      sortByOrder: true,
    );
    expect(p.nToId.values, ['b', 'new', 'old', 'late']);
  });

  test('제목은 120자에서 자른다', () {
    final p = AiTodoPayload.build(
      [make('a', title: '나' * 200)],
      now: now,
      sendDescription: true,
    );
    expect((p.items[0]['t']! as String).length, 120);
  });
}
