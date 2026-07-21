import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/category.dart' as domain;
import 'categories_dao.dart';
import 'groups_dao.dart';
import 'outbox_dao.dart';
import 'todos_dao.dart';

part 'app_database.g.dart';

/// `todos` SQLite 테이블.
///
/// Drift 의 row 데이터 클래스는 도메인 [Todo] 와 충돌하지 않도록 `TodoRow` 로 강제.
/// 매핑은 [TodosDao] 가 담당한다.
@DataClassName('TodoRow')
class Todos extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  // Category.id (snake_case, e.g. 'personal_dev') 저장. enum 명 직접 저장 X.
  TextColumn get category => text()();
  DateTimeColumn get dueAt => dateTime().nullable()();
  DateTimeColumn get doneAt => dateTime().nullable()();
  // 진행중(in-progress) 시작 시각. 값 있고 done_at 이 null 이면 진행중. 완료 시 null.
  DateTimeColumn get startedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get calendarEventId => text().nullable()();
  // v1.1 — 트리 노드 부모 id. null = 카테고리 직속 root.
  // FK 제약은 두지 않음 — Supabase 양방향 동기화 도중 일시적 dangling 가능 + LWW 가 자정 처리.
  TextColumn get parentId => text().nullable()();
  // v1.1 — TodoType.name ('task' | 'note'). 기본 'task'.
  TextColumn get type => text().withDefault(const Constant('task'))();
  // v1.1 — 같은 parent 내 사용자 정의 순서. 작은 값 먼저. drag-reorder 는 v1.2 후속.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  // v1.2 — 상세 메모 (long text). nullable.
  TextColumn get description => text().nullable()();
  // fast-tasks (날짜·기간) — 기간 모드 종료 시각. 단일 모드면 null.
  DateTimeColumn get endAt => dateTime().nullable()();
  // fast-tasks — true 면 시간 미표시 (하루종일).
  BoolColumn get isAllDay => boolean().withDefault(const Constant(false))();
  // fast-tasks — 단일·시간 모드에서 dueAt 이 '시작'('start')/'마감'('end')인지.
  TextColumn get timeAnchor => text().withDefault(const Constant('start'))();
  // date-repeat (v7) — 반복 시리즈 id. 마스터=자기 id, 인스턴스=마스터 id, null=일반.
  TextColumn get seriesId => text().nullable()();
  // date-repeat (v7) — 반복 규칙 직렬화(RecurrenceRule.encode). 마스터에만.
  TextColumn get recurrenceRule => text().nullable()();
  // date-repeat (v7) — 반복 종료일. 마스터에만. null=무한.
  DateTimeColumn get recurrenceEndAt => dateTime().nullable()();
  // date-repeat (v7) — true=규칙 보유 숨김 마스터(목록 제외, 캘린더 RRULE 소유).
  BoolColumn get isSeriesMaster =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// v1.2 — 카테고리 테이블. 5 builtin 도 row 로 저장되어 사용자가 추가 / 삭제 가능.
///
/// id 는 사용자 카테고리는 uuid, builtin 은 'work' / 'personal_dev' / 'daily' /
/// 'longterm' / 'idea' 로 유지 (옛 todos.category id 와 호환).
///
/// 정렬은 (sortOrder asc, createdAt asc) — 같은 sortOrder 면 먼저 만든 게 위.
@DataClassName('CategoryRow')
class Categories extends Table {
  TextColumn get id => text()();
  TextColumn get label => text()();
  // Material Icons 폰트의 codepoint. Color.value 와 함께 row 직접 저장 — UI 가
  // category.icon / category.color getter 로 IconData / Color 재구성.
  IntColumn get iconCodePoint => integer()();
  IntColumn get colorValue => integer()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isBuiltin => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  // v1.3 — 소속 그룹 (Groups.id). null = '미분류'. FK 제약 두지 않음 (Supabase
  // 동기화 중 일시적 dangling 허용 + UI 가 미지 groupId 를 미분류로 안전 fallback).
  TextColumn get groupId => text().nullable()();
  // v1.6 — 보관(archive) 플래그. true 면 활성 화면에서 숨김 (데이터 보존).
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// v1.3 — 그룹 테이블 (카테고리 상위 '큰분류'). 전부 사용자 정의 (builtin seed 없음).
///
/// 구조: 그룹 > 카테고리 > todo 트리. 사이드바가 그룹 단위로 접히고, groupId 가
/// null 인 카테고리는 최상단 '미분류' 섹션에 모인다.
///
/// 정렬은 (sortOrder asc, createdAt asc) — Categories 와 동일.
@DataClassName('GroupRow')
class Groups extends Table {
  TextColumn get id => text()();
  TextColumn get label => text()();
  IntColumn get colorValue => integer()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isBuiltin => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  // v1.6 — 보관(archive) 플래그. true 면 사이드바에서 숨김 + 소속 카테고리 cascade 보관.
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 오프라인/연결 실패 시 원격 push 대기열. FIFO 로 순서 보존.
/// [SyncingTodoRepository] 가 local mutation 후 enqueue, 재연결 시 _tryFlush 가 비움.
@DataClassName('OutboxRow')
class OutboxEntries extends Table {
  TextColumn get id => text()(); // outbox entry id (uuid)
  // 'upsert' | 'delete'
  TextColumn get kind => text()();
  // 대상 todo id (delete 시에도 식별용)
  TextColumn get todoId => text()();
  // upsert 일 때만 — Todo JSON (jsonEncode). delete 일 때 null.
  TextColumn get payload => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [Todos, Categories, Groups, OutboxEntries],
  daos: [TodosDao, CategoriesDao, GroupsDao, OutboxDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openOnDisk());

