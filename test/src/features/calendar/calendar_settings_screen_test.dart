import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/features/calendar/calendar_gateway.dart';
import 'package:solo_todo/src/features/calendar/calendar_settings.dart';
import 'package:solo_todo/src/features/calendar/calendar_settings_screen.dart';
import 'package:solo_todo/src/features/calendar/google_auth_service.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';

import 'fake_calendar_gateway.dart';

/// 인메모리 [CalendarSettingsPreference] — [calendar_settings_test.dart] 의
/// `_FakeStore` 와 동일한 역할. 이 화면 테스트는 저장된 최종값을 직접 검증하는
/// 것이 목표라 노출된 `stored`/`saveCount` 를 그대로 assert 에 쓴다.
class _FakePreference implements CalendarSettingsPreference {
  _FakePreference({CalendarSettings? stored})
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

/// [CalendarAuth] fake — 연결 해제(및 연결) 흐름 검증용. `authedClient` 는
/// 기본으로 성공(client 반환)하고, `signOutCalls` 로 [연결 해제] 가 실제로
/// signOut 을 호출했는지 센다.
class _FakeCalendarAuth implements CalendarAuth {
  _FakeCalendarAuth({this.authSucceeds = true});

  final bool authSucceeds;
  int signOutCalls = 0;
  int authedClientCalls = 0;

  @override
  Future<http.Client?> authedClient() async {
    authedClientCalls++;
    return authSucceeds ? http.Client() : null;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }
}

const _calendars = [
  CalendarInfo(
    id: 'primary',
    summary: '기본 캘린더',
    primary: true,
    accessRole: 'owner',
  ),
  CalendarInfo(id: 'family', summary: '가족', accessRole: 'writer'),
  CalendarInfo(id: 'holidays', summary: '대한민국의 휴일', accessRole: 'reader'),
];

void main() {
  Future<
    ({
      ProviderContainer container,
      _FakePreference store,
      _FakeCalendarAuth auth,
    })
  >
  pump(
    WidgetTester tester, {
    bool available = true,
    CalendarSettings? initialSettings,
    List<CalendarInfo> calendars = _calendars,
    List<Category> categories = Category.builtinSeeds,
    int pendingCount = 0,
    bool authSucceeds = true,
  }) async {
    final store = _FakePreference(
      stored: initialSettings ?? const CalendarSettings(),
    );
    final auth = _FakeCalendarAuth(authSucceeds: authSucceeds);
    final gateway = FakeCalendarGateway(calendars: calendars);

    // 연결 해제가 대기 큐를 비우므로 실제 DB 파일 대신 in-memory 를 물린다.
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [
        googleCalendarAvailableProvider.overrideWithValue(available),
        calendarAuthProvider.overrideWithValue(auth),
        calendarSettingsPreferenceProvider.overrideWithValue(store),
        calendarGatewayProvider.overrideWithValue(gateway),
        activeCategoriesProvider.overrideWithValue(AsyncData(categories)),
        appDatabaseProvider.overrideWithValue(db),
        calendarPendingOpsCountProvider.overrideWith(
          (ref) => Stream.value(pendingCount),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const CalendarSettingsScreen(),
        ),
      ),
    );
    await container.read(calendarSettingsProvider.notifier).restored;
    await tester.pumpAndSettle();

    return (container: container, store: store, auth: auth);
  }

