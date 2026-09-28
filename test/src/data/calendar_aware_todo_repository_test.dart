import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/calendar_aware_todo_repository.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar/calendar_settings.dart';

void main() {
  late AppDatabase db;
  late CalendarAwareTodoRepository repo;
  var settings = const CalendarSettings(
    connected: true,
    writeCalendarId: 'write@cal',
    defaultAddToCalendar: true,
  );
  var seq = 0;

  final t0 = DateTime.utc(2026, 8, 15, 9);

  setUp(() async {
    db = AppDatabase.memory();
    seq = 0;
    settings = const CalendarSettings(
      connected: true,
      writeCalendarId: 'write@cal',
      defaultAddToCalendar: true,
    );
    repo = CalendarAwareTodoRepository(
      inner: LocalTodoRepository(db.todosDao),
      ops: db.calendarOpsDao,
      settings: () => settings,
      now: () => t0,
      idGen: () => 'op-${seq++}',
    );
  });

  tearDown(() => db.close());

  Todo make({
    String id = 'todo-1',
    String title = '제목',
    DateTime? dueAt,
    String? calendarEventId,
    String? calendarId,
    int sortOrder = 0,
    TodoType type = TodoType.task,
  }) => Todo(
    id: id,
    title: title,
    category: Category.work,
    dueAt: dueAt,
    createdAt: t0,
    updatedAt: t0,
    calendarEventId: calendarEventId,
    calendarId: calendarId,
    sortOrder: sortOrder,
    type: type,
  );

  Future<List<CalendarOpRow>> queue() => db.calendarOpsDao.dueOps(t0);

  group('읽기 — 그대로 위임한다', () {
    test('getById / watchAll 이 inner 결과를 낸다', () async {
      await repo.upsert(make(title: '조회용'));
      expect((await repo.getById('todo-1'))!.title, '조회용');
      expect((await repo.watchAll().first).length, 1);
    });

    test('minSiblingSortOrder 도 위임된다', () async {
      await repo.upsert(make(sortOrder: 5));
      final min = await repo.minSiblingSortOrder(
        categoryId: Category.work.id,
        parentId: null,
      );
      expect(min, 5);
    });
  });

  group('큐 적재', () {
    test('신규 + 날짜 + 기본 등록 ON → create op 1건', () async {
      await repo.upsert(make(dueAt: DateTime.utc(2026, 8, 20, 14)));
      final q = await queue();
      expect(q.length, 1);
      expect(q.single.kind, 'create');
      expect(q.single.todoId, 'todo-1');
      expect(q.single.calendarId, 'write@cal');
      expect(q.single.eventId, isNull);
    });

    test('create op 의 payload 는 저장된 할 일 스냅샷', () async {
      final todo = make(dueAt: DateTime.utc(2026, 8, 20, 14), title: '보고서');
      await repo.upsert(todo);
      final decoded =
          jsonDecode((await queue()).single.payload!) as Map<String, dynamic>;
      expect(decoded['title'], '보고서');
      expect(decoded['id'], 'todo-1');
    });

    test('감시 필드 변경 → update op (대상 이벤트·캘린더 지정)', () async {
      final linked = make(
        dueAt: DateTime.utc(2026, 8, 20, 14),
        calendarEventId: 'ev-1',
        calendarId: 'write@cal',
      );
      await repo.upsert(linked);
      await db.calendarOpsDao.clear();

      await repo.upsert(linked.copyWith(title: '바뀐 제목'));
      final q = await queue();
      expect(q.single.kind, 'update');
      expect(q.single.eventId, 'ev-1');
      expect(q.single.calendarId, 'write@cal');
    });

    test('정렬만 바뀌면 큐가 비어 있다 — 정렬 한 번에 API N회를 막는다', () async {
      final linked = make(
        dueAt: DateTime.utc(2026, 8, 20, 14),
        calendarEventId: 'ev-1',
        calendarId: 'write@cal',
      );
      await repo.upsert(linked);
      await db.calendarOpsDao.clear();

      await repo.upsert(linked.copyWith(sortOrder: 9));
      expect(await queue(), isEmpty);
    });

    test('링크 저장(create 성공 후 되쓰기)은 큐를 늘리지 않는다 — 무한 재적재 방지', () async {
      final todo = make(dueAt: DateTime.utc(2026, 8, 20, 14));
      await repo.upsert(todo);
      await db.calendarOpsDao.clear();

      await repo.upsert(
        todo.copyWith(calendarEventId: 'ev-1', calendarId: 'write@cal'),
      );
      expect(await queue(), isEmpty);
    });

    test('날짜를 지우면 delete op', () async {
      final linked = make(
        dueAt: DateTime.utc(2026, 8, 20, 14),
        calendarEventId: 'ev-1',
        calendarId: 'write@cal',
      );
      await repo.upsert(linked);
      await db.calendarOpsDao.clear();

      await repo.upsert(linked.copyWith(dueAt: null));
      final q = await queue();
      expect(q.single.kind, 'delete');
      expect(q.single.eventId, 'ev-1');
      expect(q.single.payload, isNull);
    });

    test('메모로 전환하면 delete op', () async {
      final linked = make(
        dueAt: DateTime.utc(2026, 8, 20, 14),
        calendarEventId: 'ev-1',
        calendarId: 'write@cal',
      );
      await repo.upsert(linked);
      await db.calendarOpsDao.clear();

      await repo.upsert(linked.copyWith(type: TodoType.note));
      expect((await queue()).single.kind, 'delete');
    });
  });

  group('삭제', () {
    test('링크된 할 일을 지우면 delete op 가 남는다', () async {
      final linked = make(
        dueAt: DateTime.utc(2026, 8, 20, 14),
        calendarEventId: 'ev-1',
        calendarId: 'write@cal',
      );
      await repo.upsert(linked);
      await db.calendarOpsDao.clear();

      await repo.deleteById('todo-1');
      final q = await queue();
      expect(q.single.kind, 'delete');
      expect(q.single.eventId, 'ev-1');
      expect(q.single.calendarId, 'write@cal');
      // 로컬에서도 실제로 지워졌다.
      expect(await repo.getById('todo-1'), isNull);
    });

    test('링크 없는 할 일 삭제는 큐를 건드리지 않는다', () async {
      await repo.upsert(make());
      await db.calendarOpsDao.clear();
      await repo.deleteById('todo-1');
      expect(await queue(), isEmpty);
    });
  });

  group('등록 의사', () {
    test('기본 등록 OFF 면 새 항목을 캘린더에 올리지 않는다', () async {
      settings = settings.copyWith(defaultAddToCalendar: false);
      await repo.upsert(make(dueAt: DateTime.utc(2026, 8, 20, 14)));
      expect(await queue(), isEmpty);
    });

    test('1회 의사 표시로 그 저장만 등록한다', () async {
      settings = settings.copyWith(defaultAddToCalendar: false);
      repo.intendCalendar(true);
      await repo.upsert(make(dueAt: DateTime.utc(2026, 8, 20, 14)));
      expect((await queue()).single.kind, 'create');
    });

    test('1회 의사는 다음 저장에 새어나가지 않는다', () async {
      settings = settings.copyWith(defaultAddToCalendar: false);
      repo.intendCalendar(true);
      await repo.upsert(make(dueAt: DateTime.utc(2026, 8, 20, 14)));
      await db.calendarOpsDao.clear();

      await repo.upsert(
        make(id: 'todo-2', dueAt: DateTime.utc(2026, 8, 21, 14)),
      );
      expect(await queue(), isEmpty);
    });

    test('의사 OFF 로 명시하면 기본이 ON 이어도 올리지 않는다', () async {
      repo.intendCalendar(false);
      await repo.upsert(make(dueAt: DateTime.utc(2026, 8, 20, 14)));
      expect(await queue(), isEmpty);
    });
  });

  group('저장 우선 — 캘린더는 저장을 막지 않는다', () {
    test('연동이 꺼져 있어도 로컬 저장은 정상이고 큐는 비어 있다', () async {
      settings = settings.copyWith(connected: false);
      await repo.upsert(make(dueAt: DateTime.utc(2026, 8, 20, 14)));
      expect((await repo.getById('todo-1'))!.title, '제목');
      expect(await queue(), isEmpty);
    });
  });
}
