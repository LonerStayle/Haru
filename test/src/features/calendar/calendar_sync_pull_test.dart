import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/data/todo_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar/calendar_gateway.dart';
import 'package:solo_todo/src/features/calendar/calendar_service.dart';
import 'package:solo_todo/src/features/calendar/calendar_settings.dart';
import 'package:solo_todo/src/features/calendar/calendar_sync_service.dart';

import 'fake_calendar_gateway.dart';

void main() {
  late AppDatabase db;
  late TodoRepository repo;
  late FakeCalendarGateway gateway;
  late CalendarSyncService sync;

  final t0 = DateTime.utc(2026, 8, 15, 9);
  var clock = t0;
  const cal = 'primary';

  const settings = CalendarSettings(
    connected: true,
    writeCalendarId: cal,
    readCalendarIds: [cal],
  );

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
    clock = t0;
    gateway = FakeCalendarGateway(now: () => clock);
    sync = CalendarSyncService(
      gateway: gateway,
      ops: db.calendarOpsDao,
      repo: repo,
      now: () => clock,
    );
  });

  tearDown(() => db.close());

  Future<PullResult> pull({CalendarSettings? s}) =>
      sync.pull(settings: s ?? settings, categoryFor: (_) => Category.work);

  gcal.Event remote({
    String id = 'ev-1',
    String summary = '구글 일정',
    DateTime? start,
    bool organizerSelf = true,
  }) {
    final s = start ?? DateTime.utc(2026, 8, 20, 10);
    return gcal.Event(
      id: id,
      summary: summary,
      start: gcal.EventDateTime(dateTime: s),
      end: gcal.EventDateTime(dateTime: s.add(const Duration(hours: 1))),
      organizer: gcal.EventOrganizer(self: organizerSelf),
    );
  }

  Todo appTodo({
    String id = 'todo-1',
    String title = '앱 할 일',
    String? eventId = 'ev-1',
    String origin = 'app',
    DateTime? updatedAt,
  }) => Todo(
    id: id,
    title: title,
    category: Category.work,
    dueAt: DateTime.utc(2026, 8, 20, 10),
    createdAt: t0,
    updatedAt: updatedAt ?? t0,
    calendarEventId: eventId,
    calendarId: cal,
    calendarOrigin: origin,
  );

  group('신규 유입', () {
    test('구글에서 만든 일정이 할 일로 들어온다', () async {
      gateway.seedEvent(cal, remote());

      final r = await pull();

      expect(r.imported, 1);
      final todos = await repo.watchAll().first;
      expect(todos.single.title, '구글 일정');
      expect(todos.single.calendarEventId, 'ev-1');
      expect(todos.single.calendarOrigin, 'gcal');
      expect(todos.single.calendarId, cal);
    });

    test('지정한 카테고리로 들어간다', () async {
      gateway.seedEvent(cal, remote());
      await sync.pull(settings: settings, categoryFor: (_) => Category.daily);
      final todos = await repo.watchAll().first;
      expect(todos.single.category.id, Category.daily.id);
    });

    test('맨 위에 놓인다 — 방금 들어온 것을 바로 보이게', () async {
      await repo.upsert(appTodo(id: 'todo-기존', eventId: null));
      gateway.seedEvent(cal, remote());

      await pull();

      final todos = await repo.watchAll().first;
      final imported = todos.firstWhere((t) => t.calendarOrigin == 'gcal');
      final existing = todos.firstWhere((t) => t.calendarOrigin == 'app');
      expect(imported.sortOrder, lessThan(existing.sortOrder));
    });

    test('필터에 걸린 일정은 들어오지 않는다', () async {
      gateway.seedEvent(cal, remote(organizerSelf: false));
      final r = await pull();
      expect(r.imported, 0);
      expect(r.skipped, 1);
      expect(await repo.watchAll().first, isEmpty);
    });

    test('설정을 켜면 초대받은 일정도 들어온다', () async {
      gateway.seedEvent(cal, remote(organizerSelf: false));
      final r = await pull(
        s: const CalendarSettings(
          connected: true,
          readCalendarIds: [cal],
          importInvited: true,
        ),
      );
      expect(r.imported, 1);
    });

    test('앱이 만든 이벤트는 되들어오지 않는다', () async {
      final todo = appTodo();
      await repo.upsert(todo);
      // ignore: invalid_use_of_visible_for_testing_member
      final e = CalendarService.buildEvent(todo)..id = 'ev-1';
      gateway.seedEvent(cal, e);

      final r = await pull();

      expect(r.imported, 0);
      expect((await repo.watchAll().first).length, 1);
    });
  });

  group('기존 항목 갱신', () {
    test('캘린더에서 고친 제목이 앱에 반영된다', () async {
      await repo.upsert(appTodo(title: '옛 제목'));
      // 캘린더 쪽 수정이 로컬보다 나중이어야 LWW 로 이긴다.
      clock = t0.add(const Duration(hours: 1));
      gateway.seedEvent(cal, remote(summary: '캘린더에서 고침'));

      final r = await pull();

      expect(r.updated, 1);
      expect((await repo.getById('todo-1'))!.title, '캘린더에서 고침');
    });

    test('앱이 더 최신이면 덮어쓰지 않는다', () async {
      await repo.upsert(
        appTodo(title: '앱 최신', updatedAt: t0.add(const Duration(days: 1))),
      );
      gateway.seedEvent(cal, remote(summary: '캘린더 옛 제목'));

      final r = await pull();

      expect(r.updated, 0);
      expect((await repo.getById('todo-1'))!.title, '앱 최신');
    });
  });

  group('삭제 규칙 — 출처에 따라 갈린다', () {
    test('앱이 만든 할 일: 일정 연결만 해제하고 할 일은 남긴다', () async {
      await repo.upsert(appTodo(origin: 'app'));
      gateway.seedEvent(cal, remote());
      gateway.cancelRemotely(cal, 'ev-1');

      final r = await pull();

      expect(r.unlinked, 1);
      final t = await repo.getById('todo-1');
      expect(t, isNotNull);
      expect(t!.calendarEventId, isNull);
      expect(t.calendarId, isNull);
    });

    test('캘린더에서 유입된 할 일: 함께 삭제한다', () async {
      await repo.upsert(appTodo(origin: 'gcal'));
      gateway.seedEvent(cal, remote());
      gateway.cancelRemotely(cal, 'ev-1');

      final r = await pull();

      expect(r.deleted, 1);
      expect(await repo.getById('todo-1'), isNull);
    });

    test('링크가 없는 취소 이벤트는 무시한다', () async {
      gateway.seedEvent(cal, remote());
      gateway.cancelRemotely(cal, 'ev-1');

      final r = await pull();

      expect(r.deleted, 0);
      expect(r.unlinked, 0);
    });
  });

  group('증분 토큰', () {
    test('첫 동기화 후 토큰이 발급된다', () async {
      gateway.seedEvent(cal, remote());
      final r = await pull();
      expect(r.newSyncTokens[cal], isNotNull);
    });

    test('토큰이 있으면 그 이후 변경분만 받는다', () async {
      gateway.seedEvent(cal, remote());
      final first = await pull();

      final r = await pull(
        s: CalendarSettings(
          connected: true,
          readCalendarIds: const [cal],
          syncTokens: {cal: first.newSyncTokens[cal]!},
        ),
      );

      expect(r.imported, 0); // 새 변경 없음
    });

    test('토큰이 만료되면 전체 재수집으로 폴백한다', () async {
      gateway.seedEvent(cal, remote());
      gateway.expireSyncTokens();

      final r = await pull(
        s: const CalendarSettings(
          connected: true,
          readCalendarIds: [cal],
          syncTokens: {cal: '죽은-토큰'},
        ),
      );

      expect(r.expiredCalendars, contains(cal));
      expect(r.imported, 1); // 전체 재수집으로 결국 들어왔다
      expect(r.newSyncTokens[cal], isNotNull);
    });
  });

  group('오류', () {
    test('재인증이 필요하면 그 사실을 알린다', () async {
      gateway.failAlways(CalendarGatewayException.authRequired());
      final r = await pull();
      expect(r.authRequired, isTrue);
    });

    test('일시 오류는 다음 회차로 미룬다 — 토큰을 잃지 않는다', () async {
      gateway.failAlways(CalendarGatewayException.transient());
      final r = await pull(
        s: const CalendarSettings(
          connected: true,
          readCalendarIds: [cal],
          syncTokens: {cal: '살아있는-토큰'},
        ),
      );
      expect(r.newSyncTokens, isEmpty);
      expect(r.expiredCalendars, isEmpty);
    });
  });

  test('읽기 캘린더가 없으면 아무 것도 하지 않는다', () async {
    final r = await pull(
      s: const CalendarSettings(connected: true, readCalendarIds: []),
    );
    expect(r.imported, 0);
    expect(gateway.callCount(CalendarOp.listChanges), 0);
  });
}