  /// In-memory 인스턴스 — 테스트 / 일회성 환경 용.
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 9;

  /// `storeDateTimeAsText: true` — DateTime 을 ISO 8601 text 로 저장.
  /// 기본 (unix int) 은 fetch 시 항상 local time 으로 변환되어 UTC↔local 구분을 잃는다.
  /// UTC 를 보존해야 Supabase 동기화 시 timezone 충돌이 없다.
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  /// schemaVersion 변경 history:
  /// - v1: 초기 (todos + outboxEntries)
  /// - v2: todos 에 parent_id / type / sort_order 컬럼 추가 (v1.1 — 트리 / 메모)
  /// - v3: categories 테이블 신규 + 5 builtin seed (v1.2 — 카테고리 fully 동적)
  /// - v4: todos.description 컬럼 보강. (v3 마이그레이션 중에 description 을 추가했지만
  ///   schemaVersion 을 올리지 않아, "v3 으로 이미 올라갔지만 description 컬럼이 없는"
  ///   중간 상태 DB 가 존재했다. v4 의 idempotent 가드로 그 DB 를 복구한다.)
  /// - v5: todos 에 end_at / is_all_day / time_anchor 컬럼 추가
  ///   (fast-tasks — 날짜·기간 모델). PRAGMA 가드로 idempotent.
  /// - v6: groups 테이블 신규 + categories.group_id 컬럼 (그룹 계층). 가드 idempotent.
  /// - v7: todos 에 series_id / recurrence_rule / recurrence_end_at / is_series_master
  ///   추가 (date-repeat — 날짜 반복). PRAGMA 가드로 idempotent.
  /// - v8: categories.archived / groups.archived 컬럼 추가 (보관 기능). 가드 idempotent.
  /// - v9: todos.started_at 컬럼 추가 (진행중 3-상태). PRAGMA 가드로 idempotent.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      // 신규 DB — 5 builtin 카테고리 seed.
      await _seedBuiltinCategories();
    },
    onUpgrade: (m, from, to) async {
      // 1 → 2: v1.1 트리 / 메모 모델용 3 컬럼 추가.
      // withDefault('task') / withDefault(0) 가 ALTER TABLE 시 자동 적용 (Drift) —
      // 기존 row 도 type='task' / sort_order=0 으로 채워진다. parent_id 는 nullable
      // 이므로 NULL 로 채워짐. RLS / Supabase 별도 migration 은 schema.sql 의 ALTER 안내.
      if (from < 2) {
        await m.addColumn(todos, todos.parentId);
        await m.addColumn(todos, todos.type);
        await m.addColumn(todos, todos.sortOrder);
      }
      // 2 → 3: categories 테이블 신규 + 5 builtin seed + todos.description ALTER.
      if (from < 3) {
        await m.createTable(categories);
        await m.addColumn(todos, todos.description);
        await _seedBuiltinCategories();
      }
      // 3 → 4: description 컬럼이 빠진 중간 상태 v3 DB 복구.
      // 이미 description 이 있으면 (정상 v3) ALTER 가 중복되므로, 실제 컬럼 존재
      // 여부를 PRAGMA 로 확인 후에만 추가한다 (idempotent).
      if (from == 3) {
        final info = await customSelect("PRAGMA table_info('todos')").get();
        final hasDescription = info.any((r) => r.data['name'] == 'description');
        if (!hasDescription) {
          await m.addColumn(todos, todos.description);
        }
      }
      // 4 → 5: 날짜·기간 모델 3 컬럼 추가. 기존 PRAGMA 가드 패턴으로 idempotent —
      // 이미 컬럼이 있으면 (부분 마이그레이션 / 다중 디바이스) 건너뛴다.
      if (from < 5) {
        final info = await customSelect("PRAGMA table_info('todos')").get();
        bool hasCol(String name) => info.any((r) => r.data['name'] == name);
        if (!hasCol('end_at')) {
          await m.addColumn(todos, todos.endAt);
        }
        if (!hasCol('is_all_day')) {
          await m.addColumn(todos, todos.isAllDay);
        }
        if (!hasCol('time_anchor')) {
          await m.addColumn(todos, todos.timeAnchor);
        }
      }
      // 5 → 6: groups 테이블 신규 + categories.group_id ALTER. (그룹 계층)
      // 둘 다 PRAGMA / sqlite_master 가드로 idempotent — 부분 적용된 중간 상태 DB 도
      // 안전하게 복구. groups seed 는 없음 (모든 그룹이 사용자 정의).
      if (from < 6) {
        final tables = await customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='groups'",
        ).get();
        if (tables.isEmpty) {
          await m.createTable(groups);
        }
        final catInfo = await customSelect(
          "PRAGMA table_info('categories')",
        ).get();
        final hasGroupId = catInfo.any((r) => r.data['name'] == 'group_id');
        if (!hasGroupId) {
          await m.addColumn(categories, categories.groupId);
        }
      }
      // 6 → 7: 날짜 반복 4 컬럼 추가. PRAGMA 가드로 idempotent (부분 적용 DB 안전).
      if (from < 7) {
        final info = await customSelect("PRAGMA table_info('todos')").get();
        bool hasCol(String name) => info.any((r) => r.data['name'] == name);
        if (!hasCol('series_id')) {
          await m.addColumn(todos, todos.seriesId);
        }
        if (!hasCol('recurrence_rule')) {
          await m.addColumn(todos, todos.recurrenceRule);
        }
        if (!hasCol('recurrence_end_at')) {
          await m.addColumn(todos, todos.recurrenceEndAt);
        }
        if (!hasCol('is_series_master')) {
          await m.addColumn(todos, todos.isSeriesMaster);
        }
      }
      // 7 → 8: categories.archived / groups.archived 추가 (보관 기능).
      // 각 테이블 PRAGMA 가드로 idempotent — 부분 적용/다중 디바이스 안전.
      if (from < 8) {
        final catInfo = await customSelect(
          "PRAGMA table_info('categories')",
        ).get();
        if (!catInfo.any((r) => r.data['name'] == 'archived')) {
          await m.addColumn(categories, categories.archived);
        }
        final grpInfo = await customSelect("PRAGMA table_info('groups')").get();
        if (!grpInfo.any((r) => r.data['name'] == 'archived')) {
          await m.addColumn(groups, groups.archived);
        }
      }
      // 8 → 9: todos.started_at 추가 (진행중 3-상태). PRAGMA 가드로 idempotent.
      if (from < 9) {
        final info = await customSelect("PRAGMA table_info('todos')").get();
        if (!info.any((r) => r.data['name'] == 'started_at')) {
          await m.addColumn(todos, todos.startedAt);
        }
      }
    },
  );

  /// 5 builtin 카테고리를 categories 에 seed.
  /// [InsertMode.insertOrIgnore] — 이미 같은 id 가 있으면 무시 (사용자가 builtin 을
  /// 삭제했다가 다른 디바이스에서 다시 migrate 가 일어나도 conflict 없이 idempotent).
  /// createdAt 은 epoch 0 으로 통일 — sortOrder asc 우선이므로 정렬 영향 없음.
  Future<void> _seedBuiltinCategories() async {
    final seedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    for (final c in domain.Category.builtinSeeds) {
      await into(categories).insert(
        CategoriesCompanion.insert(
          id: c.id,
          label: c.label,
          iconCodePoint: c.iconCodePoint,
          colorValue: c.colorValue,
          sortOrder: Value(c.sortOrder),
          isBuiltin: Value(c.isBuiltin),
          createdAt: seedAt,
        ),
        mode: InsertMode.insertOrIgnore,
      );
    }
  }

  static QueryExecutor _openOnDisk() {
    return LazyDatabase(() async {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'solo_todo.sqlite'));
      return NativeDatabase.createInBackground(file);
    });
  }

  /// 사용자 데이터 전체 삭제 (todos + outbox). signOut 또는 다른 user 로 전환 시 호출.
  /// 단일 사용자 비전이지만, sign-out 후 다른 이메일로 로그인 시 옛 데이터 노출 방지.
  Future<void> clearAllUserData() async {
    await transaction(() async {
      await delete(todos).go();
      await delete(outboxEntries).go();
    });
  }
}
