import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';

void main() {
  Todo make(String id, {DateTime? dueAt}) => Todo(
    id: id,
    title: id,
    category: Category.work,
    dueAt: dueAt,
    createdAt: DateTime.utc(2026, 8, 1),
    updatedAt: DateTime.utc(2026, 8, 1),
  );

  List<String> ids(List<Todo> todos) => todos.map((t) => t.id).toList();

  group('TodoSortPolicy.apply', () {
    test('manual 모드는 들어온 순서를 그대로 유지한다', () {
      final items = [
        make('a', dueAt: DateTime.utc(2026, 8, 20)),
        make('b'),
        make('c', dueAt: DateTime.utc(2026, 8, 3)),
      ];

      final sorted = TodoSortPolicy.apply(items, TodoSortMode.manual);

      expect(ids(sorted), ['a', 'b', 'c']);
    });

    test('dueDate 모드는 일정이 빠른 순으로 정렬한다', () {
      final items = [
        make('late', dueAt: DateTime.utc(2026, 8, 20, 9)),
        make('early', dueAt: DateTime.utc(2026, 8, 3, 18)),
        make('mid', dueAt: DateTime.utc(2026, 8, 12)),
      ];

      final sorted = TodoSortPolicy.apply(items, TodoSortMode.dueDate);

      expect(ids(sorted), ['early', 'mid', 'late']);
    });

    test('dueDate 모드에서 날짜 없는 항목은 맨 뒤로, 그 안에서는 원래 순서', () {
      final items = [
        make('noDate1'),
        make('dated', dueAt: DateTime.utc(2026, 8, 12)),
        make('noDate2'),
      ];

      final sorted = TodoSortPolicy.apply(items, TodoSortMode.dueDate);

      expect(ids(sorted), ['dated', 'noDate1', 'noDate2']);
    });

    test('dueAt 이 같으면 원래(수동) 순서를 유지한다 — stable', () {
      final same = DateTime.utc(2026, 8, 12, 10);
      final items = [
        make('first', dueAt: same),
        make('second', dueAt: same),
        make('third', dueAt: same),
      ];

      final sorted = TodoSortPolicy.apply(items, TodoSortMode.dueDate);

      expect(ids(sorted), ['first', 'second', 'third']);
    });

    test('원본 리스트를 변형하지 않는다', () {
      final items = [
        make('b', dueAt: DateTime.utc(2026, 8, 20)),
        make('a', dueAt: DateTime.utc(2026, 8, 3)),
      ];

      TodoSortPolicy.apply(items, TodoSortMode.dueDate);

      expect(ids(items), ['b', 'a']);
    });

    test('빈 리스트는 빈 리스트를 돌려준다', () {
      expect(TodoSortPolicy.apply(const [], TodoSortMode.dueDate), isEmpty);
    });

    test('로컬 시각 기준으로 비교한다 — UTC/로컬 혼재해도 순서가 흔들리지 않는다', () {
      final utcNoon = DateTime.utc(2026, 8, 12, 3);
      final items = [
        make(
          'localLater',
          dueAt: utcNoon.toLocal().add(const Duration(hours: 2)),
        ),
        make('utcEarlier', dueAt: utcNoon),
      ];

      final sorted = TodoSortPolicy.apply(items, TodoSortMode.dueDate);

      expect(ids(sorted), ['utcEarlier', 'localLater']);
    });
  });

  group('TodoSortMode', () {
    test('storageKey 왕복 — 저장된 문자열에서 그대로 복원된다', () {
      for (final mode in TodoSortMode.values) {
        expect(TodoSortMode.fromStorage(mode.storageValue), mode);
      }
    });

    test('알 수 없는 값 / null 은 manual 로 안전 fallback', () {
      expect(TodoSortMode.fromStorage(null), TodoSortMode.manual);
      expect(TodoSortMode.fromStorage('무엇인가'), TodoSortMode.manual);
    });
  });
}
