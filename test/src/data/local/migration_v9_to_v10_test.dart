import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:solo_todo/src/data/local/app_database.dart';

/// schemaVersion 9 → 10 migration 검증 (Google Calendar 연동 — todos 2컬럼 +
/// calendar_ops 큐 테이블 신규).
///
/// 시나리오:
///   1. raw sqlite3 in-memory 에 v9 시점 schema (todos 20 컬럼 + categories +
///      groups + outbox_entries, calendar_id/calendar_origin/calendar_ops 없음)
///      만들고 옛 todos row 를 직접 insert. user_version = 9.
///   2. 같은 connection 을 AppDatabase 로 wrap → onUpgrade(9, 10) 발화 →
///      todos 에 calendar_id / calendar_origin ALTER + calendar_ops CREATE TABLE.
///   3. 옛 row 보존 + calendar_origin 기본값 'app' + 컬럼/테이블 실제 생성 확인.
///   4. 같은 onUpgrade(9, 10) 로직을 같은 커넥션에 두 번 실행해도 예외가 없다
///      (PRAGMA / sqlite_master 가드가 idempotent 함을 직접 검증).
void main() {
  void seedV9Schema(sqlite.Database db) {
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
    db.execute('PRAGMA user_version = 9');
  }

  test('v9 fixture → migrate → 옛 row 보존 + calendar 컬럼/테이블 신규', () async {
    final db = sqlite.sqlite3.openInMemory();
    addTearDown(db.close);
    seedV9Schema(db);

    db.execute('''
      INSERT INTO "todos" (
        id, title, category, due_at, done_at, started_at, created_at, updated_at,
        calendar_event_id, parent_id, type, sort_order, description, end_at,
        is_all_day, time_anchor, series_id, recurrence_rule, recurrence_end_at,
        is_series_master
      )
      VALUES (
        'v9-task', '옛 회사 todo', 'work',
        '2026-08-10T09:00:00.000Z', NULL, NULL,
        '2026-08-10T08:00:00.000Z', '2026-08-10T08:00:00.000Z',
        NULL, NULL, 'task', 0, NULL, NULL, 0, 'start', NULL, NULL, NULL, 0
      );
    ''');

    final app = AppDatabase(NativeDatabase.opened(db));
    addTearDown(app.close);

    // 첫 query 가 migration 을 트리거 — row 레벨(TodoRow)로 직접 확인해
    // (아직 TodosDao 도메인 매핑에는 반영 안 된) 신규 컬럼 값을 검증한다.
    final rows = await app.select(app.todos).get();
    final row = rows.singleWhere((r) => r.id == 'v9-task');
    expect(row.title, '옛 회사 todo');
    expect(
      row.calendarOrigin,
      'app',
      reason: '기존 row 는 calendar_origin 기본값 app 으로 채워져야 함',
    );
    expect(row.calendarId, isNull);

    // 컬럼/테이블이 실제로 추가됐는지 raw 검증.
    final todoCols = db
        .select('PRAGMA table_info("todos");')
        .map((r) => r['name'] as String)
        .toSet();
    expect(
      todoCols,
      containsAll(['calendar_id', 'calendar_origin']),
      reason: 'onUpgrade 9→10 가 todos 에 2 컬럼을 추가해야 함',
    );

    final calendarOpsTables = db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='calendar_ops';",
    );
    expect(
      calendarOpsTables,
      isNotEmpty,
      reason: 'onUpgrade 9→10 가 calendar_ops 테이블을 생성해야 함',
    );

    final version = db.select('PRAGMA user_version;').first['user_version'];
    expect(version, greaterThanOrEqualTo(10));
  });

  test(
    'migrate 후 신규 todo row — calendarId/calendarOrigin round-trip',
    () async {
      final db = sqlite.sqlite3.openInMemory();
      addTearDown(db.close);
      seedV9Schema(db);

      final app = AppDatabase(NativeDatabase.opened(db));
      addTearDown(app.close);

      await app
          .into(app.todos)
          .insertOnConflictUpdate(
            TodosCompanion.insert(
              id: 'new-cal',
              title: '캘린더 연동 테스트',
              category: 'work',
              createdAt: DateTime.utc(2026, 8, 15),
              updatedAt: DateTime.utc(2026, 8, 15),
              calendarId: const Value('primary'),
              calendarOrigin: const Value('gcal'),
            ),
          );

      final got = await (app.select(
        app.todos,
      )..where((t) => t.id.equals('new-cal'))).getSingle();
      expect(got.calendarId, 'primary');
      expect(got.calendarOrigin, 'gcal');
    },
  );

  test('migrate 후 calendar_ops CRUD 정상 동작', () async {
    final db = sqlite.sqlite3.openInMemory();
    addTearDown(db.close);
    seedV9Schema(db);

    final app = AppDatabase(NativeDatabase.opened(db));
    addTearDown(app.close);

    await app.calendarOpsDao.enqueue(
      CalendarOpRow(
        id: 'op-1',
        kind: 'create',
        todoId: 'new-cal',
        eventId: null,
        calendarId: 'primary',
        payload: '{"title":"캘린더 연동 테스트"}',
        attempts: 0,
        lastError: null,
        nextAttemptAt: null,
        createdAt: DateTime.utc(2026, 8, 15, 9),
      ),
    );

    final due = await app.calendarOpsDao.dueOps(DateTime.utc(2026, 8, 15, 10));
    expect(due, hasLength(1));
    expect(due.single.todoId, 'new-cal');
  });

  test('onUpgrade(9,10) 를 같은 커넥션에 두 번 실행해도 예외가 없다 (idempotent)', () async {
    final db = sqlite.sqlite3.openInMemory();
    addTearDown(db.close);
    seedV9Schema(db);

    final app = AppDatabase(NativeDatabase.opened(db));
    addTearDown(app.close);

    // 첫 접근 — 자연 마이그레이션 9→10 발화 (user_version 이 10 으로 갱신됨).
    await app.select(app.todos).get();
    final firstVersion = db
        .select('PRAGMA user_version;')
        .first['user_version'];
    expect(firstVersion, greaterThanOrEqualTo(10));

    // 같은 onUpgrade(9, 10) 로직을 수동으로 한 번 더 실행 — PRAGMA / sqlite_master
    // 가드가 이미 존재하는 컬럼·테이블을 건너뛰어야 하며 예외가 나면 안 된다.
    final migrator = app.createMigrator();
    await expectLater(app.migration.onUpgrade(migrator, 9, 10), completes);

    // 재실행 후에도 데이터/스키마가 정상 상태로 유지된다.
    final todoCols = db
        .select('PRAGMA table_info("todos");')
        .map((r) => r['name'] as String)
        .toSet();
    expect(todoCols, containsAll(['calendar_id', 'calendar_origin']));
    final calendarOpsTables = db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='calendar_ops';",
    );
    expect(calendarOpsTables, isNotEmpty);
  });
}
