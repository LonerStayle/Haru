import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar/google_auth_service.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_entry.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_providers.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_screen.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';

/// 구글 이벤트의 **화면 표시**. 네트워크는 타지 않고 조회 provider 를 override 한다.
void main() {
  final now = DateTime(2026, 8, 15, 12);

  GoogleEventEntry meeting({
    String id = 'g1',
    String title = '외부 미팅',
    DateTime? start,
    DateTime? end,
    bool isAllDay = false,
  }) => GoogleEventEntry(
    id: id,
    title: title,
    start: start ?? DateTime(2026, 8, 15, 14),
    end: end ?? DateTime(2026, 8, 15, 15),
    isAllDay: isAllDay,
  );

  Future<void> mount(
    WidgetTester tester, {
    List<GoogleEventEntry> events = const [],
    bool available = true,
    List<Todo> todos = const [],
  }) async {
    AppPlatform.debugFormFactorOverride = FormFactor.desktop;
    addTearDown(() => AppPlatform.debugFormFactorOverride = null);
    await tester.binding.setSurfaceSize(const Size(1300, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nowProvider.overrideWithValue(() => now),
          recurrenceMaterializerProvider.overrideWith((_) {}),
          allTodosProvider.overrideWith((_) => Stream.value(todos)),
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
          googleCalendarAvailableProvider.overrideWithValue(available),
          googleEventsProvider.overrideWith((ref, range) async => events),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const Scaffold(body: CalendarScreen()),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  group('표시', () {
    testWidgets('이벤트가 달력 칸과 선택일 패널에 함께 그려진다', (tester) async {
      await mount(tester, events: [meeting()]);

      expect(
        find.byKey(const ValueKey('calendar-chip-gcal:g1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('calendar-panel-tile-gcal:g1')),
        findsOneWidget,
      );
      expect(find.text('외부 미팅'), findsWidgets);
    });

    testWidgets('읽기 전용 — 체크 원이 없고 Google 표시가 붙는다', (tester) async {
      await mount(tester, events: [meeting()]);
      expect(
        find.byKey(const ValueKey('calendar-panel-check-gcal:g1')),
        findsNothing,
      );
      expect(find.textContaining('Google'), findsOneWidget);
    });

    testWidgets('여러 날 이벤트는 기간 막대로 그려진다', (tester) async {
      await mount(
        tester,
        events: [
          meeting(
            id: 'g2',
            title: '휴가',
            start: DateTime(2026, 8, 17),
            end: DateTime(2026, 8, 19),
            isAllDay: true,
          ),
        ],
      );
      expect(
        find.byKey(const ValueKey('calendar-bar-gcal:g2')),
        findsOneWidget,
      );
    });

    testWidgets('로컬 할 일과 나란히 보인다', (tester) async {
      await mount(
        tester,
        events: [meeting()],
        todos: [
          Todo(
            id: 'a',
            title: '세금계산서',
            category: Category.work,
            dueAt: DateTime(2026, 8, 15),
            isAllDay: true,
            createdAt: DateTime(2026, 1, 1),
            updatedAt: DateTime(2026, 1, 1),
          ),
        ],
      );
      expect(
        find.byKey(const ValueKey('calendar-panel-tile-todo:a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('calendar-panel-tile-gcal:g1')),
        findsOneWidget,
      );
    });
  });

  group('표시 토글', () {
    testWidgets('연동이 구성돼 있으면 토글이 보이고 기본은 켜짐', (tester) async {
      await mount(tester, events: [meeting()]);
      expect(
        find.byKey(const ValueKey('calendar-google-toggle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('calendar-chip-gcal:g1')),
        findsOneWidget,
      );
    });

    testWidgets('끄면 이벤트가 사라지고 다시 켜면 돌아온다', (tester) async {
      await mount(tester, events: [meeting()]);

      await tester.tap(find.byKey(const ValueKey('calendar-google-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('calendar-chip-gcal:g1')), findsNothing);
      expect(
        find.byKey(const ValueKey('calendar-panel-tile-gcal:g1')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('calendar-google-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('calendar-chip-gcal:g1')),
        findsOneWidget,
      );
    });

    testWidgets('연동이 없으면 토글 자체를 숨긴다', (tester) async {
      await mount(tester, available: false);
      expect(
        find.byKey(const ValueKey('calendar-google-toggle')),
        findsNothing,
      );
    });

    testWidgets('연동이 없으면 이벤트도 안 그린다 (기본 off)', (tester) async {
      await mount(tester, events: [meeting()], available: false);
      expect(find.byKey(const ValueKey('calendar-chip-gcal:g1')), findsNothing);
    });
  });

  group('실패 내성', () {
    testWidgets('조회가 실패해도 로컬 할 일은 그대로 보인다', (tester) async {
      AppPlatform.debugFormFactorOverride = FormFactor.desktop;
      addTearDown(() => AppPlatform.debugFormFactorOverride = null);
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            nowProvider.overrideWithValue(() => now),
            recurrenceMaterializerProvider.overrideWith((_) {}),
            allTodosProvider.overrideWith(
              (_) => Stream.value([
                Todo(
                  id: 'a',
                  title: '세금계산서',
                  category: Category.work,
                  dueAt: DateTime(2026, 8, 15),
                  isAllDay: true,
                  createdAt: DateTime(2026, 1, 1),
                  updatedAt: DateTime(2026, 1, 1),
                ),
              ]),
            ),
            categoriesProvider.overrideWith(
              (_) => Stream.value(Category.builtinSeeds),
            ),
            groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
            googleCalendarAvailableProvider.overrideWithValue(true),
            googleEventsProvider.overrideWith(
              (ref, range) async => throw Exception('network down'),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.mobileLight(),
            home: const Scaffold(body: CalendarScreen()),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }

      expect(
        find.byKey(const ValueKey('calendar-panel-tile-todo:a')),
        findsOneWidget,
        reason: '구글이 죽어도 캘린더는 로컬만으로 정상 동작해야 한다',
      );
    });
  });
}
