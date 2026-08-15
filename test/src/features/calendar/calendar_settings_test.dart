import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solo_todo/src/features/calendar/calendar_settings.dart';

/// 인메모리 저장소 — Notifier 로직(복원/사용자 우선/저장 실패 무시)을 shared_preferences
/// 플랫폼 채널 없이 테스트한다.
class _FakeStore implements CalendarSettingsPreference {
  _FakeStore({CalendarSettings? stored})
    : stored = stored ?? const CalendarSettings();

  CalendarSettings stored;
  int saveCount = 0;

  @override
  Future<CalendarSettings> load() async => stored;

  @override
  Future<void> save(CalendarSettings settings) async {
    stored = settings;
    saveCount++;
  }

  @override
  Future<void> setSyncToken(String calendarId, String token) async {
    final tokens = Map<String, String>.of(stored.syncTokens)
      ..[calendarId] = token;
    stored = stored.copyWith(syncTokens: tokens);
  }

  @override
  Future<void> clearSyncToken(String calendarId) async {
    final tokens = Map<String, String>.of(stored.syncTokens)
      ..remove(calendarId);
    stored = stored.copyWith(syncTokens: tokens);
  }
}

class _ThrowingStore implements CalendarSettingsPreference {
  @override
  Future<CalendarSettings> load() async => throw StateError('저장소 없음');

  @override
  Future<void> save(CalendarSettings settings) async =>
      throw StateError('저장소 없음');

  @override
  Future<void> setSyncToken(String calendarId, String token) async =>
      throw StateError('저장소 없음');

  @override
  Future<void> clearSyncToken(String calendarId) async =>
      throw StateError('저장소 없음');
}

