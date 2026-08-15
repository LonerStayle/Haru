import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/data/todo_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar/calendar_gateway.dart';
import 'package:solo_todo/src/features/calendar/calendar_sync_service.dart';

import 'fake_calendar_gateway.dart';

void main() {
  late AppDatabase db;
  late TodoRepository repo;
  late FakeCalendarGateway gateway;
  late CalendarSyncService sync;

  final t0 = DateTime.utc(2026, 8, 15, 9);
  var clock = t0;
  const cal = 'write@cal';

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
    gateway = FakeCalendarGateway(now: () => clock);
    clock = t0;
    sync = CalendarSyncService(
      gateway: gateway,
      ops: db.calendarOpsDao,
      repo: repo,
      now: () => clock,
    );
  });

  tearDown(() => db.close());

  Todo make({
    String id = 'todo-1',
    String title = '제목',
    DateTime? dueAt,
    String? calendarEventId,
    String? calendarId,
  }) => Todo(
    id: id,
    title: title,
    category: Category.work,
    dueAt: dueAt ?? DateTime.utc(2026, 8, 20, 14),
    createdAt: t0,
    updatedAt: t0,
    calendarEventId: calendarEventId,
    calendarId: calendarId,
  );

  Future<void> enqueue({
    required String kind,
    required String todoId,
    String? eventId,
    String calendarId = cal,
    String id = 'op-1',
  }) => db.calendarOpsDao.enqueue(
    CalendarOpRow(
      id: id,
      kind: kind,
      todoId: todoId,
      eventId: eventId,
      calendarId: calendarId,
      payload: null,
      attempts: 0,
      lastError: null,
      nextAttemptAt: null,
      createdAt: clock,
    ),
  );

  Future<List<CalendarOpRow>> queue() =>
      db.calendarOpsDao.dueOps(clock.add(const Duration(days: 365)));

  group('생성', () {
    test('이벤트를 만들고 링크를 저장한 뒤 큐에서 내린다', () async {
      await repo.upsert(make());
      await enqueue(kind: 'create', todoId: 'todo-1');

      final r = await sync.flushPending();

      expect(r.succeeded, 1);
      expect(gateway.liveEvents(cal).length, 1);
      final saved = await repo.getById('todo-1');
      expect(saved!.calendarEventId, isNotNull);
      expect(saved.calendarId, cal);
      expect(await queue(), isEmpty);
    });

    test('링크를 저장해도 updatedAt 은 그대로 — echo 차단 기준을 지킨다', () async {
      await repo.upsert(make());
      await enqueue(kind: 'create', todoId: 'todo-1');
      clock = t0.add(const Duration(hours: 3));

      await sync.flushPending();

      expect((await repo.getById('todo-1'))!.updatedAt, t0);
    });

    test('이미 링크가 있으면 생성 대신 갱신한다 — 두 기기 중복 방지', () async {
      gateway.seedEvent(cal, _event('ev-기존'));
      await repo.upsert(make(calendarEventId: 'ev-기존', calendarId: cal));
      await enqueue(kind: 'create', todoId: 'todo-1');

      await sync.flushPending();

      expect(gateway.callCount(CalendarOp.insertEvent), 0);
      expect(gateway.callCount(CalendarOp.updateEvent), 1);
      expect(gateway.liveEvents(cal).length, 1);
    });

    test('할 일이 이미 지워졌으면 만들지 않고 큐만 비운다', () async {
      await enqueue(kind: 'create', todoId: '없는-todo');

      final r = await sync.flushPending();

      expect(gateway.callCount(CalendarOp.insertEvent), 0);
      expect(r.dropped, 1);
      expect(await queue(), isEmpty);
    });
  });

  group('갱신·삭제', () {
    test('큐에 쌓인 뒤 바뀐 최신 상태로 갱신한다', () async {
      gateway.seedEvent(cal, _event('ev-1'));
      await repo.upsert(
        make(title: '최신 제목', calendarEventId: 'ev-1', calendarId: cal),
      );
      await enqueue(kind: 'update', todoId: 'todo-1', eventId: 'ev-1');

      await sync.flushPending();

      expect(gateway.eventById(cal, 'ev-1')!.summary, '최신 제목');
    });

    test('삭제는 할 일이 없어도 진행한다 — 이벤트만 남은 상태를 정리', () async {
      gateway.seedEvent(cal, _event('ev-1'));
      await enqueue(kind: 'delete', todoId: 'todo-1', eventId: 'ev-1');

      final r = await sync.flushPending();

      expect(r.succeeded, 1);
      expect(gateway.liveEvents(cal), isEmpty);
    });

    test('갱신 대상 할 일이 사라졌으면 이벤트를 지운다', () async {
      gateway.seedEvent(cal, _event('ev-1'));
      await enqueue(kind: 'update', todoId: '없는-todo', eventId: 'ev-1');

      await sync.flushPending();

      expect(gateway.liveEvents(cal), isEmpty);
    });
  });

  group('실패 — 항목은 서로 독립이다', () {
    test('하나가 rate limit 이어도 나머지는 진행한다', () async {
      await repo.upsert(make(id: 'todo-1'));
      await repo.upsert(make(id: 'todo-2'));
      await enqueue(kind: 'create', todoId: 'todo-1', id: 'op-1');
      await enqueue(kind: 'create', todoId: 'todo-2', id: 'op-2');
      gateway.failNext(
        CalendarGatewayException.rateLimited(),
        op: CalendarOp.insertEvent,
      );

      final r = await sync.flushPending();

      expect(r.succeeded, 1);
      expect(r.retryable, 1);
      expect(gateway.liveEvents(cal).length, 1);
    });

    test('재시도 가능 실패는 큐에 남고 백오프가 걸린다', () async {
      await repo.upsert(make());
      await enqueue(kind: 'create', todoId: 'todo-1');
      gateway.failNext(CalendarGatewayException.transient());

      await sync.flushPending();

      final rows = await db.calendarOpsDao.dueOps(
        clock.add(const Duration(days: 1)),
      );
      expect(rows.single.attempts, 1);
      expect(rows.single.nextAttemptAt, isNotNull);
      expect(rows.single.lastError, isNotNull);
    });

    test('백오프 시각 전에는 다시 시도하지 않는다', () async {
      await repo.upsert(make());
      await enqueue(kind: 'create', todoId: 'todo-1');
      gateway.failNext(CalendarGatewayException.transient());
      await sync.flushPending();

      gateway.clearFailures();
      final r = await sync.flushPending(); // 시계는 그대로 — 아직 백오프 중

      expect(r.succeeded, 0);
      expect(gateway.liveEvents(cal), isEmpty);
    });

    test('백오프가 지나면 다시 시도해 성공한다', () async {
      await repo.upsert(make());
      await enqueue(kind: 'create', todoId: 'todo-1');
      gateway.failNext(CalendarGatewayException.transient());
      await sync.flushPending();

      gateway.clearFailures();
      clock = clock.add(const Duration(hours: 2));
      final r = await sync.flushPending();

      expect(r.succeeded, 1);
      expect(await queue(), isEmpty);
    });

    test('재인증이 필요하면 큐를 보존한 채 즉시 멈춘다', () async {
      await repo.upsert(make(id: 'todo-1'));
      await repo.upsert(make(id: 'todo-2'));
      await enqueue(kind: 'create', todoId: 'todo-1', id: 'op-1');
      await enqueue(kind: 'create', todoId: 'todo-2', id: 'op-2');
      gateway.failAlways(CalendarGatewayException.authRequired());

      final r = await sync.flushPending();

      expect(r.authRequired, isTrue);
      expect(gateway.callCount(CalendarOp.insertEvent), 1); // 두 번째는 시도조차 안 함
      expect((await queue()).length, 2);
    });

    test('영구 실패는 재시도 상한까지만 버티고 큐에서 내린다', () async {
      await repo.upsert(make());
      await enqueue(kind: 'create', todoId: 'todo-1');
      gateway.failAlways(CalendarGatewayException.permanent('잘못된 요청'));

      var guard = 0;
      while ((await queue()).isNotEmpty && guard++ < 20) {
        clock = clock.add(const Duration(hours: 2));
        await sync.flushPending();
      }

      expect(await queue(), isEmpty);
      expect(guard, lessThan(20));
    });
  });

  test('큐가 비어 있으면 아무 호출도 하지 않는다', () async {
    final r = await sync.flushPending();
    expect(r.succeeded, 0);
    expect(gateway.callCount(CalendarOp.insertEvent), 0);
  });
}

/// 이미 구글 쪽에 있는 이벤트를 흉내내는 최소 형태.
gcal.Event _event(String id) => gcal.Event(
  id: id,
  summary: '옛 제목',
  start: gcal.EventDateTime(dateTime: DateTime.utc(2026, 8, 20, 14)),
  end: gcal.EventDateTime(dateTime: DateTime.utc(2026, 8, 20, 15)),
);
