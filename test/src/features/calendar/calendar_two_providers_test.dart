import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/calendar_aware_todo_repository.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar/calendar_event.dart';
import 'package:solo_todo/src/features/calendar/calendar_gateway.dart';
import 'package:solo_todo/src/features/calendar/calendar_settings.dart';
import 'package:solo_todo/src/features/calendar/calendar_sync_service.dart';

import 'fake_calendar_gateway.dart';

/// 테스트용 그래프 캘린더 하나.
const _msCalendar = CalendarInfo(
  id: 'ms-cal-1',
  summary: '내 Outlook 캘린더',
  primary: true,
  accessRole: 'owner',
);

/// 구글과 Microsoft 를 **동시에 켰을 때** 서로를 침범하지 않는지 고정한다.
///
/// 이 파일이 지키는 불변식은 셋이다:
/// 1. 새 이벤트는 기본 서비스로만 나가고, 그 사실이 할 일에 기록된다.
/// 2. 이미 묶인 할 일의 수정·삭제는 **묶인 그 서비스**로만 간다.
/// 3. 각 동기화는 자기 서비스의 큐·링크만 건드린다.
///
/// 하나라도 깨지면 구글 이벤트 id 가 그래프로 날아가 404 만 반복하거나, 한쪽
/// 수신이 다른 쪽 링크를 지워버린다.
void main() {
  late AppDatabase db;
  late CalendarAwareTodoRepository repo;
  late FakeCalendarGateway googleGw;
  late FakeCalendarGateway msGw;
  late CalendarSyncService googleSync;
  late CalendarSyncService msSync;
  late CalendarSettings settings;
  var seq = 0;

  final t0 = DateTime.utc(2026, 8, 15, 9);
  const gCal = 'primary';
  const mCal = 'ms-cal-1';

  /// 두 서비스 모두 연결된 기본 상태.
  CalendarSettings bothConnected({
    CalendarProvider defaultProvider = CalendarProvider.google,
  }) => CalendarSettings(
    connected: true,
    writeCalendarId: gCal,
    readCalendarIds: const [gCal],
    defaultAddToCalendar: true,
    defaultProvider: defaultProvider,
    microsoft: const CalendarConnection(
      connected: true,
      writeCalendarId: mCal,
      readCalendarIds: [mCal],
    ),
  );

  setUp(() {
    db = AppDatabase.memory();
    seq = 0;
    settings = bothConnected();
    repo = CalendarAwareTodoRepository(
      inner: LocalTodoRepository(db.todosDao),
      ops: db.calendarOpsDao,
      settings: () => settings,
      now: () => t0,
      idGen: () => 'op-${seq++}',
    );
    googleGw = FakeCalendarGateway(now: () => t0);
    msGw = FakeCalendarGateway(
      now: () => t0,
      provider: CalendarProvider.microsoft,
      calendars: const [_msCalendar],
    );
    googleSync = CalendarSyncService(
      gateway: googleGw,
      ops: db.calendarOpsDao,
      repo: LocalTodoRepository(db.todosDao),
      now: () => t0,
    );
    msSync = CalendarSyncService(
      gateway: msGw,
      ops: db.calendarOpsDao,
      repo: LocalTodoRepository(db.todosDao),
      now: () => t0,
    );
  });

  tearDown(() => db.close());

  Todo make({
    String id = 'todo-1',
    String title = '제목',
    DateTime? dueAt,
    String? calendarEventId,
    String? calendarId,
    String? calendarProvider,
    String calendarOrigin = 'app',
    DateTime? updatedAt,
  }) => Todo(
    id: id,
    title: title,
    category: Category.work,
    dueAt: dueAt ?? DateTime.utc(2026, 8, 20, 14),
    createdAt: t0,
    updatedAt: updatedAt ?? t0,
    calendarEventId: calendarEventId,
    calendarId: calendarId,
    calendarProvider: calendarProvider,
    calendarOrigin: calendarOrigin,
  );

  Future<List<CalendarOpRow>> queue() => db.calendarOpsDao.dueOps(t0);

  group('새 이벤트는 기본 서비스로만 나간다', () {
    test('기본이 구글이면 구글에만 생기고 링크에 provider 가 남는다', () async {
      await repo.upsert(make());
      await googleSync.flushPending();
      await msSync.flushPending();

      expect(googleGw.liveEvents(gCal), hasLength(1));
      expect(msGw.liveEvents(mCal), isEmpty);
      final saved = await repo.getById('todo-1');
      expect(saved!.calendarProvider, 'google');
      expect(saved.calendarId, gCal);
    });

    test('기본이 Microsoft 면 그래프에만 생긴다', () async {
      settings = bothConnected(defaultProvider: CalendarProvider.microsoft);
      await repo.upsert(make());
      await googleSync.flushPending();
      await msSync.flushPending();

      expect(googleGw.liveEvents(gCal), isEmpty);
      expect(msGw.liveEvents(mCal), hasLength(1));
      final saved = await repo.getById('todo-1');
      expect(saved!.calendarProvider, 'microsoft');
      expect(saved.calendarId, mCal);
    });

    test('기본 서비스가 연결 안 됐으면 연결된 다른 쪽으로 떨어진다', () async {
      // "연결은 했는데 할 일이 캘린더에 안 올라간다" 를 막는 규칙.
      settings = bothConnected(
        defaultProvider: CalendarProvider.microsoft,
      ).copyWith(microsoft: const CalendarConnection(connected: false));

      await repo.upsert(make());
      await googleSync.flushPending();

      expect(googleGw.liveEvents(gCal), hasLength(1));
      expect((await repo.getById('todo-1'))!.calendarProvider, 'google');
    });

    test('아무 데도 연결 안 됐으면 큐가 비어 있다', () async {
      settings = const CalendarSettings(
        microsoft: CalendarConnection(connected: false),
      );
      await repo.upsert(make());
      expect(await queue(), isEmpty);
    });
  });

  group('수정·삭제는 묶인 서비스로만 간다', () {
    test('그래프에 묶인 할 일을 고쳐도 구글은 호출되지 않는다', () async {
      msGw.seedEvent(
        mCal,
        CalEvent(
          id: 'ms-1',
          title: '옛 제목',
          start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
          end: CalEventTime.at(DateTime.utc(2026, 8, 20, 15)),
        ),
      );
      final linked = make(
        calendarEventId: 'ms-1',
        calendarId: mCal,
        calendarProvider: 'microsoft',
      );
      await repo.upsert(linked);
      await repo.upsert(
        linked.copyWith(
          title: '새 제목',
          updatedAt: t0.add(const Duration(minutes: 1)),
        ),
      );

      final ops = await queue();
      expect(ops.single.provider, 'microsoft');

      await googleSync.flushPending();
      expect(googleGw.callCount(CalendarOp.updateEvent), 0);
      expect(await queue(), hasLength(1), reason: '구글이 남의 작업을 집어가면 안 된다');

      await msSync.flushPending();
      expect(msGw.eventById(mCal, 'ms-1')!.title, '새 제목');
      expect(await queue(), isEmpty);
    });

    test('삭제도 묶인 서비스로 간다', () async {
      msGw.seedEvent(
        mCal,
        CalEvent(
          id: 'ms-2',
          title: '지울 것',
          start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
        ),
      );
      await repo.upsert(
        make(
          calendarEventId: 'ms-2',
          calendarId: mCal,
          calendarProvider: 'microsoft',
        ),
      );
      await repo.deleteById('todo-1');

      await msSync.flushPending();
      expect(msGw.liveEvents(mCal), isEmpty);
      expect(googleGw.callCount(CalendarOp.deleteEvent), 0);
    });

    test('provider 기록이 없는 옛 할 일은 구글로 간다 (하위호환)', () async {
      googleGw.seedEvent(
        gCal,
        CalEvent(
          id: 'g-1',
          title: '옛 항목',
          start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
        ),
      );
      final legacy = make(calendarEventId: 'g-1', calendarId: gCal);
      await repo.upsert(legacy);
      await repo.upsert(
        legacy.copyWith(
          title: '고침',
          updatedAt: t0.add(const Duration(minutes: 1)),
        ),
      );

      expect((await queue()).single.provider, 'google');
      await googleSync.flushPending();
      expect(googleGw.eventById(gCal, 'g-1')!.title, '고침');
    });

    test('묶인 서비스의 연결이 끊겨 있으면 작업을 쌓지 않는다', () async {
      settings = bothConnected().copyWith(
        microsoft: const CalendarConnection(connected: false),
      );
      final linked = make(
        calendarEventId: 'ms-3',
        calendarId: mCal,
        calendarProvider: 'microsoft',
      );
      await repo.upsert(linked);
      await repo.upsert(
        linked.copyWith(
          title: '고침',
          updatedAt: t0.add(const Duration(minutes: 1)),
        ),
      );
      expect(await queue(), isEmpty);
    });
  });

  group('수신 — 각자 자기 링크만 본다', () {
    Future<PullResult> pullGoogle() =>
        googleSync.pull(settings: settings, categoryFor: (_) => Category.work);
    Future<PullResult> pullMs() =>
        msSync.pull(settings: settings, categoryFor: (_) => Category.daily);

    test('그래프에서 유입된 할 일은 출처와 서비스가 기록된다', () async {
      msGw.seedEvent(
        mCal,
        CalEvent(
          id: 'ms-in-1',
          title: 'Teams 회의',
          start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
          end: CalEventTime.at(DateTime.utc(2026, 8, 20, 15)),
        ),
      );

      final r = await pullMs();

      expect(r.imported, 1);
      final todo = (await repo.watchAll().first).single;
      expect(todo.title, 'Teams 회의');
      expect(todo.calendarOrigin, 'msgraph');
      expect(todo.calendarProvider, 'microsoft');
      expect(todo.isFromCalendar, isTrue);
      expect(todo.category.id, Category.daily.id);
    });

    test('그래프에서 지워지면 유입 할 일도 함께 지워진다', () async {
      msGw.seedEvent(
        mCal,
        CalEvent(
          id: 'ms-in-2',
          title: '취소될 회의',
          start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
        ),
      );
      await pullMs();
      msGw.cancelRemotely(mCal, 'ms-in-2');

      final r = await pullMs();

      expect(r.deleted, 1);
      expect(await repo.watchAll().first, isEmpty);
    });

    test('앱이 만든 할 일은 그래프에서 지워도 남고 연결만 끊긴다', () async {
      await repo.upsert(
        make(
          calendarEventId: 'ms-in-3',
          calendarId: mCal,
          calendarProvider: 'microsoft',
        ),
      );
      msGw.seedEvent(
        mCal,
        CalEvent(
          id: 'ms-in-3',
          title: '앱이 만든 것',
          start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
        ),
      );
      msGw.cancelRemotely(mCal, 'ms-in-3');

      final r = await pullMs();

      expect(r.unlinked, 1);
      final todo = (await repo.watchAll().first).single;
      expect(todo.calendarEventId, isNull);
      expect(todo.calendarProvider, isNull);
    });

    test('구글 수신은 그래프에 묶인 할 일을 건드리지 않는다 — 이벤트 id 가 같아도', () async {
      // 두 서비스가 우연히 같은 id 를 쓸 수 있다고 가정한 방어. 링크 조회가
      // provider 로 걸러지지 않으면 한쪽 수신이 다른 쪽 링크를 덮어쓴다.
      const sharedId = 'same-id';
      await repo.upsert(
        make(
          title: '그래프 항목',
          calendarEventId: sharedId,
          calendarId: mCal,
          calendarProvider: 'microsoft',
        ),
      );
      googleGw.seedEvent(
        gCal,
        CalEvent(
          id: sharedId,
          title: '구글에서 온 다른 일정',
          start: CalEventTime.at(DateTime.utc(2026, 8, 21, 14)),
          end: CalEventTime.at(DateTime.utc(2026, 8, 21, 15)),
          updated: t0.add(const Duration(days: 1)),
        ),
      );

      final r = await pullGoogle();

      // 기존 할 일은 그대로고, 구글 것은 새 할 일로 들어온다.
      expect(r.updated, 0);
      expect((await repo.getById('todo-1'))!.title, '그래프 항목');
      expect(r.imported, 1);
    });

    test('읽기 캘린더가 비어 있으면 아무 호출도 하지 않는다', () async {
      // Microsoft 기본값은 "읽기 캘린더 없음" 이다 — 그래프의 캘린더 id 는 목록을
      // 받아봐야 알 수 있어 가짜 기본값을 넣을 수 없다.
      settings = bothConnected().copyWith(
        microsoft: CalendarConnection.microsoftDefaults.copyWith(
          connected: true,
        ),
      );
      final r = await pullMs();
      expect(r.imported, 0);
      expect(msGw.callCount(CalendarOp.listChanges), 0);
    });
  });

  group('설정 — 서비스별로 따로 산다', () {
    test('viewFor 가 각자의 칸을 준다', () {
      final s = bothConnected();
      expect(s.viewFor(CalendarProvider.google).writeCalendarId, gCal);
      expect(s.viewFor(CalendarProvider.microsoft).writeCalendarId, mCal);
    });

    test('withConnection 은 다른 서비스를 건드리지 않는다', () {
      final s = bothConnected().withConnection(
        CalendarProvider.microsoft,
        const CalendarConnection(connected: false),
      );
      expect(s.connected, isTrue);
      expect(s.microsoft.connected, isFalse);
      expect(s.writeCalendarId, gCal);
    });

    test('anyConnected 는 한쪽만 켜져 있어도 참', () {
      const onlyMs = CalendarSettings(
        microsoft: CalendarConnection(connected: true),
      );
      expect(onlyMs.connected, isFalse);
      expect(onlyMs.anyConnected, isTrue);
    });

    test('creationTarget 은 기본 서비스 → 연결된 다른 쪽 순으로 고른다', () {
      expect(
        bothConnected().creationTarget()!.provider,
        CalendarProvider.google,
      );
      expect(
        bothConnected(
          defaultProvider: CalendarProvider.microsoft,
        ).creationTarget()!.provider,
        CalendarProvider.microsoft,
      );
      expect(const CalendarSettings().creationTarget(), isNull);
    });

    test('모르는 provider 문자열은 구글로 읽는다 (하위호환)', () {
      expect(CalendarProvider.fromWire(null), CalendarProvider.google);
      expect(CalendarProvider.fromWire('알 수 없음'), CalendarProvider.google);
      expect(
        CalendarProvider.fromWire('microsoft'),
        CalendarProvider.microsoft,
      );
      expect(
        CalendarProvider.fromOriginTag('msgraph'),
        CalendarProvider.microsoft,
      );
      expect(CalendarProvider.fromOriginTag('gcal'), CalendarProvider.google);
    });
  });

  group('큐 — 서비스별로 갈라진다', () {
    test('dueOps(provider) 가 자기 것만 준다', () async {
      settings = bothConnected();
      await repo.upsert(make(id: 'g', title: '구글행'));
      settings = bothConnected(defaultProvider: CalendarProvider.microsoft);
      await repo.upsert(make(id: 'm', title: '그래프행'));

      final all = await db.calendarOpsDao.dueOps(t0);
      expect(all, hasLength(2));
      expect(
        (await db.calendarOpsDao.dueOps(
          t0,
          provider: CalendarProvider.google,
        )).single.todoId,
        'g',
      );
      expect(
        (await db.calendarOpsDao.dueOps(
          t0,
          provider: CalendarProvider.microsoft,
        )).single.todoId,
        'm',
      );
    });

    test('한쪽만 비우면 다른 쪽 대기열은 남는다 — 연결 해제 시 필요', () async {
      settings = bothConnected();
      await repo.upsert(make(id: 'g'));
      settings = bothConnected(defaultProvider: CalendarProvider.microsoft);
      await repo.upsert(make(id: 'm'));

      await db.calendarOpsDao.clearProvider(CalendarProvider.microsoft);

      final left = await db.calendarOpsDao.dueOps(t0);
      expect(left.single.todoId, 'g');
    });
  });
}
