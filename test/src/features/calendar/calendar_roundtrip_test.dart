import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/calendar_aware_todo_repository.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar/calendar_settings.dart';
import 'package:solo_todo/src/features/calendar/calendar_sync_service.dart';

import 'fake_calendar_gateway.dart';

/// 앱 ↔ 캘린더 왕복이 **스스로 멈추는지** 검증한다.
///
/// 이 피처 최대 사고 위험은 무한 루프다. 앱이 이벤트를 올리면 구글이 그 이벤트의
/// 수정 시각을 새로 찍기 때문에, 시각만 비교하면 우리가 쓴 변경이 매번 "캘린더가 더
/// 최신" 으로 돌아와 앱을 갱신하고, 그 갱신이 또 올라간다. 여기 테스트들이 그 고리가
/// 실제로 끊겨 있는지 본다 (수용 기준 9).
void main() {
  late AppDatabase db;
  late FakeCalendarGateway gateway;
  late CalendarAwareTodoRepository uiRepo;
  late CalendarSyncService sync;

  final t0 = DateTime.utc(2026, 8, 15, 9);
  var clock = t0;
  const cal = 'primary';

  var settings = const CalendarSettings(
    connected: true,
    writeCalendarId: cal,
    readCalendarIds: [cal],
    defaultAddToCalendar: true,
  );

  setUp(() {
    db = AppDatabase.memory();
    clock = t0;
    settings = const CalendarSettings(
      connected: true,
      writeCalendarId: cal,
      readCalendarIds: [cal],
      defaultAddToCalendar: true,
    );
    gateway = FakeCalendarGateway(now: () => clock);

    // 화면이 쓰는 저장소 — 데코레이터가 붙어 저장할 때마다 큐에 쌓인다.
    uiRepo = CalendarAwareTodoRepository(
      inner: LocalTodoRepository(db.todosDao),
      ops: db.calendarOpsDao,
      settings: () => settings,
      now: () => clock,
    );
    // 동기화 서비스가 쓰는 저장소 — 데코레이터 없음. 이 구분이 루프 차단의 핵심이다.
    sync = CalendarSyncService(
      gateway: gateway,
      ops: db.calendarOpsDao,
      repo: LocalTodoRepository(db.todosDao),
      now: () => clock,
    );
  });

  tearDown(() => db.close());

  Todo make({
    String id = 'todo-1',
    String title = '보고서 작성',
    DateTime? dueAt,
    DateTime? endAt,
    bool isAllDay = false,
    String timeAnchor = 'start',
  }) => Todo(
    id: id,
    title: title,
    category: Category.work,
    dueAt: dueAt ?? DateTime.utc(2026, 8, 20, 14),
    endAt: endAt,
    isAllDay: isAllDay,
    timeAnchor: timeAnchor,
    createdAt: t0,
    updatedAt: t0,
  );

  Future<int> queueLength() async => (await db.calendarOpsDao.dueOps(
    clock.add(const Duration(days: 365)),
  )).length;

  /// 한 사이클: 보내기 → 받아오기.
  Future<void> cycle() async {
    await sync.flushPending();
    final pull = await sync.pull(
      settings: settings,
      categoryFor: (_) => Category.work,
    );
    settings = settings.copyWith(syncTokens: {...pull.newSyncTokens});
  }

  group('왕복이 스스로 멈춘다', () {
    test('등록 후 두 번 더 돌려도 큐가 비어 있다', () async {
      await uiRepo.upsert(make());
      expect(await queueLength(), 1);

      await cycle();
      expect(await queueLength(), 0, reason: '첫 사이클에 이벤트가 만들어진다');

      await cycle();
      await cycle();
      expect(await queueLength(), 0, reason: '받아온 내용이 다시 큐에 쌓이면 안 된다');
      expect(gateway.liveEvents(cal).length, 1, reason: '이벤트가 늘어나면 안 된다');
    });

    test('날짜 모드 5종 모두 왕복 후 정지한다', () async {
      // 종일 항목은 앱이 **local 자정**으로 저장한다(`_serializeDate` 규칙).
      // 구글의 종일 이벤트도 시간대 없는 날짜라 왕복 시 local 로 돌아온다.
      final variants = <String, Todo>{
        '하루종일': make(id: 'a', dueAt: DateTime(2026, 8, 20), isAllDay: true),
        '시작시간': make(id: 'b', dueAt: DateTime.utc(2026, 8, 20, 9)),
        '마감시간': make(
          id: 'c',
          dueAt: DateTime.utc(2026, 8, 20, 18),
          timeAnchor: 'end',
        ),
        '기간(시간)': make(
          id: 'd',
          dueAt: DateTime.utc(2026, 8, 21, 9),
          endAt: DateTime.utc(2026, 8, 21, 18),
        ),
        '기간(종일)': make(
          id: 'e',
          dueAt: DateTime(2026, 8, 22),
          endAt: DateTime(2026, 8, 24),
          isAllDay: true,
        ),
      };
      for (final t in variants.values) {
        await uiRepo.upsert(t);
      }

      await cycle();
      await cycle();

      expect(await queueLength(), 0);
      expect(gateway.liveEvents(cal).length, 5);

      // 모드가 왕복에서 변질되지 않았는지 — 되읽은 값이 원본과 같아야 한다.
      for (final entry in variants.entries) {
        final saved = await uiRepo.getById(entry.value.id);
        expect(
          saved!.dateMode,
          entry.value.dateMode,
          reason: '${entry.key} 모드가 왕복에서 변질됐다',
        );
        expect(saved.dueAt, entry.value.dueAt, reason: '${entry.key} 시각 변질');
        expect(saved.endAt, entry.value.endAt, reason: '${entry.key} 종료 변질');
      }
    });

    test('앱에서 수정해도 한 번만 반영되고 멈춘다', () async {
      await uiRepo.upsert(make());
      await cycle();

      final saved = await uiRepo.getById('todo-1');
      clock = clock.add(const Duration(minutes: 10));
      await uiRepo.upsert(saved!.copyWith(title: '제목 변경', updatedAt: clock));
      expect(await queueLength(), 1);

      await cycle();
      expect(gateway.eventById(cal, saved.calendarEventId!)!.summary, '제목 변경');

      await cycle();
      expect(await queueLength(), 0, reason: '반영 후 추가 작업이 생기면 루프다');
    });

    test('캘린더에서 수정한 내용이 앱에 반영된 뒤에도 멈춘다', () async {
      await uiRepo.upsert(make());
      await cycle();
      final eventId = (await uiRepo.getById('todo-1'))!.calendarEventId!;

      // 사람이 구글 캘린더에서 제목을 고쳤다.
      clock = clock.add(const Duration(minutes: 30));
      final edited = gateway.eventById(cal, eventId)!..summary = '캘린더에서 고침';
      gateway.seedEvent(cal, edited);

      await cycle();
      expect((await uiRepo.getById('todo-1'))!.title, '캘린더에서 고침');

      await cycle();
      expect(await queueLength(), 0, reason: '되받은 내용을 다시 올리면 루프다');
      expect(gateway.liveEvents(cal).length, 1);
    });

    test('완료 토글도 한 번만 반영된다', () async {
      await uiRepo.upsert(make());
      await cycle();

      final saved = await uiRepo.getById('todo-1');
      clock = clock.add(const Duration(minutes: 5));
      await uiRepo.upsert(saved!.copyWith(doneAt: clock, updatedAt: clock));

      await cycle();
      expect(gateway.eventById(cal, saved.calendarEventId!)!.colorId, '8');

      await cycle();
      expect(await queueLength(), 0);
    });
  });

  group('정렬·이동은 캘린더를 건드리지 않는다', () {
    test('순서만 바꾸면 API 호출이 늘지 않는다', () async {
      await uiRepo.upsert(make());
      await cycle();
      final callsBefore = gateway.callCount(CalendarOp.updateEvent);

      final saved = await uiRepo.getById('todo-1');
      for (var i = 0; i < 5; i++) {
        await uiRepo.upsert(saved!.copyWith(sortOrder: i));
      }

      expect(await queueLength(), 0);
      await cycle();
      expect(gateway.callCount(CalendarOp.updateEvent), callsBefore);
    });
  });

  group('삭제', () {
    test('앱에서 지우면 이벤트도 사라지고 큐가 비워진다', () async {
      await uiRepo.upsert(make());
      await cycle();

      await uiRepo.deleteById('todo-1');
      await cycle();

      expect(gateway.liveEvents(cal), isEmpty);
      expect(await queueLength(), 0);

      await cycle();
      expect(await queueLength(), 0);
    });

    test('날짜를 지우면 이벤트가 사라지고 링크도 정리된다', () async {
      await uiRepo.upsert(make());
      await cycle();

      final saved = await uiRepo.getById('todo-1');
      clock = clock.add(const Duration(minutes: 5));
      await uiRepo.upsert(saved!.copyWith(dueAt: null, updatedAt: clock));

      await cycle();

      expect(gateway.liveEvents(cal), isEmpty);
      final after = await uiRepo.getById('todo-1');
      expect(after!.calendarEventId, isNull, reason: '끊어진 링크가 남으면 안 된다');
      expect(await queueLength(), 0);
    });
  });
}
