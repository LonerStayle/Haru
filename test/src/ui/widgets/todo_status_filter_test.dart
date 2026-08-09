import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/ui/widgets/todo_status_filter.dart';

void main() {
  Todo make({
    required String id,
    TodoType type = TodoType.task,
    DateTime? doneAt,
    DateTime? startedAt,
  }) => Todo(
    id: id,
    title: id,
    category: Category.work,
    type: type,
    doneAt: doneAt,
    startedAt: startedAt,
    createdAt: DateTime.utc(2026, 8, 1),
    updatedAt: DateTime.utc(2026, 8, 1),
  );

  final undone = make(id: 'u');
  final inProgress = make(id: 'p', startedAt: DateTime.utc(2026, 8, 2));
  final done = make(id: 'd', doneAt: DateTime.utc(2026, 8, 2));
  final note = make(id: 'n', type: TodoType.note);

  group('TodoStatusFilter.matches', () {
    test('all 은 타입·상태 무관하게 전부 통과', () {
      for (final t in [undone, inProgress, done, note]) {
        expect(TodoStatusFilter.all.matches(t), isTrue);
      }
    });

    test('undone 은 순수 미완료 task 만 (진행중 제외)', () {
      expect(TodoStatusFilter.undone.matches(undone), isTrue);
      expect(TodoStatusFilter.undone.matches(inProgress), isFalse);
      expect(TodoStatusFilter.undone.matches(done), isFalse);
      // note 는 isDone 이 항상 false 라 자칫 '미완료'로 새어 들어온다 — 타입으로 차단.
      expect(TodoStatusFilter.undone.matches(note), isFalse);
    });

    test('inProgress / done / note 는 각 상태만', () {
      expect(TodoStatusFilter.inProgress.matches(inProgress), isTrue);
      expect(TodoStatusFilter.inProgress.matches(undone), isFalse);
      expect(TodoStatusFilter.done.matches(done), isTrue);
      expect(TodoStatusFilter.done.matches(inProgress), isFalse);
      expect(TodoStatusFilter.note.matches(note), isTrue);
      expect(TodoStatusFilter.note.matches(undone), isFalse);
    });
  });

  group('TodoStatusCounts', () {
    test('상태별 카운트 + all 은 4개 합과 일치', () {
      final counts = TodoStatusCounts.of([
        undone,
        undone,
        inProgress,
        done,
        note,
      ]);
      expect(counts.undone, 2);
      expect(counts.inProgress, 1);
      expect(counts.done, 1);
      expect(counts.note, 1);
      expect(
        counts.all,
        counts.undone + counts.inProgress + counts.done + counts.note,
      );
    });

    test('빈 입력은 전부 0', () {
      final counts = TodoStatusCounts.of(const <Todo>[]);
      expect(counts.all, 0);
      expect(counts.countOf(TodoStatusFilter.done), 0);
    });
  });

  group('TodoStatusFilterBar', () {
    Future<TodoStatusFilter?> mount(
      WidgetTester tester, {
      required TodoStatusCounts counts,
      TodoStatusFilter selected = TodoStatusFilter.all,
    }) async {
      TodoStatusFilter? tapped;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.mobileLight(),
          home: Scaffold(
            body: TodoStatusFilterBar(
              counts: counts,
              selected: selected,
              onSelected: (f) => tapped = f,
              accent: Category.work.color,
            ),
          ),
        ),
      );
      return tapped;
    }

    testWidgets('칩 라벨은 "이름 개수" 형식', (tester) async {
      await mount(
        tester,
        counts: TodoStatusCounts.of([undone, inProgress, done, note]),
      );

      expect(find.text('전체 4'), findsOneWidget);
      expect(find.text('미완료 1'), findsOneWidget);
      expect(find.text('진행중 1'), findsOneWidget);
      expect(find.text('완료 1'), findsOneWidget);
      expect(find.text('메모 1'), findsOneWidget);
    });

    testWidgets('메모 0건이면 메모 칩 자체를 숨긴다', (tester) async {
      await mount(tester, counts: TodoStatusCounts.of([undone, done]));

      expect(find.text('메모 0'), findsNothing);
      expect(find.byKey(const ValueKey('status-filter-note')), findsNothing);
      // 나머지 칩은 0건이어도 유지 (자리 이동 방지).
      expect(find.text('진행중 0'), findsOneWidget);
    });

    testWidgets('칩 탭 → 그 필터로 onSelected', (tester) async {
      TodoStatusFilter? tapped;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.mobileLight(),
          home: Scaffold(
            body: TodoStatusFilterBar(
              counts: TodoStatusCounts.of([undone, done]),
              selected: TodoStatusFilter.all,
              onSelected: (f) => tapped = f,
              accent: Category.work.color,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('status-filter-done')));
      await tester.pump();

      expect(tapped, TodoStatusFilter.done);
    });

    testWidgets('선택된 칩은 굵게 — 시각적으로 현재 상태를 알 수 있다', (tester) async {
      await mount(
        tester,
        counts: TodoStatusCounts.of([undone, done]),
        selected: TodoStatusFilter.done,
      );

      final selectedText = tester.widget<Text>(find.text('완료 1'));
      final otherText = tester.widget<Text>(find.text('미완료 1'));
      expect(selectedText.style?.fontWeight, FontWeight.w700);
      expect(otherText.style?.fontWeight, FontWeight.w600);
    });
  });
}
