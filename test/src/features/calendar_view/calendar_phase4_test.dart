import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_day_cell.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_providers.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_screen.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/todo_detail/todo_detail_screen.dart';
import 'package:solo_todo/src/ui/inspector.dart';

/// UX 개선 Phase 4 — 캘린더 (개선안 §4-7).
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
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() async => db.close());

  Future<({InspectorController inspector, MemoryUiPrefsStore prefs})> mount(
    WidgetTester tester, {
    List<Todo> seed = const [],
    FormFactor form = FormFactor.desktop,
    Size size = const Size(1300, 1000),
    MemoryUiPrefsStore? prefs,
  }) async {
    AppPlatform.debugFormFactorOverride = form;
    addTearDown(() => AppPlatform.debugFormFactorOverride = null);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final t in seed) {
      await db.todosDao.upsert(t);
    }
    final inspector = InspectorController();
    final store = prefs ?? MemoryUiPrefsStore();
    Widget body = const CalendarScreen();
    if (form == FormFactor.desktop) {
      body = InspectorScope(controller: inspector, child: body);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowProvider.overrideWithValue(() => now),
          recurrenceMaterializerProvider.overrideWith((_) {}),
          allTodosProvider.overrideWith((_) => Stream.value(seed)),
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
          uiPrefsStoreProvider.overrideWithValue(store),
        ],
        child: MaterialApp(home: Scaffold(body: body)),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    return (inspector: inspector, prefs: store);
  }

  Finder cell(DateTime d) =>
      find.byKey(ValueKey('calendar-cell-${calendarDateKey(d)}'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('세그먼트 이름은 [달력 | 타임라인]', (tester) async {
    await mount(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('calendar-segment-list')),
        matching: find.text('타임라인'),
      ),
      findsOneWidget,
    );
    expect(find.text('목록'), findsNothing);
  });

  testWidgets('달력 칩 글자는 12px — 10px 은 읽기 어려웠다', (tester) async {
    await mount(
      tester,
      seed: [make(id: 'a', title: '세금계산서', dueAt: DateTime(2026, 8, 15))],
    );
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('calendar-chip-todo:a')),
        matching: find.text('세금계산서'),
      ),
    );
    expect(text.style?.fontSize, 12);
  });

  testWidgets('칩에 마우스를 올리면 전체 제목·시각 툴팁', (tester) async {
    await mount(
      tester,
      seed: [
        make(
          id: 'a',
          title: '분기 결산 보고',
          dueAt: DateTime(2026, 8, 15, 14, 30),
          isAllDay: false,
        ),
      ],
    );
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.byKey(const ValueKey('calendar-chip-todo:a')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, '분기 결산 보고 · 14:30');

    // 마우스를 올리면 실제로 뜬다.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('calendar-chip-todo:a'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('분기 결산 보고 · 14:30'), findsOneWidget);
  });

  group('격자 칩 드래그', () {
    testWidgets('칩을 다른 날 칸에 놓으면 날짜가 바뀌고, 되돌리기로 원래대로', (tester) async {
      await mount(
        tester,
        seed: [make(id: 'a', title: '세금계산서', dueAt: DateTime(2026, 8, 15))],
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('calendar-chip-todo:a'))),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(cell(DateTime(2026, 8, 20))));
      await tester.pump();
      await gesture.up();
      await settle(tester);

      expect((await db.todosDao.getById('a'))!.dueAt, DateTime(2026, 8, 20));
      expect(find.textContaining('8월 20일 (목)'), findsWidgets);

      await tester.tap(find.text('되돌리기'));
      await settle(tester);
      expect((await db.todosDao.getById('a'))!.dueAt, DateTime(2026, 8, 15));
    });

    testWidgets('가장자리 칸(토요일)에 놓아도 달 넘김 띠가 드롭을 삼키지 않는다', (tester) async {
      await mount(
        tester,
        seed: [make(id: 'a', title: '세금계산서', dueAt: DateTime(2026, 8, 15))],
      );
      // 8/22(토) 칸의 오른쪽 끝 — 달 넘김 띠가 걸쳐 있는 자리.
      final target = tester.getTopRight(cell(DateTime(2026, 8, 22)));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('calendar-chip-todo:a'))),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.moveTo(target + const Offset(-3, 30));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await settle(tester);
      expect((await db.todosDao.getById('a'))!.dueAt, DateTime(2026, 8, 22));
    });

    testWidgets('데스크탑 칩 위 길게 누르기도 칸의 "이 날짜로 추가" 로 간다', (tester) async {
      await mount(
        tester,
        seed: [make(id: 'a', title: '세금계산서', dueAt: DateTime(2026, 8, 20))],
      );
      await tester.longPress(
        find.byKey(const ValueKey('calendar-chip-todo:a')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AddTodoSheet), findsOneWidget);
    });

    testWidgets('칩을 그냥 클릭하면 드래그가 아니라 그 날 선택', (tester) async {
      await mount(
        tester,
        seed: [make(id: 'a', title: '세금계산서', dueAt: DateTime(2026, 8, 20))],
      );
      await tester.tap(find.byKey(const ValueKey('calendar-chip-todo:a')));
      await tester.pump();
      expect(
        tester.widget<CalendarDayCell>(cell(DateTime(2026, 8, 20))).isSelected,
        isTrue,
      );
    });
  });

  group('칸 클릭', () {
    testWidgets('같은 칸을 두 번 클릭하면 그 날짜로 새 할 일 시트', (tester) async {
      await mount(tester);
      await tester.tap(cell(DateTime(2026, 8, 21)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(cell(DateTime(2026, 8, 21)));
      await tester.pumpAndSettle();

      final sheet = tester.widget<AddTodoSheet>(find.byType(AddTodoSheet));
      expect(sheet.initialDueAt, DateTime(2026, 8, 21));
    });

    testWidgets('한 번 클릭은 곧바로 선택만 (시트 없음)', (tester) async {
      await mount(tester);
      await tester.tap(cell(DateTime(2026, 8, 21)));
      await tester.pumpAndSettle();
      expect(find.byType(AddTodoSheet), findsNothing);
      expect(find.text('8월 21일 (금)'), findsOneWidget);
    });

    testWidgets('우클릭하면 칸 메뉴 — "…에 추가" / "오늘로 이동"', (tester) async {
      await mount(tester);
      await tester.tap(
        cell(DateTime(2026, 8, 21)),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('8월 21일 (금)에 추가'), findsOneWidget);
      expect(find.text('오늘로 이동'), findsOneWidget);

      await tester.tap(find.text('8월 21일 (금)에 추가'));
      await tester.pumpAndSettle();
      expect(find.byType(AddTodoSheet), findsOneWidget);
    });

    testWidgets('선택한 날짜는 셸이 읽을 수 있게 보관된다 (⌘N 기본값)', (tester) async {
      await mount(tester);
      await tester.tap(cell(DateTime(2026, 8, 25)));
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CalendarScreen)),
      );
      expect(
        container.read(calendarSelectionProvider).selectedDay,
        DateTime(2026, 8, 25),
      );
    });
  });

  group('선택일 목록 탭 = 상세', () {
    testWidgets('데스크탑은 오른쪽 인스펙터로 연다 (편집 시트 아님)', (tester) async {
      final m = await mount(
        tester,
        seed: [make(id: 'a', title: '세금계산서', dueAt: DateTime(2026, 8, 15))],
      );
      await tester.tap(
        find.byKey(const ValueKey('calendar-panel-tile-todo:a')),
      );
      await tester.pumpAndSettle();
      expect(m.inspector.current?.id, 'a');
      expect(find.byType(AddTodoSheet), findsNothing);
    });

    testWidgets('폰은 상세 화면으로 간다', (tester) async {
      await mount(
        tester,
        form: FormFactor.mobile,
        size: const Size(420, 900),
        seed: [make(id: 'a', title: '세금계산서', dueAt: DateTime(2026, 8, 15))],
      );
      await tester.tap(
        find.byKey(const ValueKey('calendar-panel-tile-todo:a')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetailScreen), findsOneWidget);
      // 상세 화면의 DB 구독(drift 타이머)을 정리하고 끝낸다.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('데스크탑 패널 폭', () {
    testWidgets('경계를 끌면 폭이 바뀌고 저장된다', (tester) async {
      final m = await mount(tester);
      final before = tester
          .getSize(find.byKey(const ValueKey('calendar-panel-header')))
          .width;
      await tester.drag(
        find.byKey(const ValueKey('calendar-panel-resizer')),
        const Offset(-80, 0),
      );
      await tester.pumpAndSettle();
      final after = tester
          .getSize(find.byKey(const ValueKey('calendar-panel-header')))
          .width;
      expect(after, greaterThan(before + 40));
      expect(m.prefs.data[calendarPanelWidthKey], isNotEmpty);
    });

    testWidgets('패널 접힘은 다시 열어도 유지된다', (tester) async {
      final prefs = MemoryUiPrefsStore();
      await mount(tester, prefs: prefs);
      await tester.tap(find.byKey(const ValueKey('calendar-panel-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('calendar-panel-header')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await mount(tester, prefs: prefs);
      expect(find.byKey(const ValueKey('calendar-panel-header')), findsNothing);
    });
  });

  group('빈 날 안내', () {
    testWidgets('"날짜 없음" 항목이 없으면 서랍을 가리키지 않는다', (tester) async {
      await mount(tester);
      expect(find.textContaining('날짜 없음'), findsNothing);
      expect(find.textContaining('두 번 클릭'), findsOneWidget);
    });

    testWidgets('"날짜 없음" 항목이 있으면 끌어다 놓기를 안내한다', (tester) async {
      await mount(
        tester,
        seed: [make(id: 'u', title: '언젠가')],
      );
      expect(find.textContaining('"날짜 없음"에서 끌어다'), findsOneWidget);
    });
  });

  testWidgets('폰 칸에서 넘친 점은 "+N" 으로 개수를 보인다', (tester) async {
    await mount(
      tester,
      form: FormFactor.mobile,
      size: const Size(420, 900),
      seed: [
        for (var i = 0; i < 6; i++)
          make(id: 'e$i', title: '일$i', dueAt: DateTime(2026, 8, 15)),
      ],
    );
    expect(find.text('+2'), findsOneWidget);
  });

  group('타임라인', () {
    testWidgets('"이후" 는 기본 접힘, 머리를 누르면 펼친다', (tester) async {
      await mount(
        tester,
        seed: [
          make(id: 'far', title: '먼 일정', dueAt: DateTime(2026, 10, 1)),
          make(id: 'near', title: '오늘 일정', dueAt: DateTime(2026, 8, 15)),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('calendar-segment-list')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('timeline-tile-near')), findsOneWidget);
      expect(find.byKey(const ValueKey('timeline-tile-far')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('timeline-bucket-later')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('timeline-tile-far')), findsOneWidget);
    });

    testWidgets('타임라인을 보는 동안은 선택일을 ⌘N 기본값으로 넘기지 않는다', (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('calendar-segment-list')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CalendarScreen)),
      );
      expect(container.read(calendarSelectionProvider).selectedDay, isNull);
    });
  });
}
