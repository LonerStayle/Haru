import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/recurrence.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_day_panel.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_entry.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';

Todo make({
  required String id,
  String title = '할 일',
  Category? category,
  DateTime? dueAt,
  DateTime? endAt,
  bool isAllDay = false,
  DateTime? doneAt,
  TodoType type = TodoType.task,
}) => Todo(
  id: id,
  title: title,
  category: category ?? Category.work,
  dueAt: dueAt,
  endAt: endAt,
  isAllDay: isAllDay,
  doneAt: doneAt,
  type: type,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  final date = DateTime(2026, 8, 15);
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() async => db.close());

  Future<void> mount(
    WidgetTester tester, {
    required List<CalendarEntry> entries,
    List<Todo> seed = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(700, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final t in seed) {
      await db.todosDao.upsert(t);
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowProvider.overrideWithValue(() => DateTime(2026, 8, 15, 12)),
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
          allTodosProvider.overrideWith((_) => Stream.value(seed)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CalendarDayPanel(date: date, entries: entries),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  group('헤더', () {
    testWidgets('선택일을 "8월 15일 (토)" 로 표시하고 건수를 붙인다', (tester) async {
      await mount(
        tester,
        entries: [
          TodoEntry(make(id: 'a', dueAt: date)),
          TodoEntry(make(id: 'b', dueAt: date)),
        ],
      );
      expect(find.text('8월 15일 (토)'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('"이 날짜로 추가" 버튼이 항상 있다', (tester) async {
      await mount(tester, entries: const []);
      expect(find.byKey(const ValueKey('calendar-add-on-day')), findsOneWidget);
    });
  });

  group('빈 상태', () {
    testWidgets('그날 항목이 없으면 안내 문구', (tester) async {
      await mount(tester, entries: const []);
      expect(find.text('이 날은 비어 있습니다'), findsOneWidget);
    });
  });

  group('타일', () {
    testWidgets('실제 Todo 는 체크 원과 함께 그려진다', (tester) async {
      final todo = make(id: 'a', title: '세금계산서', dueAt: date, isAllDay: true);
      await mount(tester, entries: [TodoEntry(todo)], seed: [todo]);

      expect(
        find.byKey(const ValueKey('calendar-panel-tile-todo:a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('calendar-panel-check-todo:a')),
        findsOneWidget,
      );
      expect(find.text('세금계산서'), findsOneWidget);
    });

    testWidgets('체크를 누르면 완료 상태가 저장된다', (tester) async {
      final todo = make(id: 'a', dueAt: date, isAllDay: true);
      await mount(tester, entries: [TodoEntry(todo)], seed: [todo]);

      await tester.tap(
        find.byKey(const ValueKey('calendar-panel-check-todo:a')),
      );
      await tester.pump();
      await tester.pump();

      expect((await db.todosDao.getById('a'))!.isDone, isTrue);
    });

    testWidgets('종일 항목은 시각을 찍지 않는다 (00:00 금지)', (tester) async {
      final todo = make(id: 'a', dueAt: date, isAllDay: true);
      await mount(tester, entries: [TodoEntry(todo)], seed: [todo]);
      expect(find.textContaining('00:00'), findsNothing);
    });

    testWidgets('시각 있는 항목은 시각 라벨이 붙는다', (tester) async {
      final todo = make(id: 'a', dueAt: DateTime(2026, 8, 15, 14, 30));
      await mount(tester, entries: [TodoEntry(todo)], seed: [todo]);
      expect(find.textContaining('14:30'), findsOneWidget);
    });

    testWidgets('메모(note) 는 체크 원 대신 글리프', (tester) async {
      final note = make(
        id: 'n',
        title: '메모',
        dueAt: date,
        isAllDay: true,
        type: TodoType.note,
      );
      await mount(tester, entries: [TodoEntry(note)], seed: [note]);
      expect(
        find.byKey(const ValueKey('calendar-panel-check-todo:n')),
        findsNothing,
      );
      expect(find.byIcon(Icons.sticky_note_2_outlined), findsOneWidget);
    });

    testWidgets('완료 항목은 취소선으로 구분된다', (tester) async {
      final todo = make(
        id: 'a',
        title: '완료건',
        dueAt: date,
        isAllDay: true,
        doneAt: DateTime(2026, 8, 15, 20),
      );
      await mount(tester, entries: [TodoEntry(todo)], seed: [todo]);
      final text = tester.widget<Text>(find.text('완료건'));
      expect(text.style?.decoration, TextDecoration.lineThrough);
    });
  });

  group('미래 반복 고스트', () {
    Todo master() =>
        make(id: 'm1', title: '팀 회의', dueAt: DateTime(2026, 8, 1, 10)).copyWith(
          seriesId: 'm1',
          recurrenceRule: const RecurrenceRule(
            freq: RecurrenceFreq.weekly,
          ).encode(),
          isSeriesMaster: true,
        );

    testWidgets('"예정" 표시와 함께 그려진다', (tester) async {
      final m = master();
      await mount(
        tester,
        entries: [RecurringGhostEntry(master: m, date: DateTime(2026, 8, 22))],
        seed: [m],
      );
      expect(find.text('팀 회의'), findsOneWidget);
      expect(find.textContaining('예정'), findsOneWidget);
    });

    testWidgets('체크하면 그 회차가 실체화된 뒤 완료된다', (tester) async {
      final m = master();
      await mount(
        tester,
        entries: [RecurringGhostEntry(master: m, date: DateTime(2026, 8, 22))],
        seed: [m],
      );

      await tester.tap(
        find.byKey(const ValueKey('calendar-panel-check-ghost:m1#20260822')),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      final created = await db.todosDao.getById('m1#20260822');
      expect(created, isNotNull, reason: '고스트를 건드리면 그 회차만 실체화된다');
      expect(created!.isDone, isTrue);
      expect(created.isSeriesMaster, isFalse);
    });
  });

  group('구글 이벤트 (읽기 전용)', () {
    testWidgets('체크 원이 없고 Google 표시가 붙는다', (tester) async {
      await mount(
        tester,
        entries: [
          GoogleEventEntry(
            id: 'g1',
            title: '외부 미팅',
            start: DateTime(2026, 8, 15, 14),
            end: DateTime(2026, 8, 15, 15),
            isAllDay: false,
          ),
        ],
      );
      expect(find.text('외부 미팅'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('calendar-panel-check-gcal:g1')),
        findsNothing,
      );
      expect(find.textContaining('Google'), findsOneWidget);
    });
  });
}
