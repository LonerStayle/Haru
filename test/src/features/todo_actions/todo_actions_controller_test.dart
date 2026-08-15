import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/todo_actions/todo_actions_controller.dart';

void main() {
  late AppDatabase db;
  late LocalTodoRepository repo;
  late TodoActionsController controller;

  final created = DateTime.utc(2026, 5, 27, 9, 0);

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
    controller = TodoActionsController(repo, () => created);
  });

  tearDown(() async => db.close());

  Todo seed({DateTime? doneAt}) {
    return Todo(
      id: 'a',
      title: '회의',
      category: Category.work,
      dueAt: null,
      doneAt: doneAt,
      createdAt: created,
      updatedAt: created,
      calendarEventId: null,
    );
  }

  test('toggle: 미체크 → 체크 (doneAt 가 now 로 채워짐, updatedAt 갱신)', () async {
    final original = seed();
    await repo.upsert(original);

    final later = DateTime.utc(2026, 5, 27, 10);
    controller = TodoActionsController(repo, () => later);

    final updated = await controller.toggle(original);

    expect(updated.isDone, isTrue);
    expect(updated.doneAt, later);
    expect(updated.updatedAt, later);

    final fromDb = await repo.getById('a');
    expect(fromDb, updated);
  });

  test('toggle: 체크 → 미체크 (doneAt null, updatedAt 갱신)', () async {
    final original = seed(doneAt: DateTime.utc(2026, 5, 27, 10));
    await repo.upsert(original);

    final later = DateTime.utc(2026, 5, 27, 11);
    controller = TodoActionsController(repo, () => later);

    final updated = await controller.toggle(original);

    expect(updated.isDone, isFalse);
    expect(updated.doneAt, isNull);
    expect(updated.updatedAt, later);
  });

  test('delete: row 가 사라짐', () async {
    final original = seed();
    await repo.upsert(original);

    await controller.delete(original);

    expect(await repo.getById('a'), isNull);
  });

  test('restore: delete 후 복원 시 동일 id + updatedAt 보존', () async {
    final original = seed(doneAt: DateTime.utc(2026, 5, 27, 10));
    await repo.upsert(original);

    await controller.delete(original);
    expect(await repo.getById('a'), isNull);

    await controller.restore(original);
    expect(await repo.getById('a'), original);
  });

  group('Task B — sortOrder 불변식 / bump / reorder', () {
    Todo make(String id, {int sortOrder = 0, DateTime? doneAt}) => Todo(
      id: id,
      title: id,
      category: Category.work,
      dueAt: null,
      doneAt: doneAt,
      createdAt: created,
      updatedAt: created,
      calendarEventId: null,
      sortOrder: sortOrder,
    );

    test('toggle 은 sortOrder 를 바꾸지 않는다 (체크해도 자리 유지)', () async {
      final t = make('a', sortOrder: 5);
      await repo.upsert(t);

      final later = DateTime.utc(2026, 5, 27, 12);
      controller = TodoActionsController(repo, () => later);
      final toggled = await controller.toggle(t);

      expect(toggled.sortOrder, 5, reason: '체크 시 sortOrder 불변');
      expect((await repo.getById('a'))!.sortOrder, 5);
    });

    test('update (시트 편집) 는 sortOrder 를 min(형제)-1 로 bump (맨 위)', () async {
      await repo.upsert(make('a', sortOrder: 0));
      await repo.upsert(make('b', sortOrder: 1));
      await repo.upsert(make('c', sortOrder: 2));

      // c 를 편집 → 맨 위로 (min 0 - 1 = -1).
      final edited = await controller.update(
        make('c', sortOrder: 2).copyWith(title: 'c-edited'),
      );
      expect(edited.sortOrder, -1);

      final list = await repo.watchByCategory(Category.work).first;
      expect(list.map((t) => t.id).first, 'c', reason: '편집한 항목이 맨 위로');
    });

    test('진행중 토글 — sortOrder 동률 그룹 안에서도 순서가 안 바뀐다', () async {
      // 마이그레이션 이전 데이터는 sortOrder 가 전부 0 이라 동률 그룹이 크다.
      final a = make('a');
      final b = make('b');
      final c = make('c');
      for (final t in [a, b, c]) {
        await repo.upsert(t);
      }
      final before = (await repo.watchByCategory(Category.work).first)
          .map((t) => t.id)
          .toList();

      final later = DateTime.utc(2026, 5, 27, 12);
      controller = TodoActionsController(repo, () => later);
      await controller.toggleInProgress(c);

      final after = (await repo.watchByCategory(Category.work).first)
          .map((t) => t.id)
          .toList();
      expect(after, before, reason: '세모 토글은 updatedAt 만 건드림 → 자리 유지');
    });

    test('update — 바뀐 게 없으면 자리 유지 (열어보고 저장만 눌러도 안 움직임)', () async {
      await repo.upsert(make('a', sortOrder: 0));
      await repo.upsert(make('b', sortOrder: 1));
      final c = make('c', sortOrder: 2);
      await repo.upsert(c);

      // 편집 시트를 열었다가 아무것도 고치지 않고 저장한 상황.
      final later = DateTime.utc(2026, 5, 27, 12);
      controller = TodoActionsController(repo, () => later);
      final result = await controller.update(c);

      expect(result.sortOrder, 2, reason: '내용 동일 → bump 없음');
      expect(result.updatedAt, created, reason: '내용 동일 → updatedAt 도 보존');

      final list = await repo.watchByCategory(Category.work).first;
      expect(list.map((t) => t.id).toList(), ['a', 'b', 'c']);
    });

    test('update — 카테고리 id 가 같으면 label/색 차이는 변경으로 보지 않는다', () async {
      final t = make('a', sortOrder: 3);
      await repo.upsert(t);

      // 같은 id 인데 표시용 label/색만 다른 Category 객체 (join 복원 편차).
      final restyled = t.copyWith(
        category: Category.work.copyWith(label: '업무', colorValue: 0xFF112233),
      );
      final later = DateTime.utc(2026, 5, 27, 12);
      controller = TodoActionsController(repo, () => later);
      final result = await controller.update(restyled);

      expect(result.sortOrder, 3);
      expect(result.updatedAt, created);
    });

    test('reorderSiblings — 새 순서대로 연속 sortOrder 재부여 (min 기준)', () async {
      // 시각 순서 [a(0), b(1), c(2)] 에서 c 를 맨 앞으로.
      final a = make('a', sortOrder: 0);
      final b = make('b', sortOrder: 1);
      final c = make('c', sortOrder: 2);
      for (final t in [a, b, c]) {
        await repo.upsert(t);
      }

      // c(index 2) → index 0 으로.
      await controller.reorderSiblings([a, b, c], 2, 0);

      final list = await repo.watchByCategory(Category.work).first;
      expect(list.map((t) => t.id).toList(), ['c', 'a', 'b']);
      // base = min(0) → c=0, a=1, b=2.
      expect((await repo.getById('c'))!.sortOrder, 0);
      expect((await repo.getById('a'))!.sortOrder, 1);
      expect((await repo.getById('b'))!.sortOrder, 2);
    });

    test('reorderSiblings — 변화 없는 이동(target==old)은 no-op', () async {
      final a = make('a', sortOrder: 0);
      final b = make('b', sortOrder: 1);
      await repo.upsert(a);
      await repo.upsert(b);

      // ReorderableList 시맨틱: index 0 → newIndex 0 → 보정 후 동일.
      await controller.reorderSiblings([a, b], 0, 0);

      expect((await repo.getById('a'))!.sortOrder, 0);
      expect((await repo.getById('b'))!.sortOrder, 1);
    });
  });

  group('§14-C — 타입 전환 시 자식 보존 (메모↔할일 왕복)', () {
    Todo node(
      String id, {
      String? parentId,
      TodoType type = TodoType.task,
      DateTime? doneAt,
    }) => Todo(
      id: id,
      title: id,
      category: Category.work,
      dueAt: null,
      doneAt: doneAt,
      createdAt: created,
      updatedAt: created,
      calendarEventId: null,
      parentId: parentId,
      type: type,
    );

    test('부모 task→note 전환 — 자식 parentId / 서브트리 진척 보존', () async {
      await repo.upsert(node('p'));
      await repo.upsert(node('c1', parentId: 'p', doneAt: created));
      await repo.upsert(node('c2', parentId: 'p'));

      // id 동일하게 type 만 note 로 전환.
      final asNote = (await repo.getById(
        'p',
      ))!.copyWith(type: TodoType.note, doneAt: null);
      await controller.update(asNote);

      // 자식 parentId 는 부모 id 를 그대로 가리킨다(전환은 id 불변).
      expect((await repo.getById('c1'))!.parentId, 'p');
      expect((await repo.getById('c2'))!.parentId, 'p');
      expect((await repo.getById('p'))!.type, TodoType.note);

      // 헤딩이 된 부모의 서브트리 진척 — task 자식 2 중 1 done.
      final all = await repo.watchByCategory(Category.work).first;
      final progress = computeSubtreeProgress((await repo.getById('p'))!, all);
      expect(progress, const SubtreeProgress(doneCount: 1, taskCount: 2));
    });

    test('부모 note→task 전환 — 자식 보존 (왕복 정합)', () async {
      await repo.upsert(node('p', type: TodoType.note));
      await repo.upsert(node('c1', parentId: 'p'));

      final asTask = (await repo.getById('p'))!.copyWith(type: TodoType.task);
      await controller.update(asTask);

      expect((await repo.getById('c1'))!.parentId, 'p');
      expect((await repo.getById('p'))!.type, TodoType.task);
    });
  });

  group('setDueAt — 캘린더 드래그 전용 (v1.6)', () {
    Todo dated({
      String id = 'a',
      DateTime? dueAt,
      DateTime? endAt,
      int sortOrder = 0,
      bool isAllDay = false,
    }) => Todo(
      id: id,
      title: '회의',
      category: Category.work,
      dueAt: dueAt ?? DateTime(2026, 8, 15, 14, 30),
      endAt: endAt,
      isAllDay: isAllDay,
      sortOrder: sortOrder,
      createdAt: created,
      updatedAt: created,
    );

    test('날짜만 바꾸고 sortOrder 는 그대로 — update 처럼 맨 위로 튀지 않는다', () async {
      final original = dated(sortOrder: 7);
      await repo.upsert(original);
      // 같은 형제에 더 위(작은 sortOrder)가 있어도 bump 되면 안 된다.
      await repo.upsert(dated(id: 'top', sortOrder: 1));

      final later = DateTime.utc(2026, 8, 20, 10);
      controller = TodoActionsController(repo, () => later);

      final moved = await controller.setDueAt(
        original.copyWith(dueAt: DateTime(2026, 8, 20, 14, 30)),
      );

      expect(moved.sortOrder, 7);
      expect(moved.dueAt, DateTime(2026, 8, 20, 14, 30));
      expect(moved.updatedAt, later);
      expect((await repo.getById('a'))!.sortOrder, 7);
    });

    test('같은 조건에서 update 는 여전히 맨 위로 bump 한다 (기존 동작 회귀 없음)', () async {
      final original = dated(sortOrder: 7);
      await repo.upsert(original);
      await repo.upsert(dated(id: 'top', sortOrder: 1));

      final bumped = await controller.update(
        original.copyWith(dueAt: DateTime(2026, 8, 20, 14, 30)),
      );

      expect(bumped.sortOrder, 0); // min(1) - 1
    });

    test('내용이 그대로면 아무것도 쓰지 않는다 (updatedAt 보존)', () async {
      final original = dated();
      await repo.upsert(original);

      final later = DateTime.utc(2026, 8, 20, 10);
      controller = TodoActionsController(repo, () => later);

      final same = await controller.setDueAt(original);
      expect(same.updatedAt, created);
      expect((await repo.getById('a'))!.updatedAt, created);
    });

    test('저장된 sortOrder 를 우선한다 — 스트림 지연으로 옛 값을 들고 와도 되돌리지 않는다', () async {
      await repo.upsert(dated(sortOrder: 3));
      // 화면이 들고 있던 옛 스냅샷(sortOrder 99)으로 날짜만 옮긴다.
      final stale = dated(sortOrder: 99, dueAt: DateTime(2026, 8, 22, 14, 30));

      final moved = await controller.setDueAt(stale);

      expect(moved.sortOrder, 3);
      expect((await repo.getById('a'))!.sortOrder, 3);
    });

    test('기간 항목의 endAt 도 함께 저장된다', () async {
      final original = dated(
        dueAt: DateTime(2026, 8, 15),
        endAt: DateTime(2026, 8, 18),
        isAllDay: true,
      );
      await repo.upsert(original);

      await controller.setDueAt(
        original.copyWith(
          dueAt: DateTime(2026, 8, 20),
          endAt: DateTime(2026, 8, 23),
        ),
      );

      final fromDb = (await repo.getById('a'))!;
      expect(fromDb.dueAt, DateTime(2026, 8, 20));
      expect(fromDb.endAt, DateTime(2026, 8, 23));
      expect(fromDb.dateMode, TodoDateMode.range);
    });

    test('DB 에 없던 항목(방금 실체화된 반복 회차)도 그대로 저장된다', () async {
      final fresh = dated(id: 'series#20260820', sortOrder: 5);
      final saved = await controller.setDueAt(fresh);
      expect(saved.sortOrder, 5);
      expect(await repo.getById('series#20260820'), isNotNull);
    });
  });
}
