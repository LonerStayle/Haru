import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_day_cell.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_entry.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_layout.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_month_grid.dart';

Todo make({
  required String id,
  String title = '할 일',
  Category? category,
  DateTime? dueAt,
  DateTime? endAt,
  bool isAllDay = false,
  DateTime? doneAt,
}) => Todo(
  id: id,
  title: title,
  category: category ?? Category.work,
  dueAt: dueAt,
  endAt: endAt,
  isAllDay: isAllDay,
  doneAt: doneAt,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  final today = DateTime(2026, 8, 15);
  final august = DateTime(2026, 8);

  Map<DateTime, List<CalendarEntry>> bucketsOf(List<CalendarEntry> entries) =>
      bucketByDate(
        entries: entries,
        rangeStart: DateTime(2026, 7, 26),
        rangeEnd: DateTime(2026, 9, 5),
      );

  Future<void> mount(
    WidgetTester tester, {
    List<CalendarEntry> entries = const [],
    DateTime? selectedDay,
    void Function(DateTime)? onSelectDay,
    void Function(DateTime)? onLongPressDay,
    Size size = const Size(1100, 800),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.mobileLight(),
        home: Scaffold(
          body: CalendarMonthGrid(
            focusedMonth: august,
            buckets: bucketsOf(entries),
            today: today,
            selectedDay: selectedDay ?? today,
            onSelectDay: onSelectDay,
            onLongPressDay: onLongPressDay,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder cell(DateTime d) =>
      find.byKey(ValueKey('calendar-cell-${calendarDateKey(d)}'));

  group('그리드 기하', () {
    testWidgets('42칸이 모두 그려진다 (앞뒤 달 넘침 포함)', (tester) async {
      await mount(tester);
      expect(find.byType(CalendarDayCell), findsNWidgets(42));
      // 앞 넘침 (7/26) 과 뒤 넘침 (9/5) 도 실재한다.
      expect(cell(DateTime(2026, 7, 26)), findsOneWidget);
      expect(cell(DateTime(2026, 9, 5)), findsOneWidget);
    });

    testWidgets('요일 헤더는 일요일부터', (tester) async {
      await mount(tester);
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .toList();
      // 헤더가 맨 앞에 오므로 앞 7개가 요일.
      expect(labels.take(7), ['일', '월', '화', '수', '목', '금', '토']);
    });

    testWidgets('모든 주 행의 높이가 균일하다', (tester) async {
      await mount(tester);
      final heights = <double>{};
      for (final d in [
        DateTime(2026, 7, 26),
        DateTime(2026, 8, 2),
        DateTime(2026, 8, 30),
      ]) {
        heights.add(tester.getSize(cell(d)).height);
      }
      expect(heights, hasLength(1));
    });
  });

  group('오늘 / 선택 강조', () {
    testWidgets('오늘과 선택일이 다를 때 둘 다 보인다', (tester) async {
      await mount(tester, selectedDay: DateTime(2026, 8, 20));

      final todayCell = tester.widget<CalendarDayCell>(cell(today));
      final selectedCell = tester.widget<CalendarDayCell>(
        cell(DateTime(2026, 8, 20)),
      );

      expect(todayCell.isToday, isTrue);
      expect(todayCell.isSelected, isFalse);
      expect(selectedCell.isToday, isFalse);
      expect(selectedCell.isSelected, isTrue);
    });

    testWidgets('오늘이자 선택일이면 두 표식이 동시에 선다', (tester) async {
      await mount(tester, selectedDay: today);
      final c = tester.widget<CalendarDayCell>(cell(today));
      expect(c.isToday, isTrue);
      expect(c.isSelected, isTrue);
    });

    testWidgets('다른 달 넘침 날짜는 isOutsideMonth', (tester) async {
      await mount(tester);
      expect(
        tester
            .widget<CalendarDayCell>(cell(DateTime(2026, 7, 26)))
            .isOutsideMonth,
        isTrue,
      );
      expect(
        tester
            .widget<CalendarDayCell>(cell(DateTime(2026, 8, 3)))
            .isOutsideMonth,
        isFalse,
      );
    });
  });

  group('인터랙션', () {
    testWidgets('날짜 탭 → onSelectDay(그 날짜)', (tester) async {
      final tapped = <DateTime>[];
      await mount(tester, onSelectDay: tapped.add);
      await tester.tap(cell(DateTime(2026, 8, 20)));
      await tester.pump();
      expect(tapped, [DateTime(2026, 8, 20)]);
    });

    testWidgets('길게 누르기 → onLongPressDay(그 날짜)', (tester) async {
      final pressed = <DateTime>[];
      await mount(tester, onLongPressDay: pressed.add);
      await tester.longPress(cell(DateTime(2026, 8, 20)));
      await tester.pump();
      expect(pressed, [DateTime(2026, 8, 20)]);
    });

    testWidgets('넘침 날짜도 탭된다 (그 달로 이동하기 위해)', (tester) async {
      final tapped = <DateTime>[];
      await mount(tester, onSelectDay: tapped.add);
      await tester.tap(cell(DateTime(2026, 9, 5)));
      await tester.pump();
      expect(tapped, [DateTime(2026, 9, 5)]);
    });
  });

  group('데스크탑 — 제목 칩', () {
    setUp(() => AppPlatform.debugFormFactorOverride = FormFactor.desktop);
    tearDown(() => AppPlatform.debugFormFactorOverride = null);

    testWidgets('단일 항목은 제목 칩으로 그려진다', (tester) async {
      await mount(
        tester,
        entries: [
          TodoEntry(
            make(id: 'a', title: '세금계산서', dueAt: DateTime(2026, 8, 15)),
          ),
        ],
      );
      expect(
        find.byKey(const ValueKey('calendar-chip-todo:a')),
        findsOneWidget,
      );
      expect(find.text('세금계산서'), findsOneWidget);
    });

    testWidgets('상한 3개를 넘으면 "외 N건"', (tester) async {
      await mount(
        tester,
        entries: [
          for (var i = 0; i < 5; i++)
            TodoEntry(
              make(
                id: 'e$i',
                title: '일$i',
                dueAt: DateTime(2026, 8, 15, 9 + i),
              ),
            ),
        ],
      );
      expect(find.byType(CalendarEntryChip), findsNWidgets(3));
      expect(
        find.byKey(ValueKey('calendar-more-${calendarDateKey(today)}')),
        findsOneWidget,
      );
      expect(find.text('외 2건'), findsOneWidget);
    });

    testWidgets('미완료가 완료보다 먼저 칩 자리를 차지한다', (tester) async {
      await mount(
        tester,
        entries: [
          TodoEntry(
            make(
              id: 'done',
              title: '완료건',
              dueAt: DateTime(2026, 8, 15, 8),
              doneAt: DateTime(2026, 8, 15, 20),
            ),
          ),
          for (var i = 0; i < 3; i++)
            TodoEntry(
              make(
                id: 'u$i',
                title: '미완료$i',
                dueAt: DateTime(2026, 8, 15, 18 + i),
              ),
            ),
        ],
      );
      expect(find.text('완료건'), findsNothing);
      expect(find.text('미완료0'), findsOneWidget);
    });
  });

  group('모바일 — 점', () {
    setUp(() => AppPlatform.debugFormFactorOverride = FormFactor.mobile);
    tearDown(() => AppPlatform.debugFormFactorOverride = null);

    testWidgets('단일 항목은 점으로 그려지고 제목은 안 나온다', (tester) async {
      await mount(
        tester,
        size: const Size(420, 900),
        entries: [
          TodoEntry(
            make(id: 'a', title: '세금계산서', dueAt: DateTime(2026, 8, 15)),
          ),
        ],
      );
      expect(find.byKey(const ValueKey('calendar-dot-todo:a')), findsOneWidget);
      expect(find.text('세금계산서'), findsNothing);
    });

    testWidgets('상한 4개까지만 점을 찍는다', (tester) async {
      await mount(
        tester,
        size: const Size(420, 900),
        entries: [
          for (var i = 0; i < 6; i++)
            TodoEntry(
              make(
                id: 'e$i',
                title: '일$i',
                dueAt: DateTime(2026, 8, 15, 9 + i),
              ),
            ),
        ],
      );
      expect(find.byType(CalendarEntryDot), findsNWidgets(4));
    });
  });

  group('기간 막대', () {
    testWidgets('여러 날 항목은 막대로 그려진다 (칩이 아니라)', (tester) async {
      await mount(
        tester,
        entries: [
          TodoEntry(
            make(
              id: 'trip',
              title: '출장',
              dueAt: DateTime(2026, 8, 17),
              endAt: DateTime(2026, 8, 19),
              isAllDay: true,
            ),
          ),
        ],
      );
      expect(
        find.byKey(const ValueKey('calendar-bar-todo:trip')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('calendar-chip-todo:trip')),
        findsNothing,
      );
    });

    testWidgets('주 경계를 넘으면 막대가 주마다 하나씩 (두 조각)', (tester) async {
      await mount(
        tester,
        entries: [
          TodoEntry(
            make(
              id: 'long',
              title: '장기',
              dueAt: DateTime(2026, 8, 14),
              endAt: DateTime(2026, 8, 25),
              isAllDay: true,
            ),
          ),
        ],
      );
      // 8/14(금)~8/25(화) 는 3개 주에 걸친다.
      expect(
        find.byKey(const ValueKey('calendar-bar-todo:long')),
        findsNWidgets(3),
      );
      // 이어진 조각은 제목을 반복하지 않는다.
      expect(find.text('장기'), findsOneWidget);
    });

    testWidgets('막대가 있으면 그 주의 칩 영역이 아래로 밀린다', (tester) async {
      await mount(tester);
      final without = tester
          .widget<CalendarDayCell>(cell(DateTime(2026, 8, 18)))
          .reservedTop;

      await mount(
        tester,
        entries: [
          TodoEntry(
            make(
              id: 'trip',
              title: '출장',
              dueAt: DateTime(2026, 8, 17),
              endAt: DateTime(2026, 8, 19),
              isAllDay: true,
            ),
          ),
        ],
      );
      final with_ = tester
          .widget<CalendarDayCell>(cell(DateTime(2026, 8, 18)))
          .reservedTop;

      expect(without, 0.0);
      expect(with_, greaterThan(0));
    });
  });

  group('고스트 (미래 반복 예정)', () {
    setUp(() => AppPlatform.debugFormFactorOverride = FormFactor.desktop);
    tearDown(() => AppPlatform.debugFormFactorOverride = null);

    testWidgets('고스트도 칩으로 그려진다', (tester) async {
      final master = make(
        id: 'm1',
        title: '팀 회의',
        dueAt: DateTime(2026, 8, 1, 10),
      ).copyWith(seriesId: 'm1', isSeriesMaster: true);

      await mount(
        tester,
        entries: [
          RecurringGhostEntry(master: master, date: DateTime(2026, 8, 22)),
        ],
      );
      expect(
        find.byKey(const ValueKey('calendar-chip-ghost:m1#20260822')),
        findsOneWidget,
      );
      expect(find.text('팀 회의'), findsOneWidget);
    });
  });
}
