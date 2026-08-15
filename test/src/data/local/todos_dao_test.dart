import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart' as domain;

/// TodosDao 매핑 검증 — Task A3: calendarId / calendarOrigin round-trip.
///
/// 매 테스트는 in-memory AppDatabase 로 fresh start.
void main() {
  group('TodosDao — calendarId / calendarOrigin round-trip', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.memory();
    });

    tearDown(() async {
      await db.close();
    });

    domain.Todo buildTodo({String? calendarId, String calendarOrigin = 'app'}) {
      final now = DateTime.utc(2026, 8, 15, 9);
      return domain.Todo(
        id: 'todo-cal-1',
        title: '캘린더 연동 할 일',
        category: Category.work,
        dueAt: DateTime.utc(2026, 8, 16, 10),
        doneAt: null,
        createdAt: now,
        updatedAt: now,
        calendarEventId: 'evt-1',
        calendarId: calendarId,
        calendarOrigin: calendarOrigin,
      );
    }

    test('upsert → getById — calendarId/calendarOrigin(gcal) 이 보존된다', () async {
      final todo = buildTodo(calendarId: 'primary', calendarOrigin: 'gcal');
      await db.todosDao.upsert(todo);

      final restored = await db.todosDao.getById('todo-cal-1');
      expect(restored, isNotNull);
      expect(restored!.calendarId, 'primary');
      expect(restored.calendarOrigin, 'gcal');
    });

    test(
      'upsert → getById — calendarId null / calendarOrigin 기본값(app) 보존',
      () async {
        final todo = buildTodo();
        await db.todosDao.upsert(todo);

        final restored = await db.todosDao.getById('todo-cal-1');
        expect(restored, isNotNull);
        expect(restored!.calendarId, isNull);
        expect(restored.calendarOrigin, 'app');
      },
    );

    test('watchAll — join 조회에서도 calendarId/calendarOrigin 보존', () async {
      final todo = buildTodo(calendarId: 'work-cal', calendarOrigin: 'gcal');
      await db.todosDao.upsert(todo);

      final list = await db.todosDao.watchAll().first;
      final restored = list.singleWhere((t) => t.id == 'todo-cal-1');
      expect(restored.calendarId, 'work-cal');
      expect(restored.calendarOrigin, 'gcal');
    });
  });
}
