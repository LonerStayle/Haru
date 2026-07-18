import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_categories_repository.dart';
import 'package:solo_todo/src/data/local/local_groups_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';

/// GroupsController 검증 — in-memory DB + LocalGroupsRepository.
///
/// 삭제 정책 (MVP): 차단 없음. 그룹 삭제 시 속한 카테고리는 미분류(groupId=null)로
/// 이동하고 그룹 row 만 지운다. todo / 카테고리 데이터는 절대 유실되지 않는다.
void main() {
  group('GroupsController', () {
    late AppDatabase db;
    late GroupsController controller;

    setUp(() {
      db = AppDatabase.memory();
      controller = GroupsController(
        LocalGroupsRepository(db.groupsDao),
        LocalCategoriesRepository(db.categoriesDao),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('add — 새 그룹 추가 + watchAll 에 반영', () async {
      await controller.add(
        const Group(id: 'grp-a', label: '회사', colorValue: 0xFF2A66FF),
      );
      final list = await db.groupsDao.watchAll().first;
      expect(list.length, 1);
      expect(list.single.id, 'grp-a');
      expect(list.single.label, '회사');
    });

    test('delete — 속한 카테고리가 없으면 그냥 그룹만 삭제', () async {
      await controller.add(
        const Group(id: 'grp-a', label: '회사', colorValue: 0xFF2A66FF),
      );
      final affected = await controller.delete('grp-a');
      expect(affected, 1);
      expect(await db.groupsDao.getById('grp-a'), isNull);
    });

    test('delete — 속한 카테고리는 미분류(groupId=null)로 이동 후 그룹만 삭제', () async {
      await controller.add(
        const Group(id: 'grp-a', label: '회사', colorValue: 0xFF2A66FF),
      );
      // work / daily 를 grp-a 에 배정, idea 는 다른 그룹.
      await db.categoriesDao.upsert(Category.work.copyWith(groupId: 'grp-a'));
      await db.categoriesDao.upsert(Category.daily.copyWith(groupId: 'grp-a'));
      await db.categoriesDao.upsert(Category.idea.copyWith(groupId: 'grp-z'));

      await controller.delete('grp-a');

      // 그룹은 삭제됨.
      expect(await db.groupsDao.getById('grp-a'), isNull);
      // 속했던 카테고리는 미분류로 이동 (삭제되지 않음).
      expect((await db.categoriesDao.getById('work'))!.groupId, isNull);
      expect((await db.categoriesDao.getById('daily'))!.groupId, isNull);
      // 카테고리 자체는 보존 (5 builtin 그대로).
      final cats = await db.categoriesDao.watchAll().first;
      expect(cats.length, 5);
      // 다른 그룹 카테고리는 영향 없음.
      expect((await db.categoriesDao.getById('idea'))!.groupId, 'grp-z');
    });

    test('delete — 존재하지 않는 id 면 idempotent (0 반환)', () async {
      final affected = await controller.delete('grp-none');
      expect(affected, 0);
    });
  });
}