void main() {
  ProviderContainer containerWith(CalendarSettingsPreference store) {
    final container = ProviderContainer(
      overrides: [calendarSettingsPreferenceProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('CalendarSettingsNotifier', () {
    test('저장된 값이 없으면 기본값(쓰기=primary, 읽기=[primary], autoSync=true)', () async {
      final container = containerWith(_FakeStore());

      // 복원 전 초기값도 이미 기본값이다 (build() 가 동기로 반환).
      final initial = container.read(calendarSettingsProvider);
      expect(initial.connected, isFalse);
      expect(initial.writeCalendarId, 'primary');
      expect(initial.readCalendarIds, ['primary']);
      expect(initial.categoryMap, isEmpty);
      expect(initial.defaultCategoryId, isEmpty);
      expect(initial.importInvited, isFalse);
      expect(initial.autoSync, isTrue);
      expect(initial.syncTokens, isEmpty);
      expect(initial.lastSyncedAt, isNull);
      expect(initial.defaultAddToCalendar, isFalse);

      await container.read(calendarSettingsProvider.notifier).restored;

      expect(
        container.read(calendarSettingsProvider).writeCalendarId,
        'primary',
      );
    });

    test('저장된 설정을 앱 시작 시 복원한다', () async {
      final store = _FakeStore(
        stored: CalendarSettings(
          connected: true,
          writeCalendarId: 'work@group.calendar.google.com',
          readCalendarIds: const ['primary', 'work@group.calendar.google.com'],
          categoryMap: const {'primary': 'cat-1'},
          defaultCategoryId: 'cat-1',
          importInvited: true,
          autoSync: false,
          syncTokens: const {'primary': 'token-abc'},
          lastSyncedAt: DateTime.utc(2026, 8, 15, 9, 30),
          defaultAddToCalendar: true,
        ),
      );
      final container = containerWith(store);

      await container.read(calendarSettingsProvider.notifier).restored;

      final restored = container.read(calendarSettingsProvider);
      expect(restored.connected, isTrue);
      expect(restored.writeCalendarId, 'work@group.calendar.google.com');
      expect(restored.readCalendarIds, [
        'primary',
        'work@group.calendar.google.com',
      ]);
      expect(restored.categoryMap, {'primary': 'cat-1'});
      expect(restored.defaultCategoryId, 'cat-1');
      expect(restored.importInvited, isTrue);
      expect(restored.autoSync, isFalse);
      expect(restored.syncTokens, {'primary': 'token-abc'});
      expect(restored.lastSyncedAt, DateTime.utc(2026, 8, 15, 9, 30));
      expect(restored.defaultAddToCalendar, isTrue);
    });

    test('update 하면 상태가 바뀌고 전체가 저장된다', () async {
      final store = _FakeStore();
      final container = containerWith(store);
      await container.read(calendarSettingsProvider.notifier).restored;

      await container
          .read(calendarSettingsProvider.notifier)
          .update((c) => c.copyWith(autoSync: false, connected: true));

      expect(container.read(calendarSettingsProvider).autoSync, isFalse);
      expect(container.read(calendarSettingsProvider).connected, isTrue);
      expect(store.stored.autoSync, isFalse);
      expect(store.saveCount, 1);
    });

    test('setSyncToken / clearSyncToken 은 그 캘린더 항목만 바꾼다', () async {
      final store = _FakeStore(
        stored: const CalendarSettings(
          syncTokens: {'primary': 'old-token', 'work': 'work-token'},
        ),
      );
      final container = containerWith(store);
      await container.read(calendarSettingsProvider.notifier).restored;

      await container
          .read(calendarSettingsProvider.notifier)
          .setSyncToken('primary', 'new-token');

      expect(container.read(calendarSettingsProvider).syncTokens, {
        'primary': 'new-token',
        'work': 'work-token',
      });

      await container
          .read(calendarSettingsProvider.notifier)
          .clearSyncToken('work');

      expect(container.read(calendarSettingsProvider).syncTokens, {
        'primary': 'new-token',
      });
    });

    test('복원이 늦게 끝나도 그 사이 사용자가 바꾼 값을 덮어쓰지 않는다', () async {
      final store = _FakeStore(stored: const CalendarSettings(autoSync: false));
      final container = containerWith(store);
      final notifier = container.read(calendarSettingsProvider.notifier);

      // 저장된 값(autoSync=false)이 도착하기 전에 사용자가 직접 켬.
      await notifier.update((c) => c.copyWith(autoSync: true));
      expect(container.read(calendarSettingsProvider).autoSync, isTrue);

      await notifier.restored;

      expect(container.read(calendarSettingsProvider).autoSync, isTrue);
    });

    test('저장소가 실패해도 앱은 기본값으로 계속 동작한다', () async {
      final container = ProviderContainer(
        overrides: [
          calendarSettingsPreferenceProvider.overrideWithValue(
            _ThrowingStore(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(calendarSettingsProvider.notifier).restored;

      expect(
        container.read(calendarSettingsProvider).writeCalendarId,
        'primary',
      );
      // 저장 실패도 UI 로 전파되지 않는다 (상태는 바뀐다).
      await container
          .read(calendarSettingsProvider.notifier)
          .update((c) => c.copyWith(autoSync: false));
      expect(container.read(calendarSettingsProvider).autoSync, isFalse);
    });
  });

  group('SharedPrefsCalendarSettingsPreference', () {
    const preference = SharedPrefsCalendarSettingsPreference();

    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('최초 실행(저장된 값 없음) 시 기본값을 반환한다', () async {
      final loaded = await preference.load();

      expect(loaded.connected, isFalse);
      expect(loaded.writeCalendarId, 'primary');
      expect(loaded.readCalendarIds, ['primary']);
      expect(loaded.categoryMap, isEmpty);
      expect(loaded.defaultCategoryId, isEmpty);
      expect(loaded.importInvited, isFalse);
      expect(loaded.autoSync, isTrue);
      expect(loaded.syncTokens, isEmpty);
      expect(loaded.lastSyncedAt, isNull);
      expect(loaded.defaultAddToCalendar, isFalse);
    });

    test('save 후 load 하면 10개 키 전부 복원된다', () async {
      final settings = CalendarSettings(
        connected: true,
        writeCalendarId: 'work@group.calendar.google.com',
        readCalendarIds: const ['primary', 'work@group.calendar.google.com'],
        categoryMap: const {'primary': 'cat-1', 'work': 'cat-2'},
        defaultCategoryId: 'cat-1',
        importInvited: true,
        autoSync: false,
        syncTokens: const {'primary': 'token-abc'},
        lastSyncedAt: DateTime.utc(2026, 8, 15, 9, 30, 1),
        defaultAddToCalendar: true,
      );

      await preference.save(settings);
      final loaded = await preference.load();

      expect(loaded.connected, isTrue);
      expect(loaded.writeCalendarId, 'work@group.calendar.google.com');
      expect(loaded.readCalendarIds.toSet(), {
        'primary',
        'work@group.calendar.google.com',
      });
      expect(loaded.categoryMap, {'primary': 'cat-1', 'work': 'cat-2'});
      expect(loaded.defaultCategoryId, 'cat-1');
      expect(loaded.importInvited, isTrue);
      expect(loaded.autoSync, isFalse);
      expect(loaded.syncTokens, {'primary': 'token-abc'});
      expect(loaded.lastSyncedAt, DateTime.utc(2026, 8, 15, 9, 30, 1));
      expect(loaded.defaultAddToCalendar, isTrue);
    });

    test('readCalendarIds 저장 시 중복이 제거된다', () async {
      await preference.save(
        const CalendarSettings(readCalendarIds: ['primary', 'work', 'primary']),
      );

      final loaded = await preference.load();

      expect(loaded.readCalendarIds.toSet(), {'primary', 'work'});
      expect(loaded.readCalendarIds.length, 2);
    });

    test('setSyncToken / clearSyncToken 은 다른 설정을 건드리지 않고 맵 항목만 바꾼다', () async {
      await preference.save(
        const CalendarSettings(
          writeCalendarId: 'work',
          syncTokens: {'primary': 'old-token'},
        ),
      );

      await preference.setSyncToken('secondary', 'new-token');
      var loaded = await preference.load();
      expect(loaded.syncTokens, {
        'primary': 'old-token',
        'secondary': 'new-token',
      });
      expect(loaded.writeCalendarId, 'work'); // 건드리지 않음.

      await preference.clearSyncToken('primary');
      loaded = await preference.load();
      expect(loaded.syncTokens, {'secondary': 'new-token'});
    });

    test('깨진 JSON 리스트/맵이 저장돼 있어도 예외 없이 기본값으로 폴백한다', () async {
      SharedPreferences.setMockInitialValues({
        'gcal.readCalendarIds': '{not valid json]',
        'gcal.categoryMap': '["이건 map 이 아니라 list"]',
        'gcal.syncTokens': 'null',
        'gcal.lastSyncedAt': '이건 날짜가 아님',
      });

      // load() 는 어떤 경우에도 throw 하지 않는다.
      final loaded = await preference.load();

      expect(loaded.readCalendarIds, ['primary']);
      expect(loaded.categoryMap, isEmpty);
      expect(loaded.syncTokens, isEmpty);
      expect(loaded.lastSyncedAt, isNull);
    });

    test('타입이 다른 JSON(리스트 원소가 문자열이 아님)도 기본값으로 폴백한다', () async {
      SharedPreferences.setMockInitialValues({
        'gcal.readCalendarIds': '[1, 2, 3]',
        'gcal.categoryMap': '{"primary": 123}',
      });

      final loaded = await preference.load();

      expect(loaded.readCalendarIds, ['primary']);
      expect(loaded.categoryMap, isEmpty);
    });
  });
}
