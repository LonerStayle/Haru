import 'package:drift/drift.dart';

import '../../domain/category.dart' as domain;
import 'app_database.dart';

part 'categories_dao.g.dart';

/// 카테고리 CRUD + 조회 스트림.
///
/// 모든 외부 인터페이스는 도메인 [domain.Category] 만 노출. Drift 의 [CategoryRow]
/// 는 내부 매핑용. createdAt 은 row 의 정렬 fallback 으로만 쓰이고 도메인 모델은
/// 노출하지 않는다 (도메인은 sortOrder 만 의미).
@DriftAccessor(tables: [Categories, Todos])
class CategoriesDao extends DatabaseAccessor<AppDatabase>
    with _$CategoriesDaoMixin {
  CategoriesDao(super.db);

  Future<domain.Category?> getById(String id) async {
    final row = await (select(
      categories,
    )..where((c) => c.id.equals(id))).getSingleOrNull();
    return row == null ? null : _rowToDomain(row);
  }

  /// sortOrder asc + createdAt asc 정렬로 전체 카테고리 watch.
  Stream<List<domain.Category>> watchAll() {
    final q = select(categories)
      ..orderBy([
        (c) => OrderingTerm(expression: c.sortOrder, mode: OrderingMode.asc),
        (c) => OrderingTerm(expression: c.createdAt, mode: OrderingMode.asc),
      ]);
    return q.watch().map((rows) => rows.map(_rowToDomain).toList());
  }

  /// 1회성 fetch — sidebar 초기 렌더 또는 검증용.
  Future<List<domain.Category>> getAll() async {
    final q = select(categories)
      ..orderBy([
        (c) => OrderingTerm(expression: c.sortOrder, mode: OrderingMode.asc),
        (c) => OrderingTerm(expression: c.createdAt, mode: OrderingMode.asc),
      ]);
    final rows = await q.get();
    return rows.map(_rowToDomain).toList();
  }

  /// id 기준 upsert. 신규 카테고리 (ADD) / 향후 편집 (label/color/icon) 모두 같은 경로.
  Future<void> upsert(domain.Category category, {DateTime? createdAt}) {
    return into(categories).insertOnConflictUpdate(
      CategoriesCompanion.insert(
        id: category.id,
        label: category.label,
        iconCodePoint: category.iconCodePoint,
        colorValue: category.colorValue,
        sortOrder: Value(category.sortOrder),
        isBuiltin: Value(category.isBuiltin),
        createdAt: createdAt ?? DateTime.now().toUtc(),
        groupId: Value(category.groupId),
        archived: Value(category.archived),
      ),
    );
  }

  /// hard delete. 호출자가 사전에 [countTodosOfCategory] 로 안 todos 가 0건임을
  /// 확인해야 한다 (정책 위반 시 todos 가 dangling 상태가 됨). builtin 도 삭제 가능.
  Future<int> deleteById(String id) {
    return (delete(categories)..where((c) => c.id.equals(id))).go();
  }

  /// 안 todos 의 개수 — 삭제 차단 정책 (CategoryDeletePolicy) 의 입력.
  Future<int> countTodosOfCategory(String id) async {
    final countExp = countAll();
    final q = selectOnly(todos)
      ..addColumns([countExp])
      ..where(todos.category.equals(id));
    final row = await q.getSingle();
    return row.read(countExp) ?? 0;
  }

  // --- 매핑 헬퍼 ---------------------------------------------------------

  domain.Category _rowToDomain(CategoryRow row) {
    return domain.Category(
      id: row.id,
      label: row.label,
      iconCodePoint: row.iconCodePoint,
      colorValue: row.colorValue,
      sortOrder: row.sortOrder,
      isBuiltin: row.isBuiltin,
      groupId: row.groupId,
      archived: row.archived,
    );
  }
}
