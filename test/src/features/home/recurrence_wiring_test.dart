import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/recurrence.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';

ProviderContainer _container(
  AppDatabase db,
  DateTime Function() now,
) => ProviderContainer(
  overrides: [
    appDatabaseProvider.overrideWithValue(db),
    nowProvider.overrideWithValue(now),
    // dedupedTodayProvider 가 보관 필터를 위해 categoriesProvider 를 참조 —
    // fakeAsync 정착을 위해 즉시 emit 하는 Stream.value 로 대체.
    categoriesProvider.overrideWith((_) => Stream.value(Category.builtinSeeds)),
  ],
);

Todo _master({
  required String id,
  required RecurrenceRule rule,
  required DateTime dueAt,
}) => Todo(
  id: id,
  title: '매일 비타민',
  category: Category.daily,
  dueAt: dueAt,
  doneAt: null,
  createdAt: dueAt,
  updatedAt: dueAt,
  seriesId: id,
  recurrenceRule: rule.encode(),
  isSeriesMaster: true,
);

void main() {
  // 트리거(스트림+async upsert)는 실제 async — 폴링으로 안정화 대기.
  group('recurrenceMaterializerProvider', () {
    test('누락 인스턴스를 결정적 id 로 생성', () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      await db.todosDao.upsert(
        _master(
          id: 'm1',
          rule: const RecurrenceRule(freq: RecurrenceFreq.daily),
          dueAt: DateTime(2026, 1, 1),
        ),
      );

      final c = _container(db, () => DateTime(2026, 1, 5, 12));
      addTearDown(c.dispose);
      c.read(recurrenceMaterializerProvider); // 활성화

      var inst = <Todo>[];
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final all = await db.todosDao.watchAll().first;
        inst = all
            .where((t) => t.seriesId == 'm1' && !t.isSeriesMaster)
            .toList();
        if (inst.length >= 5) break;
      }
      expect(inst.length, 5); // 1/1~1/5
      expect(inst.map((t) => t.id).toSet(), {
        'm1#20260101',
        'm1#20260102',
        'm1#20260103',
        'm1#20260104',
        'm1#20260105',
      }, reason: '결정적 id — 중복 불가');
    });

    test('재평가해도 중복 없음 (결정적 id 멱등)', () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      await db.todosDao.upsert(
        _master(
          id: 'm1',
          rule: const RecurrenceRule(freq: RecurrenceFreq.daily),
          dueAt: DateTime(2026, 1, 4),
        ),
      );

      final c = _container(db, () => DateTime(2026, 1, 5, 12));
      addTearDown(c.dispose);
      c.read(recurrenceMaterializerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final all = await db.todosDao.watchAll().first;
      final inst = all
          .where((t) => t.seriesId == 'm1' && !t.isSeriesMaster)
          .toList();
      expect(inst.length, 2); // 1/4, 1/5 — 재평가에도 결정적 id 라 2건 유지
    });
  });

  test('dedupedTodayProvider — 같은 시리즈 미체크 누적은 1건만 노출', () {
    fakeAsync((async) {
      final db = AppDatabase.memory();
      final container = _container(db, () => clock.now());
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      db.todosDao.upsert(
        _master(
          id: 'm1',
          rule: const RecurrenceRule(freq: RecurrenceFreq.daily),
          dueAt: DateTime(2026, 1, 1),
        ),
      );
      for (final d in [3, 4, 5]) {
        db.todosDao.upsert(
          Todo(
            id: 'm1#2026010$d',
            title: '매일 비타민',
            category: Category.daily,
            dueAt: DateTime(2026, 1, d, 9),
            doneAt: null,
            createdAt: DateTime(2026, 1, d),
            updatedAt: DateTime(2026, 1, d),
            seriesId: 'm1',
          ),
        );
      }
      async.flushMicrotasks();

      container.listen(watchTodayTodosProvider, (_, _) {});
      async.flushMicrotasks();

      final deduped = container.read(dedupedTodayProvider);
      final seriesVisible = deduped.visible
          .where((t) => t.seriesId == 'm1')
          .toList();
      expect(seriesVisible.length, 1, reason: 'leader 1건만');
      expect(seriesVisible.single.dueAt!.day, 3, reason: '가장 이른 발생분이 leader');
      expect(deduped.hiddenCountBySeries['m1'], 2);
      expect(deduped.visible.any((t) => t.isSeriesMaster), isFalse);
    }, initialTime: DateTime(2026, 1, 5, 12));
  });
}
