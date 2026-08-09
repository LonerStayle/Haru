import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/todo_actions/todo_actions_controller.dart';

/// 할 일 이동 — 하위→다른 하위 / 상위→하위 / 하위→상위 3 경로와, 이동 시 서브트리가
/// 통째로 따라오는지(자손 category 동기화)를 데이터 계층에서 검증한다.
void main() {
  late AppDatabase db;
  late LocalTodoRepository repo;
  late TodoActionsController controller;

  final created = DateTime.utc(2026, 8, 9, 9, 0);
  final movedAt = DateTime.utc(2026, 8, 9, 15, 30);

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
    controller = TodoActionsController(repo, () => movedAt);
  });

  tearDown(() async => db.close());

  Todo node(
    String id, {
    String? parentId,
    Category category = Category.work,
    int sortOrder = 0,
  }) => Todo(
    id: id,
    title: id,
    category: category,
    dueAt: null,
    doneAt: null,
    createdAt: created,
    updatedAt: created,
    calendarEventId: null,
    parentId: parentId,
    sortOrder: sortOrder,
  );

  Future<List<Todo>> seedTree() async {
    // 회사: a > b > c,  d (독립 root)
    final nodes = [
      node('a', sortOrder: 0),
      node('b', parentId: 'a', sortOrder: 0),
      node('c', parentId: 'b', sortOrder: 0),
      node('d', sortOrder: 1),
    ];
    for (final t in nodes) {
      await repo.upsert(t);
    }
    return nodes;
  }

  test('하위 → 다른 항목의 하위 (b 를 d 밑으로, 자손 c 도 딸려온다)', () async {
    final all = await seedTree();
    final b = all.firstWhere((t) => t.id == 'b');
    final d = all.firstWhere((t) => t.id == 'd');

    final ok = await controller.moveTo(
      b,
      newParent: d,
      targetCategory: Category.work,
      all: all,
    );

    expect(ok, isTrue);
    expect((await repo.getById('b'))!.parentId, 'd');
    expect(
      (await repo.getById('c'))!.parentId,
      'b',
      reason: '자손은 parentId 로 따라오므로 그대로',
    );
    expect(
      (await db.todosDao.watchChildrenOf('a').first),
      isEmpty,
      reason: '옛 부모 a 밑은 비어야',
    );
    expect((await db.todosDao.watchChildrenOf('d').first).map((t) => t.id), [
      'b',
    ]);
  });

  test('상위 → 다른 항목의 하위 (root d 를 c 밑으로)', () async {
    final all = await seedTree();
    final c = all.firstWhere((t) => t.id == 'c');
    final d = all.firstWhere((t) => t.id == 'd');

    final ok = await controller.moveTo(
      d,
      newParent: c,
      targetCategory: Category.work,
      all: all,
    );

    expect(ok, isTrue);
    expect((await repo.getById('d'))!.parentId, 'c');
    expect(
      (await db.todosDao.watchRootsOfCategory(Category.work).first).map(
        (t) => t.id,
      ),
      ['a'],
      reason: 'd 가 root 목록에서 빠져야',
    );
  });

  test('하위 → 상위 (c 를 최상위로, 지정 카테고리 root 가 된다)', () async {
    final all = await seedTree();
    final c = all.firstWhere((t) => t.id == 'c');

    final ok = await controller.moveTo(
      c,
      newParent: null,
      targetCategory: Category.daily,
      all: all,
    );

    expect(ok, isTrue);
    final moved = await repo.getById('c');
    expect(moved!.parentId, isNull);
    expect(moved.category.id, 'daily');
    expect(
      (await db.todosDao.watchRootsOfCategory(Category.daily).first).map(
        (t) => t.id,
      ),
      ['c'],
    );
  });

  test('다른 카테고리 항목 밑으로 옮기면 서브트리 전체가 그 카테고리로 동기화', () async {
    final all = await seedTree();
    // 개인개발 카테고리의 root 하나 추가.
    final host = node('host', category: Category.personalDev);
    await repo.upsert(host);
    final a = all.firstWhere((t) => t.id == 'a');

    final ok = await controller.moveTo(
      a,
      newParent: host,
      targetCategory: Category.work, // 부모 카테고리가 이긴다.
      all: [...all, host],
    );

    expect(ok, isTrue);
    for (final id in ['a', 'b', 'c']) {
      expect(
        (await repo.getById(id))!.category.id,
        'personal_dev',
        reason: '$id 도 부모 카테고리를 따라가야',
      );
    }
    expect(
      await db.todosDao.watchRootsOfCategory(Category.work).first,
      hasLength(1),
      reason: '회사에는 d 만 남아야',
    );
  });

  test('이동 후 새 형제들의 맨 위에 놓인다 (min sortOrder - 1)', () async {
    final all = await seedTree();
    // d 밑에 형제 둘 (sortOrder 3, 5).
    final s1 = node('s1', parentId: 'd', sortOrder: 3);
    final s2 = node('s2', parentId: 'd', sortOrder: 5);
    await repo.upsert(s1);
    await repo.upsert(s2);
    final b = all.firstWhere((t) => t.id == 'b');

    await controller.moveTo(
      b,
      newParent: all.firstWhere((t) => t.id == 'd'),
      targetCategory: Category.work,
      all: [...all, s1, s2],
    );

    expect((await repo.getById('b'))!.sortOrder, 2, reason: 'min(3) - 1');
    expect((await db.todosDao.watchChildrenOf('d').first).map((t) => t.id), [
      'b',
      's1',
      's2',
    ]);
  });

  test('자기 자손 밑으로는 이동 거부 — 아무것도 쓰지 않는다', () async {
    final all = await seedTree();
    final a = all.firstWhere((t) => t.id == 'a');
    final c = all.firstWhere((t) => t.id == 'c');

    final ok = await controller.moveTo(
      a,
      newParent: c,
      targetCategory: Category.work,
      all: all,
    );

    expect(ok, isFalse);
    expect((await repo.getById('a'))!.parentId, isNull);
    expect(
      (await repo.getById('a'))!.updatedAt,
      created,
      reason: '거부 시 row 를 건드리지 않아야',
    );
  });

  test('같은 자리로 이동하면 no-op — sortOrder 가 튀지 않는다', () async {
    final all = await seedTree();
    final b = all.firstWhere((t) => t.id == 'b');

    final ok = await controller.moveTo(
      b,
      newParent: all.firstWhere((t) => t.id == 'a'),
      targetCategory: Category.work,
      all: all,
    );

    expect(ok, isFalse);
    expect((await repo.getById('b'))!.sortOrder, 0, reason: '자리 유지');
    expect((await repo.getById('b'))!.updatedAt, created);
  });

  test('완료/진행중 상태는 이동해도 보존', () async {
    final all = await seedTree();
    final doneAt = DateTime.utc(2026, 8, 9, 10);
    final c = all
        .firstWhere((t) => t.id == 'c')
        .copyWith(doneAt: doneAt, description: '메모');
    await repo.upsert(c);

    await controller.moveTo(
      c,
      newParent: null,
      targetCategory: Category.work,
      all: all,
    );

    final moved = await repo.getById('c');
    expect(moved!.doneAt, doneAt);
    expect(moved.description, '메모');
  });

  test('편집 시트에서 카테고리만 바꿔도 자손이 함께 옮겨간다 (기존 버그 회귀)', () async {
    final all = await seedTree();
    final a = all.firstWhere((t) => t.id == 'a');

    // 시트 편집 = category 만 교체한 Todo 를 update 로 전달.
    await controller.update(a.copyWith(category: Category.daily));

    for (final id in ['a', 'b', 'c']) {
      expect(
        (await repo.getById(id))!.category.id,
        'daily',
        reason: '$id 이 옛 카테고리에 남으면 안 됨',
      );
    }
  });
}
