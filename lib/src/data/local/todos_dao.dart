import 'package:drift/drift.dart';

import '../../domain/category.dart';
import '../../domain/policies/visibility_policy.dart';
import '../../domain/todo.dart' as domain;
import 'app_database.dart';

part 'todos_dao.g.dart';

/// Todo CRUD + 조회 스트림.
///
/// 모든 외부 인터페이스는 도메인 [domain.Todo] 만 노출. Drift 의 [TodoRow] 는 내부 매핑용.
///
/// v1.2 — 카테고리가 동적 row 가 되어 todos.category 는 id 문자열만 저장한다.
/// 따라서 조회 시 categories 테이블과 left-join 하여 label/color/icon 을 복원한다.
/// (builtin id 는 join 실패해도 [Category.tryFromId] 로 복원, 그래도 미지면 placeholder.)
@DriftAccessor(tables: [Todos, Categories])
class TodosDao extends DatabaseAccessor<AppDatabase> with _$TodosDaoMixin {
  TodosDao(super.db);

  /// todos ⟕ categories left-join select 빌더. 모든 조회가 공유.
  JoinedSelectStatement<HasResultSet, dynamic> _joined() {
    return select(todos).join([
      leftOuterJoin(categories, categories.id.equalsExp(todos.category)),
    ]);
  }

  Future<domain.Todo?> getById(String id) async {
    final q = _joined()..where(todos.id.equals(id));
    final row = await q.getSingleOrNull();
    return row == null ? null : _mapJoined(row);
  }

  /// id 기준 upsert (없으면 insert, 있으면 전체 update).
  Future<void> upsert(domain.Todo todo) {
    return into(todos).insertOnConflictUpdate(_domainToCompanion(todo));
  }

  Future<int> deleteById(String id) {
    return (delete(todos)..where((t) => t.id.equals(id))).go();
  }

  /// Task B 정렬 키 — `sortOrder asc, createdAt desc, id asc`.
  /// 불변식: **작은 sortOrder = 위쪽**. 같은 sortOrder 면 최근 생성이 위로.
  /// today 등에서 '미체크 먼저' 가 필요하면 호출자가 doneAt term 을 앞에 prepend.
  ///
  /// updatedAt 은 **의도적으로 키에서 뺐다** — 체크/진행중 토글이나 동기화 반영 같은
  /// 사소한 갱신만으로 sortOrder 동률 그룹(마이그레이션 이전 데이터는 전부 0) 안에서
  /// 자리가 튀었다. 순서는 드래그 재정렬 · 신규 추가 · 실제 내용 편집으로만 바뀐다.
  /// 마지막 id asc 는 createdAt 까지 같을 때의 결정적 tie-break — 없으면 같은 조회를
  /// 반복해도 SQLite 가 순서를 보장하지 않아 목록이 조회마다 뒤바뀔 수 있다.
  List<OrderingTerm> _sortKey() => [
    OrderingTerm(expression: todos.sortOrder, mode: OrderingMode.asc),
    OrderingTerm(expression: todos.createdAt, mode: OrderingMode.desc),
    OrderingTerm(expression: todos.id, mode: OrderingMode.asc),
  ];

  /// 미체크 우선 + Task B 정렬 키.
  ///
  /// 미체크(doneAt IS NULL)가 항상 먼저 오도록 NULLS FIRST 후 [_sortKey] 적용.
  Stream<List<domain.Todo>> watchAll() {
    final q = _joined()
      ..orderBy([
        OrderingTerm(
          expression: todos.doneAt,
          mode: OrderingMode.asc,
          nulls: NullsOrder.first,
        ),
        ..._sortKey(),
      ]);
    return q.watch().map((rows) => rows.map(_mapJoined).toList());
  }

  Stream<List<domain.Todo>> watchByCategory(Category category) {
    final q = _joined()
      ..where(todos.category.equals(category.id))
      ..orderBy([
        OrderingTerm(
          expression: todos.doneAt,
          mode: OrderingMode.asc,
          nulls: NullsOrder.first,
        ),
        ..._sortKey(),
      ]);
    return q.watch().map((rows) => rows.map(_mapJoined).toList());
  }

  /// 오늘 화면용 스트림.
  ///
  /// [VisibilityPolicy] 가 도메인 정책의 단일 출처이므로, SQL 측 필터링 대신
  /// 클라이언트에서 한 번에 적용한다. 1인 사용자 데이터 양 (~수백 건) 기준 성능 충분.
  Stream<List<domain.Todo>> watchToday(DateTime Function() now) {
    return watchAll().map(
      (all) =>
          all.where((t) => VisibilityPolicy.isVisibleToday(t, now())).toList(),
    );
  }

  /// 특정 parent 의 직속 자식들 stream — outline view 의 펼침에 사용.
  /// 정렬: Task B 키 (sortOrder asc → createdAt desc → id asc). note 포함.
  Stream<List<domain.Todo>> watchChildrenOf(String parentId) {
    final q = _joined()
      ..where(todos.parentId.equals(parentId))
      ..orderBy(_sortKey());
    return q.watch().map((rows) => rows.map(_mapJoined).toList());
  }

  /// 특정 카테고리의 root 노드들 stream (parent_id IS NULL).
  Stream<List<domain.Todo>> watchRootsOfCategory(Category category) {
    final q = _joined()
      ..where(todos.parentId.isNull() & todos.category.equals(category.id))
      ..orderBy(_sortKey());
    return q.watch().map((rows) => rows.map(_mapJoined).toList());
  }

