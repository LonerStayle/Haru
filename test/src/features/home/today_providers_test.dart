import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';

/// today_providers (watchTodayTodos + carryoverCount) 의 v1.5 날짜 기반 동작 검증.
///
/// 핵심 (v1.5 변경):
///   - **날짜(dueAt) 가 없는 항목은 오늘 화면에서 제외**된다 (이전엔 createdAt 폴백으로
///     무조건 오늘에 떠서 영구 이월되던 문제를 제거). 무날짜 항목은 전체보기에서 관리.
///   - dueAt 어제 + 미체크 = 오늘로 이월 (visible + carry count).
///   - dueAt 오늘 + 미체크 = 오늘 (visible, carry count X).
void main() {
  ProviderContainer makeContainer(AppDatabase db) => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowProvider.overrideWithValue(() => clock.now()),
      // watchTodayTodosProvider 는 이제 보관 카테고리 필터를 위해 categoriesProvider 를
      // 참조한다. drift stream 대신 즉시 emit 하는 Stream.value 로 대체 (fakeAsync 정착).
      categoriesProvider.overrideWith(
        (ref) => Stream.value(Category.builtinSeeds),
      ),
    ],
  );

  group('today_providers — 무날짜(dueAt null) 항목 제외', () {
    test('dueAt null + createdAt 어제 + 미체크 → 오늘에서 제외 (visible 0, carry 0)', () {
      fakeAsync((async) {
        final db = AppDatabase.memory();
        final container = makeContainer(db);
        addTearDown(() async {
          container.dispose();
          await db.close();
        });

        db.todosDao.upsert(
          _todo(id: 'carry', createdAt: DateTime.utc(2026, 5, 26, 9)),
        );

        container.listen(watchTodayTodosProvider, (_, _) {});
        async.flushMicrotasks();

        expect(
          container.read(watchTodayTodosProvider).requireValue,
          isEmpty,
          reason: 'v1.5 — 무날짜 항목은 오늘에 뜨지 않는다',
        );
        expect(container.read(carryoverCountProvider), 0);
      }, initialTime: DateTime(2026, 5, 27, 10));
    });

    test('dueAt null 여러 건 (어제/오늘 생성) → 전부 제외, carry 0', () {
      fakeAsync((async) {
        final db = AppDatabase.memory();
        final container = makeContainer(db);
        addTearDown(() async {
          container.dispose();
          await db.close();
        });

        db.todosDao.upsert(
          _todo(id: 'a', createdAt: DateTime.utc(2026, 5, 26, 9)),
        );
        db.todosDao.upsert(
          _todo(id: 'b', createdAt: DateTime.utc(2026, 5, 25, 9)),
        );
        db.todosDao.upsert(
          _todo(id: 'today', createdAt: DateTime.utc(2026, 5, 27, 2)),
        );

        container.listen(watchTodayTodosProvider, (_, _) {});
        async.flushMicrotasks();

        expect(container.read(watchTodayTodosProvider).requireValue, isEmpty);
        expect(container.read(carryoverCountProvider), 0);
      }, initialTime: DateTime(2026, 5, 27, 10));
    });
  });

  group('today_providers — 날짜 지정 항목 이월', () {
    test('dueAt 어제 + 미체크 → 오늘 visible + carryover 1', () {
      fakeAsync((async) {
        final db = AppDatabase.memory();
        final container = makeContainer(db);
        addTearDown(() async {
          container.dispose();
          await db.close();
        });

        db.todosDao.upsert(
          _todo(
            id: 'carry',
            createdAt: DateTime.utc(2026, 5, 26, 9),
            dueAt: DateTime(2026, 5, 26, 9),
          ),
        );

        container.listen(watchTodayTodosProvider, (_, _) {});
        async.flushMicrotasks();

        expect(
          container.read(watchTodayTodosProvider).requireValue.map((t) => t.id),
          ['carry'],
        );
        expect(
          container.read(carryoverCountProvider),
          1,
          reason: 'dueAt 어제 = 이월 카운트에 포함',
        );
      }, initialTime: DateTime(2026, 5, 27, 10));
    });

    test('dueAt 오늘 + 미체크 → visible + carryover 0', () {
      fakeAsync((async) {
        final db = AppDatabase.memory();
        final container = makeContainer(db);
        addTearDown(() async {
          container.dispose();
          await db.close();
        });

        db.todosDao.upsert(
          _todo(
            id: 'fresh',
            createdAt: DateTime.utc(2026, 5, 27, 1),
            dueAt: DateTime(2026, 5, 27, 14),
          ),
        );

        container.listen(watchTodayTodosProvider, (_, _) {});
        async.flushMicrotasks();

        expect(
          container.read(watchTodayTodosProvider).requireValue.map((t) => t.id),
          ['fresh'],
        );
        expect(container.read(carryoverCountProvider), 0);
      }, initialTime: DateTime(2026, 5, 27, 10));
    });

    test('dueAt 어제 + 어제 체크됨 → hide (carry X)', () {
      fakeAsync((async) {
        final db = AppDatabase.memory();
        final container = makeContainer(db);
        addTearDown(() async {
          container.dispose();
          await db.close();
        });

        db.todosDao.upsert(
          _todo(
            id: 'staleDone',
            createdAt: DateTime.utc(2026, 5, 26, 9),
            dueAt: DateTime(2026, 5, 26, 9),
            doneAt: DateTime(2026, 5, 26, 20),
          ),
        );

        container.listen(watchTodayTodosProvider, (_, _) {});
        async.flushMicrotasks();

        expect(
          container.read(watchTodayTodosProvider).requireValue,
          isEmpty,
          reason: '어제 체크된 항목은 자정 지나면 hide',
        );
        expect(container.read(carryoverCountProvider), 0);
      }, initialTime: DateTime(2026, 5, 27, 10));
    });
  });
}

Todo _todo({
  required String id,
  required DateTime createdAt,
  DateTime? dueAt,
  DateTime? doneAt,
}) => Todo(
  id: id,
  title: '항목 $id',
  category: Category.daily,
  dueAt: dueAt,
  doneAt: doneAt,
  createdAt: createdAt,
  updatedAt: createdAt,
  calendarEventId: null,
);
