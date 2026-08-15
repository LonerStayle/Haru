import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_day_cell.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_screen.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/timeline/timeline_screen.dart';

Todo make({
  required String id,
  String title = '할 일',
  DateTime? dueAt,
  bool isAllDay = true,
}) => Todo(
  id: id,
  title: title,
  category: Category.work,
  dueAt: dueAt,
  isAllDay: isAllDay,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  final now = DateTime(2026, 8, 15, 12);

  Future<void> mount(
    WidgetTester tester, {
    List<Todo> todos = const [],
    Size size = const Size(1200, 900),
    FormFactor form = FormFactor.desktop,
  }) async {
    AppPlatform.debugFormFactorOverride = form;
    addTearDown(() => AppPlatform.debugFormFactorOverride = null);
    await tester.binding.setSurfaceSize(size);
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
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const Scaffold(body: CalendarScreen()),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  Finder cell(DateTime d) =>
      find.byKey(ValueKey('calendar-cell-${calendarDateKey(d)}'));

  group('초기 상태', () {
    testWidgets('오늘이 속한 달을 열고 오늘을 선택한다', (tester) async {
      await mount(tester);
      expect(find.text('2026년 8월'), findsOneWidget);
      expect(find.text('8월 15일 (토)'), findsOneWidget);
      expect(
        tester.widget<CalendarDayCell>(cell(DateTime(2026, 8, 15))).isSelected,
        isTrue,
      );
    });

    testWidgets('기본 세그먼트는 [달력]', (tester) async {
      await mount(tester);
      expect(find.byKey(const ValueKey('calendar-grid-pager')), findsOneWidget);
      expect(find.byType(TimelineScreen), findsNothing);
    });
  });

  group('날짜 선택', () {
    testWidgets('날짜를 탭하면 선택일 패널 헤더가 바뀐다', (tester) async {
      await mount(tester);
      await tester.tap(cell(DateTime(2026, 8, 20)));
      await tester.pumpAndSettle();
      expect(find.text('8월 20일 (목)'), findsOneWidget);
    });

    testWidgets('선택일의 할 일이 패널에 나온다', (tester) async {
      await mount(
        tester,
        todos: [
          make(id: 'a', title: '세금계산서', dueAt: DateTime(2026, 8, 15)),
          make(id: 'b', title: '다른날', dueAt: DateTime(2026, 8, 20)),
        ],
      );
      expect(
        find.byKey(const ValueKey('calendar-panel-tile-todo:a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('calendar-panel-tile-todo:b')),
        findsNothing,
      );

      await tester.tap(cell(DateTime(2026, 8, 20)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('calendar-panel-tile-todo:b')),
        findsOneWidget,
      );
    });
  });

  group('월 이동', () {
    testWidgets('› 버튼으로 다음 달', (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('calendar-next-month')));
      await tester.pumpAndSettle();
      expect(find.text('2026년 9월'), findsOneWidget);
    });

    testWidgets('‹ 버튼으로 이전 달, 연 경계도 넘는다', (tester) async {
      await mount(tester);
      for (var i = 0; i < 8; i++) {
        await tester.tap(find.byKey(const ValueKey('calendar-prev-month')));
        await tester.pumpAndSettle();
      }
      expect(find.text('2025년 12월'), findsOneWidget);
    });

    testWidgets('"오늘" 버튼으로 복귀', (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('calendar-next-month')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-today-button')));
      await tester.pumpAndSettle();
      expect(find.text('2026년 8월'), findsOneWidget);
      expect(find.text('8월 15일 (토)'), findsOneWidget);
    });

    testWidgets('← / → 키로 달 이동, T 키로 오늘 복귀', (tester) async {
      await mount(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('2026년 9월'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('2026년 7월'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.pumpAndSettle();
      expect(find.text('2026년 8월'), findsOneWidget);
    });

    testWidgets('넘침 날짜를 탭하면 그 달로 따라 이동한다', (tester) async {
      await mount(tester);
      // 2026-09-05 는 8월 그리드의 마지막 칸.
      await tester.tap(cell(DateTime(2026, 9, 5)));
      await tester.pumpAndSettle();
      expect(find.text('2026년 9월'), findsOneWidget);
      expect(find.text('9월 5일 (토)'), findsOneWidget);
    });
  });

  group('세그먼트', () {
    testWidgets('[목록] 로 바꾸면 타임라인이, 다시 [달력] 이면 격자가 나온다', (tester) async {
      await mount(tester);

      await tester.tap(find.byKey(const ValueKey('calendar-segment-list')));
      await tester.pumpAndSettle();
      expect(find.byType(TimelineScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('calendar-grid-pager')), findsNothing);
      // embed 된 타임라인은 자기 제목을 다시 달지 않는다 (헤더가 이미 표시).
      expect(find.text('날짜가 정해진 할 일을 한눈에'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('calendar-segment-grid')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('calendar-grid-pager')), findsOneWidget);
      expect(find.byType(TimelineScreen), findsNothing);
    });

    testWidgets('세그먼트를 오가도 선택일이 유지된다', (tester) async {
      await mount(tester);
      await tester.tap(cell(DateTime(2026, 8, 20)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('calendar-segment-list')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-segment-grid')));
      await tester.pumpAndSettle();

      expect(find.text('8월 20일 (목)'), findsOneWidget);
    });
  });

  group('데스크탑 우측 패널 접기', () {
    testWidgets('토글로 접었다 폈다 — 접으면 선택일 패널이 사라진다', (tester) async {
      await mount(
        tester,
        todos: [make(id: 't1', dueAt: DateTime(2026, 8, 15))],
      );

      // 기본은 펼침 — 선택일 헤더가 보인다.
      expect(find.text('8월 15일 (토)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('calendar-panel-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('8월 15일 (토)'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('calendar-panel-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('8월 15일 (토)'), findsOneWidget);
    });

    testWidgets('접으면 격자가 패널 폭만큼 넓어진다', (tester) async {
      await mount(tester);
      final before = tester.getSize(cell(DateTime(2026, 8, 15))).width;

      await tester.tap(find.byKey(const ValueKey('calendar-panel-toggle')));
      await tester.pumpAndSettle();

      final after = tester.getSize(cell(DateTime(2026, 8, 15))).width;
      expect(after, greaterThan(before));
    });

    testWidgets('모바일에는 패널 토글이 없다', (tester) async {
      await mount(tester, form: FormFactor.mobile, size: const Size(420, 900));
      expect(find.byKey(const ValueKey('calendar-panel-toggle')), findsNothing);
    });
  });

  group('모바일 레이아웃', () {
    testWidgets('달력 접기 토글이 있고, 접으면 격자가 사라진다', (tester) async {
      await mount(tester, form: FormFactor.mobile, size: const Size(420, 900));
      expect(find.byKey(const ValueKey('calendar-grid-pager')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('calendar-collapse-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('calendar-grid-pager')), findsNothing);
      // 목록은 그대로 — 접기는 달력만 숨긴다.
      expect(find.text('8월 15일 (토)'), findsOneWidget);
    });

    testWidgets('데스크탑에는 접기 토글이 없다', (tester) async {
      await mount(tester);
      expect(
        find.byKey(const ValueKey('calendar-collapse-toggle')),
        findsNothing,
      );
    });

    testWidgets('모바일에는 ‹ › 대신 스와이프로 달을 넘긴다', (tester) async {
      await mount(tester, form: FormFactor.mobile, size: const Size(420, 900));
      // 헤더 폭을 아끼려고 모바일에선 화살표 버튼을 두지 않는다.
      expect(find.byKey(const ValueKey('calendar-prev-month')), findsNothing);
      expect(find.byKey(const ValueKey('calendar-next-month')), findsNothing);

      await tester.fling(
        find.byKey(const ValueKey('calendar-grid-pager')),
        const Offset(-400, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('2026년 9월'), findsOneWidget);
    });

    testWidgets('모바일 헤더가 좁은 폭에서도 넘치지 않는다', (tester) async {
      await mount(tester, form: FormFactor.mobile, size: const Size(360, 800));
      expect(tester.takeException(), isNull);
    });
  });
}
