import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/features/calendar/calendar_event.dart';

/// schemaVersion 10 → 11 migration 검증 (Microsoft 365 병존 — provider 구분 컬럼).
///
/// 시나리오:
///   1. raw sqlite3 in-memory 에 v10 시점 schema (calendar_provider /
///      calendar_ops.provider 가 아직 없음) 를 만들고 옛 row 를 직접 insert.
///      user_version = 10.
///   2. 같은 connection 을 AppDatabase 로 wrap → onUpgrade(10, 11) 발화.
///   3. 옛 row 가 보존되고 새 컬럼은 **null** 이다 — 코드가 null 을 구글로 읽으므로
///      기존 구글 연동이 그대로 굴러간다는 것이 이 마이그레이션의 핵심 계약이다.
///   4. 같은 onUpgrade 를 두 번 돌려도 예외가 없다 (PRAGMA 가드 idempotent).
void main() {
  void seedV10Schema(sqlite.Database db) {
    db.execute('''
      CREATE TABLE "todos" (
        "id" TEXT NOT NULL,
        "title" TEXT NOT NULL,
        "category" TEXT NOT NULL,
        "due_at" TEXT NULL,
        "done_at" TEXT NULL,
        "started_at" TEXT NULL,
        "created_at" TEXT NOT NULL,
        "updated_at" TEXT NOT NULL,
        "calendar_event_id" TEXT NULL,
        "calendar_id" TEXT NULL,
        "calendar_origin" TEXT NOT NULL DEFAULT 'app',
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
        "archived" INTEGER NOT NULL DEFAULT 0,
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
        "archived" INTEGER NOT NULL DEFAULT 0,
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
    db.execute('''
      CREATE TABLE "calendar_ops" (
        "id" TEXT NOT NULL,
        "kind" TEXT NOT NULL,
        "todo_id" TEXT NOT NULL,
        "event_id" TEXT NULL,
        "calendar_id" TEXT NOT NULL,
        "payload" TEXT NULL,
        "attempts" INTEGER NOT NULL DEFAULT 0,
        "last_error" TEXT NULL,
        "next_attempt_at" TEXT NULL,
        "created_at" TEXT NOT NULL,
        PRIMARY KEY ("id")
      );
    ''');
    db.execute('PRAGMA user_version = 10');
  }

  test('v10 fixture → migrate → 옛 row 보존 + provider 컬럼 신규(null)', () async {
    final db = sqlite.sqlite3.openInMemory();
    addTearDown(db.close);
    seedV10Schema(db);

    db.execute('''
      INSERT INTO "todos" (
        id, title, category, created_at, updated_at,
        calendar_event_id, calendar_id, calendar_origin
      )
      VALUES (
        'v10-task', '구글에 묶인 옛 todo', 'work',
        '2026-08-10T08:00:00.000Z', '2026-08-10T08:00:00.000Z',
        'ev-1', 'primary', 'gcal'
      );
    ''');
    db.execute('''
      INSERT INTO "calendar_ops" (
        id, kind, todo_id, event_id, calendar_id, payload, attempts,
        last_error, next_attempt_at, created_at
      )
      VALUES (
        'op-old', 'update', 'v10-task', 'ev-1', 'primary', NULL, 0,
        NULL, NULL, '2026-08-10T08:00:00.000Z'
      );
    ''');

    final app = AppDatabase(NativeDatabase.opened(db));
    addTearDown(app.close);

    final row = (await app.select(app.todos).get()).singleWhere(
      (r) => r.id == 'v10-task',
    );
    expect(row.title, '구글에 묶인 옛 todo');
    expect(row.calendarOrigin, 'gcal');
    expect(
      row.calendarProvider,
      isNull,
      reason: 'provider 컬럼이 생기기 전 데이터는 null 이고, 코드가 그것을 구글로 읽는다',
    );

    // 옛 큐 항목도 null provider → 구글 동기화가 그대로 집어간다.
    final due = await app.calendarOpsDao.dueOps(
      DateTime.utc(2026, 8, 11),
      provider: CalendarProvider.google,
    );
    expect(due.single.id, 'op-old');
    expect(due.single.provider, isNull);

    // Microsoft 쪽은 이 옛 항목을 절대 집어가면 안 된다.
    final msDue = await app.calendarOpsDao.dueOps(
      DateTime.utc(2026, 8, 11),
      provider: CalendarProvider.microsoft,
    );
    expect(msDue, isEmpty);

    final todoCols = db
        .select('PRAGMA table_info("todos");')
        .map((r) => r['name'] as String)
        .toSet();
    expect(todoCols, contains('calendar_provider'));

    final opCols = db
        .select('PRAGMA table_info("calendar_ops");')
        .map((r) => r['name'] as String)
        .toSet();
    expect(opCols, contains('provider'));

    final version = db.select('PRAGMA user_version;').first['user_version'];
    expect(version, greaterThanOrEqualTo(11));
  });

  test('migrate 후 신규 row — calendarProvider round-trip', () async {
    final db = sqlite.sqlite3.openInMemory();
    addTearDown(db.close);
    seedV10Schema(db);

    final app = AppDatabase(NativeDatabase.opened(db));
    addTearDown(app.close);

    await app
        .into(app.todos)
        .insertOnConflictUpdate(
          TodosCompanion.insert(
            id: 'ms-task',
            title: 'Teams 회의',
            category: 'work',
            createdAt: DateTime.utc(2026, 8, 15),
            updatedAt: DateTime.utc(2026, 8, 15),
            calendarId: const Value('ms-cal-1'),
            calendarOrigin: const Value('msgraph'),
            calendarProvider: const Value('microsoft'),
          ),
        );

    final got = await (app.select(
      app.todos,
    )..where((t) => t.id.equals('ms-task'))).getSingle();
    expect(got.calendarProvider, 'microsoft');
    expect(got.calendarOrigin, 'msgraph');
  });

  test('onUpgrade(10,11) 를 두 번 실행해도 예외가 없다 (idempotent)', () async {
    final db = sqlite.sqlite3.openInMemory();
    addTearDown(db.close);
    seedV10Schema(db);

    final app = AppDatabase(NativeDatabase.opened(db));
    addTearDown(app.close);

    await app.select(app.todos).get();

    final migrator = app.createMigrator();
    await expectLater(app.migration.onUpgrade(migrator, 10, 11), completes);

    final todoCols = db
        .select('PRAGMA table_info("todos");')
        .map((r) => r['name'] as String)
        .toSet();
    expect(todoCols, contains('calendar_provider'));
  });
}
