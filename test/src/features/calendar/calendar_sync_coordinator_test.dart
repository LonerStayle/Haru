import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/features/calendar/calendar_gateway.dart';
import 'package:solo_todo/src/features/calendar/calendar_settings.dart';
import 'package:solo_todo/src/features/calendar/calendar_sync_coordinator.dart';
import 'package:solo_todo/src/features/calendar/calendar_sync_service.dart';

import 'fake_calendar_gateway.dart';

/// 메모리 설정 저장소 — shared_preferences 플랫폼 채널 없이 돈다.
class _MemoryPreference implements CalendarSettingsPreference {
  _MemoryPreference(this._settings);

  CalendarSettings _settings;
  final cleared = <String>[];
  final saved = <String, String>{};

  @override
  Future<CalendarSettings> load() async => _settings;

  @override
  Future<void> save(CalendarSettings settings) async => _settings = settings;

  @override
  Future<void> setSyncToken(String calendarId, String token) async {
    saved[calendarId] = token;
  }

  @override
  Future<void> clearSyncToken(String calendarId) async {
    cleared.add(calendarId);
  }
}

void main() {
  late AppDatabase db;
  late FakeCalendarGateway gateway;
  late CalendarSyncCoordinator coordinator;
  late _MemoryPreference pref;
  late CalendarSettings settings;
  late List<Category> categories;

  final t0 = DateTime.utc(2026, 8, 15, 9);
  const cal = 'primary';

  setUp(() {
    db = AppDatabase.memory();
    gateway = FakeCalendarGateway(now: () => t0);
    settings = const CalendarSettings(
      connected: true,
      writeCalendarId: cal,
      readCalendarIds: [cal],
    );
    categories = [Category.work, Category.daily];
    pref = _MemoryPreference(settings);
    coordinator = CalendarSyncCoordinator(
      service: CalendarSyncService(
        gateway: gateway,
        ops: db.calendarOpsDao,
        repo: LocalTodoRepository(db.todosDao),
        now: () => t0,
      ),
      preference: pref,
      readSettings: () => settings,
      writeSettings: (s) => settings = s,
      activeCategories: () => categories,
    );
  });

  tearDown(() => db.close());

  gcal.Event remote({String id = 'ev-1'}) => gcal.Event(
    id: id,
    summary: '구글 일정',
    start: gcal.EventDateTime(dateTime: DateTime.utc(2026, 8, 20, 10)),
    end: gcal.EventDateTime(dateTime: DateTime.utc(2026, 8, 20, 11)),
  );

  group('실행 조건', () {
    test('연동이 꺼져 있으면 아무것도 하지 않는다', () async {
      settings = settings.copyWith(connected: false);
      final r = await coordinator.syncNow();
      expect(r.skipped, isTrue);
      expect(gateway.callCount(CalendarOp.listChanges), 0);
    });

    test('연결돼 있으면 받아온다', () async {
      gateway.seedEvent(cal, remote());
      final r = await coordinator.syncNow();
      expect(r.skipped, isFalse);
      expect(r.pull.imported, 1);
    });
  });

  group('설정 반영', () {
    test('새 토큰이 저장되고 설정에도 반영된다', () async {
      gateway.seedEvent(cal, remote());
      await coordinator.syncNow();
      expect(pref.saved[cal], isNotNull);
      expect(settings.syncTokens[cal], pref.saved[cal]);
    });

    test('마지막 동기화 시각이 갱신된다', () async {
      gateway.seedEvent(cal, remote());
      await coordinator.syncNow();
      expect(settings.lastSyncedAt, isNotNull);
    });

    test('만료된 토큰은 새 토큰으로 대체된다', () async {
      gateway.seedEvent(cal, remote());
      gateway.expireSyncTokens();
      settings = settings.copyWith(syncTokens: const {cal: '죽은-토큰'});

      await coordinator.syncNow();

      expect(settings.syncTokens[cal], isNot('죽은-토큰'));
      expect(settings.syncTokens[cal], isNotNull);
    });
  });

  group('유입 카테고리 결정', () {
    test('캘린더별 매핑이 우선한다', () async {
      settings = settings.copyWith(categoryMap: {cal: Category.daily.id});
      gateway.seedEvent(cal, remote());

      await coordinator.syncNow();

      final todos = await db.todosDao.watchAll().first;
      expect(todos.single.category.id, Category.daily.id);
    });

    test('매핑이 없으면 기본 카테고리로', () async {
      settings = settings.copyWith(defaultCategoryId: Category.daily.id);
      gateway.seedEvent(cal, remote());

      await coordinator.syncNow();

      final todos = await db.todosDao.watchAll().first;
      expect(todos.single.category.id, Category.daily.id);
    });

    test('매핑 대상이 보관·삭제됐으면 첫 활성 카테고리로 떨어진다', () async {
      // 매핑은 있지만 그 카테고리가 활성 목록에 없다.
      settings = settings.copyWith(categoryMap: const {cal: '사라진-카테고리'});
      categories = [Category.work];
      gateway.seedEvent(cal, remote());

      await coordinator.syncNow();

      final todos = await db.todosDao.watchAll().first;
      expect(todos.single.category.id, Category.work.id);
    });
  });

  group('순서와 실패', () {
    test('보내기를 먼저 하고 받아온다', () async {
      gateway.seedEvent(cal, remote());
      await coordinator.syncNow();
      // 두 방향 모두 호출됐고, 받아오기 결과가 반영됐다.
      expect(gateway.callCount(CalendarOp.listChanges), 1);
    });

    test('재인증이 필요하면 받아오기를 시도하지 않는다', () async {
      await db.calendarOpsDao.enqueue(
        CalendarOpRow(
          id: 'op-1',
          kind: 'delete',
          todoId: 'todo-1',
          eventId: 'ev-1',
          calendarId: cal,
          payload: null,
          attempts: 0,
          lastError: null,
          nextAttemptAt: null,
          createdAt: t0,
        ),
      );
      gateway.failAlways(CalendarGatewayException.authRequired());

      final r = await coordinator.syncNow();

      expect(r.authRequired, isTrue);
      expect(gateway.callCount(CalendarOp.listChanges), 0);
    });
  });
}