  group('3 상태', () {
    testWidgets('키 없음 — 연결 UI 없이 안내만', (tester) async {
      await pump(tester, available: false);

      expect(find.text('Google Calendar 연동이 아직 설정되지 않았어요'), findsOneWidget);
      expect(find.byKey(const ValueKey('connect-button')), findsNothing);
      expect(find.byKey(const ValueKey('disconnect-button')), findsNothing);
    });

    testWidgets('미연결 — [Google 계정 연결] 버튼만', (tester) async {
      await pump(
        tester,
        initialSettings: const CalendarSettings(connected: false),
      );

      expect(find.byKey(const ValueKey('connect-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('disconnect-button')), findsNothing);
      expect(
        find.byKey(const ValueKey('write-calendar-dropdown')),
        findsNothing,
      );
    });

    testWidgets('연결됨 — 전체 UI 노출', (tester) async {
      await pump(
        tester,
        initialSettings: const CalendarSettings(connected: true),
      );

      expect(find.text('연결됨'), findsOneWidget);
      expect(find.byKey(const ValueKey('disconnect-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('connect-button')), findsNothing);
      expect(
        find.byKey(const ValueKey('write-calendar-dropdown')),
        findsOneWidget,
      );
      // 가져올 캘린더 3개 모두 체크박스로 노출.
      expect(
        find.byKey(const ValueKey('read-cal-checkbox-primary')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('read-cal-checkbox-family')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('read-cal-checkbox-holidays')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('import-invited-checkbox')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('auto-sync-checkbox')), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-now-button')), findsOneWidget);
    });

    testWidgets('읽기 전용 캘린더는 쓰기 드롭다운에서 제외', (tester) async {
      await pump(
        tester,
        initialSettings: const CalendarSettings(connected: true),
      );

      // 메뉴를 열기 전 각 캘린더 이름의 등장 횟수 — 셋 다 "가져올 캘린더" 목록에
      // 이미 1번씩 떠 있다 ('기본 캘린더' 는 쓰기 드롭다운 현재값으로 1번 더).
      final beforeFamily = find.text('가족').evaluate().length;
      final beforeHolidays = find.text('대한민국의 휴일').evaluate().length;

      await tester.tap(find.byKey(const ValueKey('write-calendar-dropdown')));
      await tester.pumpAndSettle();

      // 메뉴가 열리면 쓰기 가능한 캘린더만 후보 항목으로 추가된다 — '가족' 은
      // 늘고, 읽기 전용인 '대한민국의 휴일' 은 후보에 없어 그대로다.
      expect(find.text('가족').evaluate().length, beforeFamily + 1);
      expect(find.text('대한민국의 휴일').evaluate().length, beforeHolidays);
    });
  });

  group('저장 동작', () {
    testWidgets('쓰기 캘린더 선택이 설정에 저장된다', (tester) async {
      final result = await pump(
        tester,
        initialSettings: const CalendarSettings(connected: true),
      );

      await tester.tap(find.byKey(const ValueKey('write-calendar-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('가족').last);
      await tester.pumpAndSettle();

      expect(result.store.stored.writeCalendarId, 'family');
      expect(
        result.container.read(calendarSettingsProvider).writeCalendarId,
        'family',
      );
    });

    testWidgets('읽기 캘린더 체크·해제가 설정에 저장된다', (tester) async {
      final result = await pump(
        tester,
        initialSettings: const CalendarSettings(
          connected: true,
          readCalendarIds: ['primary'],
        ),
      );

      // family 를 체크 → 추가됨.
      await tester.tap(find.byKey(const ValueKey('read-cal-checkbox-family')));
      await tester.pumpAndSettle();
      expect(
        result.store.stored.readCalendarIds,
        containsAll(['primary', 'family']),
      );

      // primary 를 해제 → 제거됨.
      await tester.tap(find.byKey(const ValueKey('read-cal-checkbox-primary')));
      await tester.pumpAndSettle();
      expect(result.store.stored.readCalendarIds, isNot(contains('primary')));
      expect(result.store.stored.readCalendarIds, contains('family'));
    });

    testWidgets('카테고리 매핑 변경이 설정에 저장된다', (tester) async {
      final result = await pump(
        tester,
        initialSettings: const CalendarSettings(connected: true),
      );

      await tester.tap(find.byKey(const ValueKey('read-cal-category-family')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('일상').last);
      await tester.pumpAndSettle();

      expect(result.store.stored.categoryMap['family'], 'daily');
    });
  });

  group('연결 해제', () {
    testWidgets(
      'signOut 호출 + connected=false + syncTokens 비움 + lastSyncedAt clear + 캘린더 선택 보존',
      (tester) async {
        final result = await pump(
          tester,
          initialSettings: CalendarSettings(
            connected: true,
            writeCalendarId: 'family',
            readCalendarIds: const ['primary', 'family'],
            categoryMap: const {'family': 'daily'},
            syncTokens: const {'primary': 'tok-1'},
            lastSyncedAt: DateTime.utc(2026, 8, 15, 14, 20),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('disconnect-button')));
        await tester.pumpAndSettle();

        expect(result.auth.signOutCalls, 1);

        final saved = result.store.stored;
        expect(saved.connected, isFalse);
        expect(saved.syncTokens, isEmpty);
        expect(saved.lastSyncedAt, isNull);
        // 캘린더 선택 · 카테고리 매핑은 보존.
        expect(saved.writeCalendarId, 'family');
        expect(saved.readCalendarIds, containsAll(['primary', 'family']));
        expect(saved.categoryMap, {'family': 'daily'});

        // 미연결 화면으로 전환됐는지도 확인.
        expect(find.byKey(const ValueKey('connect-button')), findsOneWidget);
      },
    );
  });
}
