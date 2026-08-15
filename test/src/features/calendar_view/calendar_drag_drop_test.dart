import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/recurrence.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_day_cell.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_screen.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';

/// 캘린더 드래그 앤 드롭 — "달력에서 항목을 끌어 날짜를 바꾼다" 의 통합 검증.
///
/// 데스크탑 폼팩터로 고정한다 (즉시 드래그라 테스트에서 다루기 단순하고,
/// 모바일은 같은 경로에 LongPressDraggable 만 갈아끼운 것이라 로직이 동일하다).
Todo make({
  required String id,
  String title = '할 일',
  DateTime? dueAt,
  DateTime? endAt,
  bool isAllDay = true,
  int sortOrder = 0,
}) => Todo(
  id: id,
  title: title,
  category: Category.work,
  dueAt: dueAt,
  endAt: endAt,
  isAllDay: isAllDay,
  sortOrder: sortOrder,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  final now = DateTime(2026, 8, 15, 12);
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() async => db.close());

  Future<void> mount(WidgetTester tester, List<Todo> seed) async {
    await tester.binding.setSurfaceSize(const Size(1300, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final t in seed) {
      await db.todosDao.upsert(t);
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
        ],
        child: MaterialApp(home: const Scaffold(body: CalendarScreen())),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  Finder cell(DateTime d) =>
      find.byKey(ValueKey('calendar-cell-${calendarDateKey(d)}'));

  /// [from] 위젯을 [to] 날짜 칸으로 끌어다 놓는다.
  Future<void> dragTo(WidgetTester tester, Finder from, DateTime to) async {
    final gesture = await tester.startGesture(tester.getCenter(from));
    // 드래그 시작 임계값을 넘긴 뒤 목표 칸 중앙으로.
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(cell(to)));
    await tester.pump();
    await gesture.up();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  group('선택일 패널 → 달력 칸', () {
    testWidgets('다른 날짜에 떨어뜨리면 dueAt 이 그 날짜로 바뀐다', (tester) async {
      await mount(tester, [
        make(id: 'a', title: '세금계산서', dueAt: DateTime(2026, 8, 15)),
      ]);

      await dragTo(
        tester,
        find.byKey(const ValueKey('calendar-panel-tile-todo:a')),
        DateTime(2026, 8, 20),
      );

      final saved = (await db.todosDao.getById('a'))!;
      expect(saved.dueAt, DateTime(2026, 8, 20));
    });

    testWidgets('시각은 보존된다 (날짜 부분만 교체)', (tester) async {
      await mount(tester, [
        make(id: 'a', dueAt: DateTime(2026, 8, 15, 14, 30), isAllDay: false),
      ]);

      await dragTo(
        tester,
        find.byKey(const ValueKey('calendar-panel-tile-todo:a')),
        DateTime(2026, 8, 20),
      );

      expect(
        (await db.todosDao.getById('a'))!.dueAt,
        DateTime(2026, 8, 20, 14, 30),
      );
    });

    testWidgets('sortOrder 는 바뀌지 않는다 (날짜 이동은 순서 조작이 아니다)', (tester) async {
      await mount(tester, [
        make(id: 'a', dueAt: DateTime(2026, 8, 15), sortOrder: 7),
        make(id: 'top', dueAt: DateTime(2026, 8, 15), sortOrder: 1),
      ]);

      await dragTo(
        tester,
        find.byKey(const ValueKey('calendar-panel-tile-todo:a')),
        DateTime(2026, 8, 20),
      );

      expect((await db.todosDao.getById('a'))!.sortOrder, 7);
    });

    testWidgets('기간 항목은 길이를 유지한 채 통째로 이동', (tester) async {
      await mount(tester, [
        make(
          id: 'trip',
          title: '출장',
          dueAt: DateTime(2026, 8, 15),
          endAt: DateTime(2026, 8, 17),
        ),
      ]);

      await dragTo(
        tester,
        find.byKey(const ValueKey('calendar-panel-tile-todo:trip')),
        DateTime(2026, 8, 20),
      );

      final saved = (await db.todosDao.getById('trip'))!;
      expect(saved.dueAt, DateTime(2026, 8, 20));
      expect(saved.endAt, DateTime(2026, 8, 22));
    });

    testWidgets('드롭 후 그 날짜가 선택된다 (결과를 눈으로 확인)', (tester) async {
      await mount(tester, [make(id: 'a', dueAt: DateTime(2026, 8, 15))]);

      await dragTo(
        tester,
        find.byKey(const ValueKey('calendar-panel-tile-todo:a')),
        DateTime(2026, 8, 20),
      );
      await tester.pumpAndSettle();

      expect(find.text('8월 20일 (목)'), findsOneWidget);
    });
  });

  group('"날짜 없음" 서랍 → 달력 칸', () {
    testWidgets('날짜가 없던 할 일에 그 날짜가 종일로 붙는다', (tester) async {
      await mount(tester, [make(id: 'u1', title: '블로그 글 쓰기', dueAt: null)]);

      await tester.tap(find.byKey(const ValueKey('calendar-undated-header')));
      await tester.pumpAndSettle();

      await dragTo(
        tester,
        find.byKey(const ValueKey('calendar-undated-tile-u1')),
        DateTime(2026, 8, 20),
      );

      final saved = (await db.todosDao.getById('u1'))!;
      expect(saved.dueAt, DateTime(2026, 8, 20));
      expect(saved.isAllDay, isTrue, reason: '시각을 모르므로 종일');
      expect(saved.dateMode, TodoDateMode.allDay);
    });
  });

  group('미래 반복 고스트 → 달력 칸', () {
    testWidgets('드롭하는 순간 그 회차가 실체화되고 새 날짜로 저장된다', (tester) async {
      final master =
          make(
            id: 'm1',
            title: '팀 회의',
            dueAt: DateTime(2026, 8, 1, 10),
            isAllDay: false,
          ).copyWith(
            seriesId: 'm1',
            recurrenceRule: const RecurrenceRule(
              freq: RecurrenceFreq.weekly,
            ).encode(),
            isSeriesMaster: true,
          );
      await mount(tester, [master]);

      // 8/22(토) 고스트를 선택일 패널에 띄운다.
      await tester.tap(cell(DateTime(2026, 8, 22)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('calendar-panel-tile-ghost:m1#20260822')),
        findsOneWidget,
      );

      await dragTo(
        tester,
        find.byKey(const ValueKey('calendar-panel-tile-ghost:m1#20260822')),
        DateTime(2026, 8, 25),
      );

      final created = (await db.todosDao.getById('m1#20260822'))!;
      expect(created.dueAt, DateTime(2026, 8, 25, 10));
      expect(created.isSeriesMaster, isFalse);
      // 마스터는 그대로 — 다른 회차는 예정 상태를 유지한다.
      expect(
        (await db.todosDao.getById('m1'))!.dueAt,
        DateTime(2026, 8, 1, 10),
      );
    });
  });

  group('무효한 드롭', () {
    testWidgets('원래 날짜에 다시 놓으면 아무것도 저장하지 않는다', (tester) async {
      final original = make(id: 'a', dueAt: DateTime(2026, 8, 15));
      await mount(tester, [original]);

      await dragTo(
        tester,
        find.byKey(const ValueKey('calendar-panel-tile-todo:a')),
        DateTime(2026, 8, 15),
      );

      final saved = (await db.todosDao.getById('a'))!;
      // drift 는 DateTime 을 UTC ISO 텍스트로 보관하므로 표현이 다를 수 있다 —
      // 같은 순간인지로 비교한다.
      expect(
        saved.updatedAt.isAtSameMomentAs(original.updatedAt),
        isTrue,
        reason: 'updatedAt 도 안 튄다',
      );
      expect(
        saved.dueAt!.isAtSameMomentAs(original.dueAt!),
        isTrue,
        reason: 'dueAt 도 그대로',
      );
    });
  });
}
