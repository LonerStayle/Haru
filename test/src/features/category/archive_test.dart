import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_categories_repository.dart';
import 'package:solo_todo/src/data/local/local_groups_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';

/// 그룹/카테고리 보관(archive) 기능 검증 — 컨트롤러 액션 + 파생 provider 필터.
void main() {
  group('CategoriesController archive/unarchive', () {
    late AppDatabase db;
    late CategoriesController controller;

    setUp(() {
      db = AppDatabase.memory();
      controller = CategoriesController(
        LocalCategoriesRepository(db.categoriesDao),
      );
    });
    tearDown(() async => db.close());

    test('archive → archived=true, unarchive → false (할 일 유무 무관)', () async {
      await controller.archive('work');
      expect((await db.categoriesDao.getById('work'))!.archived, isTrue);

      await controller.unarchive('work');
      expect((await db.categoriesDao.getById('work'))!.archived, isFalse);
    });

    test('없는 id / 이미 같은 상태면 no-op (idempotent)', () async {
      await controller.unarchive('work'); // 이미 false
      expect((await db.categoriesDao.getById('work'))!.archived, isFalse);
      await controller.archive('does-not-exist'); // 예외 없이 통과
    });
  });

  group('GroupsController archive/unarchive (cascade)', () {
    late AppDatabase db;
    late GroupsController groups;
    late CategoriesController categories;

    setUp(() {
      db = AppDatabase.memory();
      groups = GroupsController(
        LocalGroupsRepository(db.groupsDao),
        LocalCategoriesRepository(db.categoriesDao),
      );
      categories = CategoriesController(
        LocalCategoriesRepository(db.categoriesDao),
      );
    });
    tearDown(() async => db.close());

    test('그룹 보관 → 그룹 + 소속 카테고리 함께 archived, 복원도 함께', () async {
      await groups.add(
        const Group(id: 'g1', label: '지난회사', colorValue: 0xFF2A66FF),
      );
      // builtin 2개를 g1 에 배정.
      await categories.moveToGroup('work', 'g1');
      await categories.moveToGroup('personal_dev', 'g1');
      // 다른 그룹 밖 카테고리는 영향 받지 않아야 함.

      await groups.archive('g1');

      expect((await db.groupsDao.getById('g1'))!.archived, isTrue);
      expect((await db.categoriesDao.getById('work'))!.archived, isTrue);
      expect(
        (await db.categoriesDao.getById('personal_dev'))!.archived,
        isTrue,
      );
      // g1 소속이 아닌 daily 는 그대로.
      expect((await db.categoriesDao.getById('daily'))!.archived, isFalse);

      await groups.unarchive('g1');
      expect((await db.groupsDao.getById('g1'))!.archived, isFalse);
      expect((await db.categoriesDao.getById('work'))!.archived, isFalse);
      expect(
        (await db.categoriesDao.getById('personal_dev'))!.archived,
        isFalse,
      );
    });
  });

  group('active / archived 파생 provider', () {
    test('activeCategoriesProvider 는 보관 제외, archived 는 보관만', () async {
      final catCtrl = StreamController<List<Category>>();
      final c = ProviderContainer(
        overrides: [categoriesProvider.overrideWith((_) => catCtrl.stream)],
      );
      addTearDown(() async {
        c.dispose();
        await catCtrl.close();
      });
      c.listen(activeCategoriesProvider, (_, _) {});
      c.listen(archivedCategoriesProvider, (_, _) {});

      final archivedCat = Category.idea.copyWith(archived: true);
      catCtrl.add([Category.work, archivedCat]);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(activeCategoriesProvider).asData!.value.map((x) => x.id), [
        'work',
      ]);
      expect(
        c.read(archivedCategoriesProvider).asData!.value.map((x) => x.id),
        [Category.idea.id],
      );
      expect(c.read(archivedCategoryIdsProvider), {Category.idea.id});
    });

    test('activeGroupsProvider 는 보관 제외, archived 는 보관만', () async {
      final grpCtrl = StreamController<List<Group>>();
      final c = ProviderContainer(
        overrides: [groupsProvider.overrideWith((_) => grpCtrl.stream)],
      );
      addTearDown(() async {
        c.dispose();
        await grpCtrl.close();
      });
      c.listen(activeGroupsProvider, (_, _) {});
      c.listen(archivedGroupsProvider, (_, _) {});

      const active = Group(id: 'ga', label: '활성', colorValue: 0xFF2A66FF);
      const archived = Group(
        id: 'gb',
        label: '보관',
        colorValue: 0xFF2A66FF,
        archived: true,
      );
      grpCtrl.add([active, archived]);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(activeGroupsProvider).asData!.value.map((g) => g.id), [
        'ga',
      ]);
      expect(c.read(archivedGroupsProvider).asData!.value.map((g) => g.id), [
        'gb',
      ]);
    });
  });
}
