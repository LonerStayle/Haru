import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';

/// schemaVersion 7 → 8 migration 검증 (그룹/카테고리 보관 기능).
///
/// 시나리오:
///   1. raw sqlite3 in-memory 에 v7 시점 schema (categories/groups 에 archived 없음)
///      + 옛 카테고리·그룹 row 직접 insert. user_version = 7.
///   2. 같은 connection 을 AppDatabase 로 wrap → onUpgrade(7, 8) 발화 → categories /
///      groups 에 archived ALTER (default false).
///   3. 옛 row 보존 + archived 기본값 false + 컬럼 실제 추가 확인.
void main() {
  void seedV7Schema(sqlite.Database db) {
    db.execute('''
      CREATE TABLE "todos" (
        "id" TEXT NOT NULL,
        "title" TEXT NOT NULL,
        "category" TEXT NOT NULL,
        "due_at" TEXT NULL,
        "done_at" TEXT NULL,
        "created_at" TEXT NOT NULL,
        "updated_at" TEXT NOT NULL,
        "calendar_event_id" TEXT NULL,
        "parent_id" TEXT NULL,
        "type" TEXT NOT NULL DEFAULT 'task',
        "sort_order" INTEGER NOT NULL DEFAULT 0,
        "description" TEXT NULL,
        "end_at" TEXT NULL,
        "is_all_day" INTEGER NOT NULL DEFAULT 0,
        "time_anchor" TEXT NOT NULL DEFAULT 'start',
        "series_id" TEXT NULL,
        "recurrence_rule" TEXT NULL,
        "recurrence_end_at" TEXT NULL,
        "is_series_master" INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY ("id")
      );
    ''');
    db.execute('''
      CREATE TABLE "categories" (
        "id" TEXT NOT NULL,
        "label" TEXT NOT NULL,
        "icon_code_point" INTEGER NOT NULL,
        "color_value" INTEGER NOT NULL,
        "sort_order" INTEGER NOT NULL DEFAULT 0,
        "is_builtin" INTEGER NOT NULL DEFAULT 0,
        "created_at" TEXT NOT NULL,
        "group_id" TEXT NULL,
        PRIMARY KEY ("id")
      );
    ''');
    db.execute('''
      CREATE TABLE "groups" (
        "id" TEXT NOT NULL,
        "label" TEXT NOT NULL,
        "color_value" INTEGER NOT NULL,
        "sort_order" INTEGER NOT NULL DEFAULT 0,
        "is_builtin" INTEGER NOT NULL DEFAULT 0,
        "created_at" TEXT NOT NULL,
        PRIMARY KEY ("id")
      );
    ''');
    db.execute('''
      CREATE TABLE "outbox_entries" (
        "id" TEXT NOT NULL,
        "kind" TEXT NOT NULL,
        "todo_id" TEXT NOT NULL,
        "payload" TEXT NULL,
        "created_at" TEXT NOT NULL,
        PRIMARY KEY ("id")
      );
    ''');
    db.execute('PRAGMA user_version = 7');
  }

  test('v7 fixture → migrate → 옛 카테고리/그룹 보존 + archived 기본값 false', () async {
    final db = sqlite.sqlite3.openInMemory();
    addTearDown(db.close);
    seedV7Schema(db);

    db.execute('''
      INSERT INTO "categories" (id, label, icon_code_point, color_value, sort_order, is_builtin, created_at, group_id)
      VALUES ('cat-legacy', '외주', 61192, 4283215616, 0, 0, '2026-05-30T08:00:00.000Z', 'grp-legacy');
    ''');
    db.execute('''
      INSERT INTO "groups" (id, label, color_value, sort_order, is_builtin, created_at)
      VALUES ('grp-legacy', '지난회사', 4283215616, 0, 0, '2026-05-30T08:00:00.000Z');
    ''');

    final app = AppDatabase(NativeDatabase.opened(db));
    addTearDown(app.close);

    // 첫 query 가 migration 트리거 + 옛 데이터 보존.
    final cat = await app.categoriesDao.getById('cat-legacy');
    expect(cat, isNotNull);
    expect(cat!.label, '외주');
    expect(cat.groupId, 'grp-legacy');
    expect(cat.archived, isFalse, reason: '기존 카테고리는 archived 기본값 false');

    final grp = await app.groupsDao.getById('grp-legacy');
    expect(grp, isNotNull);
    expect(grp!.label, '지난회사');
    expect(grp.archived, isFalse, reason: '기존 그룹은 archived 기본값 false');

    // archived 컬럼이 실제로 추가됐는지 raw 검증.
    final catCols = db
        .select('PRAGMA table_info("categories");')
        .map((r) => r['name'] as String)
        .toSet();
    expect(
      catCols,
      contains('archived'),
      reason: 'onUpgrade 7→8 가 categories.archived 추가',
    );
    final grpCols = db
        .select('PRAGMA table_info("groups");')
        .map((r) => r['name'] as String)
        .toSet();
    expect(
      grpCols,
      contains('archived'),
      reason: 'onUpgrade 7→8 가 groups.archived 추가',
    );

    final version = db.select('PRAGMA user_version;').first['user_version'];
    expect(version, greaterThanOrEqualTo(8));
  });

  test('migrate 후 archived round-trip (upsert → read)', () async {
    final db = sqlite.sqlite3.openInMemory();
    addTearDown(db.close);
    seedV7Schema(db);

    final app = AppDatabase(NativeDatabase.opened(db));
    addTearDown(app.close);

    // 첫 접근으로 migration 발화.
    await app.categoriesDao.getAll();

    // archived=true 카테고리 / 그룹 upsert → 다시 읽어 값 보존 확인.
    await app.categoriesDao.upsert(
      const Category(
        id: 'cat-x',
        label: '보관대상',
        iconCodePoint: 0xe000,
        colorValue: 0xFF2A66FF,
        archived: true,
      ),
    );
    await app.groupsDao.upsert(
      const Group(
        id: 'grp-x',
        label: '보관그룹',
        colorValue: 0xFF2A66FF,
        archived: true,
      ),
    );

    final cat = await app.categoriesDao.getById('cat-x');
    expect(cat!.archived, isTrue);
    final grp = await app.groupsDao.getById('grp-x');
    expect(grp!.archived, isTrue);
  });
}