  /// Task B — 같은 형제 집합(같은 parentId + category)의 최소 sortOrder.
  ///
  /// 신규 생성 / 시트 수정 시 `min - 1` 로 맨 위에 올리기 위해 사용. 형제가 없으면 null.
  /// parentId 가 null 이면 root 형제 (parent_id IS NULL) 를 대상으로 한다.
  /// **불변식: 작은 sortOrder = 위.**
  Future<int?> minSiblingSortOrder({
    required String categoryId,
    String? parentId,
  }) async {
    final minExpr = todos.sortOrder.min();
    final q = selectOnly(todos)..addColumns([minExpr]);
    if (parentId == null) {
      q.where(todos.parentId.isNull() & todos.category.equals(categoryId));
    } else {
      q.where(
        todos.parentId.equals(parentId) & todos.category.equals(categoryId),
      );
    }
    final row = await q.getSingleOrNull();
    return row?.read(minExpr);
  }

  // --- 매핑 헬퍼 ---------------------------------------------------------

  /// join 결과 한 행 → 도메인 [domain.Todo]. categories 행이 있으면 그걸로 카테고리
  /// 복원, 없으면 builtin fallback, 그래도 미지면 placeholder.
  domain.Todo _mapJoined(TypedResult row) {
    final t = row.readTable(todos);
    final c = row.readTableOrNull(categories);
    return _rowToDomain(t, c);
  }

  domain.Todo _rowToDomain(TodoRow row, CategoryRow? catRow) {
    return domain.Todo(
      id: row.id,
      title: row.title,
      category: _resolveCategory(row.category, catRow),
      dueAt: row.dueAt,
      doneAt: row.doneAt,
      startedAt: row.startedAt,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      calendarEventId: row.calendarEventId,
      parentId: row.parentId,
      type: _parseType(row.type),
      sortOrder: row.sortOrder,
      description: row.description,
      endAt: row.endAt,
      isAllDay: row.isAllDay,
      timeAnchor: row.timeAnchor,
      seriesId: row.seriesId,
      recurrenceRule: row.recurrenceRule,
      recurrenceEndAt: row.recurrenceEndAt,
      isSeriesMaster: row.isSeriesMaster,
    );
  }

  /// 카테고리 복원 우선순위:
  /// 1. join 된 categories 행 (사용자 추가 카테고리의 정확한 label/color/icon)
  /// 2. builtin seed (categories 테이블이 아직 seed 안 된 옛 환경 대비)
  /// 3. placeholder — dangling category id (카테고리가 삭제됐는데 todo 가 남은 경우 등).
  ///    크래시 대신 회색 "기타" 로 안전 표시.
  static Category _resolveCategory(String id, CategoryRow? catRow) {
    if (catRow != null) {
      return Category(
        id: catRow.id,
        label: catRow.label,
        iconCodePoint: catRow.iconCodePoint,
        colorValue: catRow.colorValue,
        sortOrder: catRow.sortOrder,
        isBuiltin: catRow.isBuiltin,
        // groupId 를 빠뜨리면 todo.category.groupId 가 항상 null 이 되어 '오늘' 섹션 /
        // 타임라인의 그룹 라벨이 표시되지 않는다. join 된 row 의 소속 그룹을 그대로 보존.
        groupId: catRow.groupId,
      );
    }
    return Category.tryFromId(id) ?? _placeholderCategory(id);
  }

  /// 미지 / dangling 카테고리 id 의 안전 placeholder. 회색 + label_outline 아이콘.
  static Category _placeholderCategory(String id) => Category(
    id: id,
    label: '기타',
    iconCodePoint: 0xe893, // label_outline
    colorValue: 0xFF9E9E9E, // gray
    sortOrder: 9999,
    isBuiltin: false,
  );

  /// 옛 row 또는 외부에서 미지의 type 문자열이 들어와도 안전하게 task 로 fallback.
  static domain.TodoType _parseType(String raw) {
    switch (raw) {
      case 'note':
        return domain.TodoType.note;
      case 'task':
      default:
        return domain.TodoType.task;
    }
  }

  TodosCompanion _domainToCompanion(domain.Todo t) {
    return TodosCompanion(
      id: Value(t.id),
      title: Value(t.title),
      category: Value(t.category.id),
      dueAt: Value(t.dueAt),
      doneAt: Value(t.doneAt),
      startedAt: Value(t.startedAt),
      createdAt: Value(t.createdAt),
      // updatedAt 은 LWW 키 — 반드시 UTC 로 저장해 원격(UTC)과 round-trip 일치.
      updatedAt: Value(t.updatedAt.toUtc()),
      calendarEventId: Value(t.calendarEventId),
      parentId: Value(t.parentId),
      type: Value(t.type.name),
      sortOrder: Value(t.sortOrder),
      description: Value(t.description),
      endAt: Value(t.endAt),
      isAllDay: Value(t.isAllDay),
      timeAnchor: Value(t.timeAnchor),
      seriesId: Value(t.seriesId),
      recurrenceRule: Value(t.recurrenceRule),
      recurrenceEndAt: Value(t.recurrenceEndAt),
      isSeriesMaster: Value(t.isSeriesMaster),
    );
  }
}
