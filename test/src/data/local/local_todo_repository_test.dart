import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';

void main() {
  late AppDatabase db;
  late LocalTodoRepository repo;

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
  });

  tearDown(() async {
    await db.close();
  });

  Todo make({
    required String id,
    String title = 'x',
    Category category = Category.daily,
    DateTime? dueAt,
    DateTime? doneAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? parentId,
    TodoType type = TodoType.task,
    int sortOrder = 0,
  }) {
    final c = createdAt ?? DateTime.utc(2026, 5, 27, 9);
    return Todo(
      id: id,
      title: title,
      category: category,
      dueAt: dueAt,
      doneAt: doneAt,
      createdAt: c,
      updatedAt: updatedAt ?? c,
      calendarEventId: null,
      parentId: parentId,
      type: type,
      sortOrder: sortOrder,
    );
  }

  group('LocalTodoRepository — CRUD', () {
    test('upsert + getById round-trip', () async {
      final t = make(id: 'a', title: '회사 보고', category: Category.work);
      await repo.upsert(t);
      final got = await repo.getById('a');
      expect(got, t);
    });

    test('getById 없으면 null', () async {
      expect(await repo.getById('ghost'), isNull);
    });

    test(
      'fast-tasks — endAt/isAllDay/timeAnchor Drift round-trip (기간+하루종일)',
      () async {
        final t = Todo(
          id: 'range',
          title: '여행',
          category: Category.daily,
          dueAt: DateTime.utc(2026, 5, 27),
          doneAt: null,
          createdAt: DateTime.utc(2026, 5, 27, 9),
          updatedAt: DateTime.utc(2026, 5, 27, 9),
          calendarEventId: null,
          endAt: DateTime.utc(2026, 5, 30),
          isAllDay: true,
        );
        await repo.upsert(t);
        final got = await repo.getById('range');
        expect(got!.endAt, DateTime.utc(2026, 5, 30));
        expect(got.isAllDay, isTrue);
        expect(got.timeAnchor, 'start');
        expect(got.dateMode, TodoDateMode.range);
      },
    );

    test('fast-tasks — 마감시간 모드 round-trip (timeAnchor=end)', () async {
      final t = Todo(
        id: 'end',
        title: '제출',
        category: Category.work,
        dueAt: DateTime.utc(2026, 5, 27, 18),
        doneAt: null,
        createdAt: DateTime.utc(2026, 5, 27, 9),
        updatedAt: DateTime.utc(2026, 5, 27, 9),
        calendarEventId: null,
        timeAnchor: 'end',
      );
      await repo.upsert(t);
      final got = await repo.getById('end');
      expect(got!.timeAnchor, 'end');
      expect(got.endAt, isNull);
      expect(got.dateMode, TodoDateMode.endTime);
    });

    test('upsert 두 번째 호출 = update', () async {
      await repo.upsert(make(id: 'a', title: 'orig'));
      final updatedAt = DateTime.utc(2026, 5, 27, 11);
      await repo.upsert(make(id: 'a', title: 'new', updatedAt: updatedAt));

      final got = await repo.getById('a');
      expect(got, isNotNull);
      expect(got!.title, 'new');
      expect(got.updatedAt, updatedAt);
    });

    test('deleteById 가 row 를 지운다', () async {
      await repo.upsert(make(id: 'a'));
      await repo.deleteById('a');
      expect(await repo.getById('a'), isNull);
    });

    test('deleteById 미존재 키는 no-op', () async {
      await repo.deleteById('ghost'); // throws X
      expect(await repo.getById('ghost'), isNull);
    });

    test('todo.category 복원 시 groupId 가 보존된다 (그룹 라벨 표시 의존)', () async {
      // 그룹에 속한 카테고리를 seed 한 뒤, 그 카테고리의 todo 를 읽어 groupId 가
      // 살아 있는지 확인. (join 복원에서 groupId 누락 시 '오늘'/타임라인 그룹 라벨이 사라짐)
      const grouped = Category(
        id: 'cat-x',
        label: '코기토',
        iconCodePoint: 0xe865,
        colorValue: 0xFF2A66FF,
        isBuiltin: false,
        groupId: 'grp-1',
      );
      await db.categoriesDao.upsert(grouped);
      await repo.upsert(make(id: 't1', category: grouped));

      final got = await repo.getById('t1');
      expect(got!.category.groupId, 'grp-1');
    });
  });

  group('LocalTodoRepository — streams', () {
    test('watchAll: 빈 DB 는 빈 리스트 emit', () async {
      expect(await repo.watchAll().first, isEmpty);
    });

    test('watchAll: 미체크 우선 정렬 — 미체크가 먼저', () async {
      // 체크된 항목
      await repo.upsert(
        make(
          id: 'done',
          doneAt: DateTime.utc(2026, 5, 27, 12),
          createdAt: DateTime.utc(2026, 5, 27, 8),
        ),
      );
      // 미체크 항목
      await repo.upsert(
        make(id: 'undone', createdAt: DateTime.utc(2026, 5, 27, 9)),
      );

      final list = await repo.watchAll().first;
      expect(list.map((t) => t.id).toList(), ['undone', 'done']);
    });

    test(
      'watchAll: 여러 미체크 + 여러 체크 섞여도 미체크 그룹이 항상 먼저 (NULLS FIRST 명시 검증)',
      () async {
        // 의도적으로 체크된 항목을 먼저 insert 해서 default 순서에 의존하지 않게.
        await repo.upsert(
          make(
            id: 'done1',
            doneAt: DateTime.utc(2026, 5, 27, 10),
            createdAt: DateTime.utc(2026, 5, 27, 5),
          ),
        );
        await repo.upsert(
          make(
            id: 'done2',
            doneAt: DateTime.utc(2026, 5, 27, 11),
            createdAt: DateTime.utc(2026, 5, 27, 6),
          ),
        );
        // 미체크 항목들 (doneAt NULL).
        await repo.upsert(
          make(id: 'undone1', createdAt: DateTime.utc(2026, 5, 27, 7)),
        );
        await repo.upsert(
          make(id: 'undone2', createdAt: DateTime.utc(2026, 5, 27, 8)),
        );

        final list = await repo.watchAll().first;
        final ids = list.map((t) => t.id).toList();
        // 미체크 두 개가 모두 앞쪽 두 자리에 있어야 한다 (NULLS FIRST).
        expect(
          {ids[0], ids[1]},
          {'undone1', 'undone2'},
          reason: 'NULLS FIRST 가 동작하지 않으면 done* 가 위로 올 수 있다',
        );
        expect({ids[2], ids[3]}, {'done1', 'done2'});
      },
    );

    test('watchByCategory 가 카테고리별로만 emit', () async {
      await repo.upsert(make(id: 'w', category: Category.work));
      await repo.upsert(make(id: 'd', category: Category.daily));

      expect(
        (await repo.watchByCategory(Category.work).first).map((t) => t.id),
        ['w'],
      );
      expect(
        (await repo.watchByCategory(Category.daily).first).map((t) => t.id),
        ['d'],
      );
      expect(await repo.watchByCategory(Category.idea).first, isEmpty);
    });

    test('watchToday: 어제 미체크 + 오늘 미체크 만 visible, 내일 dueAt 은 hide', () async {
      DateTime now() => DateTime(2026, 5, 27, 10);

      await repo.upsert(
        make(
          id: 'y',
          dueAt: DateTime(2026, 5, 26),
          createdAt: DateTime.utc(2026, 5, 26),
        ),
      );
      await repo.upsert(
        make(
          id: 't',
          dueAt: DateTime(2026, 5, 27, 15),
          createdAt: DateTime.utc(2026, 5, 27),
        ),
      );
      await repo.upsert(
        make(
          id: 'm',
          dueAt: DateTime(2026, 5, 28),
          createdAt: DateTime.utc(2026, 5, 27),
        ),
      );

      final list = await repo.watchToday(now).first;
      expect(list.map((t) => t.id).toSet(), {'y', 't'});
    });

    test('watchToday: 어제 doneAt 의 체크된 항목은 hide', () async {
      DateTime now() => DateTime(2026, 5, 27, 10);

      await repo.upsert(
        make(
          id: 'stale',
          dueAt: DateTime(2026, 5, 27, 8),
          doneAt: DateTime(2026, 5, 26, 18),
          createdAt: DateTime.utc(2026, 5, 26, 9),
        ),
      );
      await repo.upsert(
        make(
          id: 'fresh',
          dueAt: DateTime(2026, 5, 27, 8),
          doneAt: DateTime(2026, 5, 27, 9),
          createdAt: DateTime.utc(2026, 5, 27, 8),
        ),
      );

      final list = await repo.watchToday(now).first;
      expect(list.map((t) => t.id), ['fresh']);
    });

    test('watchToday: v1.5 — dueAt null(무날짜) 항목은 모두 오늘에서 제외', () async {
      DateTime now() => DateTime(2026, 5, 27, 10);

      // 무날짜는 createdAt 이 어제든 오늘이든 내일이든 모두 오늘 화면 제외.
      await repo.upsert(
        make(id: 'carry', createdAt: DateTime.utc(2026, 5, 26, 9)),
      );
      await repo.upsert(
        make(id: 'today', createdAt: DateTime.utc(2026, 5, 27, 8)),
      );
      await repo.upsert(
        make(id: 'future', createdAt: DateTime.utc(2026, 5, 28, 8)),
      );

      final list = await repo.watchToday(now).first;
      expect(list, isEmpty);
    });

    test(
      'watchToday: 날짜 지정 + 어제 체크 → hide (doneAt 우선), 오늘 체크 → visible',
      () async {
        DateTime now() => DateTime(2026, 5, 27, 10);

        // dueAt 오늘 + 어제 체크 → 체크는 doneAt 으로 판단되어 hide
        await repo.upsert(
          make(
            id: 'staleDone',
            dueAt: DateTime(2026, 5, 27, 8),
            doneAt: DateTime(2026, 5, 26, 20),
            createdAt: DateTime.utc(2026, 5, 26, 9),
          ),
        );
        // dueAt 오늘 + 오늘 체크 → 오늘 체크니까 visible
        await repo.upsert(
          make(
            id: 'todayDone',
            dueAt: DateTime(2026, 5, 27, 8),
            doneAt: DateTime(2026, 5, 27, 9),
            createdAt: DateTime.utc(2026, 5, 26, 9),
          ),
        );

        final list = await repo.watchToday(now).first;
        expect(list.map((t) => t.id), ['todayDone']);
      },
    );

    test(
      'v1.1 — sortOrder 우선 정렬, 같은 sortOrder 면 dueAt → createdAt fallback',
      () async {
        // 모두 미체크 (doneAt null) + 같은 카테고리.
        // sortOrder 정렬 검증을 위해 createdAt 은 일부러 역순으로.
        await repo.upsert(
          make(id: 'b', sortOrder: 1, createdAt: DateTime.utc(2026, 5, 27, 9)),
        );
        await repo.upsert(
          make(id: 'a', sortOrder: 0, createdAt: DateTime.utc(2026, 5, 27, 8)),
        );
        await repo.upsert(
          make(id: 'c', sortOrder: 2, createdAt: DateTime.utc(2026, 5, 27, 10)),
        );

        final list = await repo.watchAll().first;
        expect(list.map((t) => t.id), [
          'a',
          'b',
          'c',
        ], reason: 'sortOrder 0,1,2 순서대로');
      },
    );

    test('v1.1 — round-trip 시 parentId / type / sortOrder 보존', () async {
      final t = make(
        id: 'tree',
        title: '울트라 모드',
        parentId: 'js-super',
        type: TodoType.note,
        sortOrder: 7,
      );
      await repo.upsert(t);
      final got = await repo.getById('tree');
      expect(got, isNotNull);
      expect(got!.parentId, 'js-super');
      expect(got.type, TodoType.note);
      expect(got.sortOrder, 7);
    });

    test('v1.1 — type 기본 task, sortOrder 기본 0 (모델 default)', () async {
      // make() 의 기본값이 type=task, sortOrder=0 이므로 backwards-compat 확인.
      await repo.upsert(make(id: 'plain'));
      final got = await repo.getById('plain');
      expect(got!.type, TodoType.task);
      expect(got.sortOrder, 0);
      expect(got.parentId, isNull);
    });
  });

  group('Task B — minSiblingSortOrder', () {
    test('형제 없으면 null', () async {
      expect(
        await repo.minSiblingSortOrder(categoryId: Category.work.id),
        isNull,
      );
    });

    test('root 형제(parentId null) 의 min 반환', () async {
      await repo.upsert(make(id: 'a', category: Category.work, sortOrder: 3));
      await repo.upsert(make(id: 'b', category: Category.work, sortOrder: -2));
      await repo.upsert(make(id: 'c', category: Category.work, sortOrder: 5));
      expect(await repo.minSiblingSortOrder(categoryId: Category.work.id), -2);
    });

    test('parentId 지정 시 그 부모의 자식들만 대상', () async {
      await repo.upsert(
        make(id: 'root', category: Category.work, sortOrder: 0),
      );
      await repo.upsert(
        make(
          id: 'ch1',
          category: Category.work,
          parentId: 'root',
          sortOrder: 4,
        ),
      );
      await repo.upsert(
        make(
          id: 'ch2',
          category: Category.work,
          parentId: 'root',
          sortOrder: 1,
        ),
      );
      expect(
        await repo.minSiblingSortOrder(
          categoryId: Category.work.id,
          parentId: 'root',
        ),
        1,
      );
      // root 형제(parentId null)는 root 하나 → 0.
      expect(await repo.minSiblingSortOrder(categoryId: Category.work.id), 0);
    });

    test('다른 카테고리는 집계에서 제외', () async {
      await repo.upsert(make(id: 'w', category: Category.work, sortOrder: -9));
      await repo.upsert(make(id: 'd', category: Category.daily, sortOrder: 2));
      expect(await repo.minSiblingSortOrder(categoryId: Category.daily.id), 2);
    });
  });

  group('Task B — 정렬 키 (sortOrder asc, createdAt desc, id asc)', () {
    test('같은 sortOrder 면 최근 생성이 위 (updatedAt 은 무관)', () async {
      // updatedAt 을 createdAt 과 반대 방향으로 줘서, 키에서 빠졌는지 확인한다.
      await repo.upsert(
        make(
          id: 'first',
          sortOrder: 0,
          createdAt: DateTime.utc(2026, 5, 27, 8),
          updatedAt: DateTime.utc(2026, 5, 27, 20),
        ),
      );
      await repo.upsert(
        make(
          id: 'second',
          sortOrder: 0,
          createdAt: DateTime.utc(2026, 5, 27, 9),
          updatedAt: DateTime.utc(2026, 5, 27, 10),
        ),
      );
      final list = await repo.watchAll().first;
      expect(list.map((t) => t.id), ['second', 'first']);
    });

    test('updatedAt 만 갱신되면 순서가 바뀌지 않는다', () async {
      final a = make(
        id: 'a',
        sortOrder: 0,
        createdAt: DateTime.utc(2026, 5, 27, 8),
        updatedAt: DateTime.utc(2026, 5, 27, 8),
      );
      final b = make(
        id: 'b',
        sortOrder: 0,
        createdAt: DateTime.utc(2026, 5, 27, 9),
        updatedAt: DateTime.utc(2026, 5, 27, 9),
      );
      await repo.upsert(a);
      await repo.upsert(b);
      expect((await repo.watchAll().first).map((t) => t.id), ['b', 'a']);

      // a 를 한참 뒤에 건드려도(동기화·토글 등) 자리는 그대로.
      await repo.upsert(a.copyWith(updatedAt: DateTime.utc(2026, 5, 28, 15)));
      expect((await repo.watchAll().first).map((t) => t.id), ['b', 'a']);
    });

    test('sortOrder·createdAt 이 모두 같으면 id 로 결정 (조회마다 동일)', () async {
      final stamp = DateTime.utc(2026, 5, 27, 8);
      for (final id in ['c', 'a', 'b']) {
        await repo.upsert(
          make(id: id, sortOrder: 0, createdAt: stamp, updatedAt: stamp),
        );
      }
      expect((await repo.watchAll().first).map((t) => t.id), ['a', 'b', 'c']);
      expect((await repo.watchAll().first).map((t) => t.id), ['a', 'b', 'c']);
    });

    test('작은 sortOrder 가 위 (음수 포함)', () async {
      await repo.upsert(make(id: 'mid', sortOrder: 0));
      await repo.upsert(make(id: 'top', sortOrder: -5));
      await repo.upsert(make(id: 'bottom', sortOrder: 3));
      final list = await repo.watchAll().first;
      expect(list.map((t) => t.id), ['top', 'mid', 'bottom']);
    });
  });
}
