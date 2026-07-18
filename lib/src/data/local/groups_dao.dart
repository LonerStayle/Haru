import 'package:drift/drift.dart';

import '../../domain/category.dart' as cat;
import '../../domain/group.dart' as domain;
import 'app_database.dart';

part 'groups_dao.g.dart';

/// 그룹 CRUD + 조회 스트림. [CategoriesDao] 미러.
///
/// 모든 외부 인터페이스는 도메인 [domain.Group] 만 노출. Drift 의 [GroupRow] 는
/// 내부 매핑용. createdAt 은 정렬 fallback 으로만 쓰이고 도메인은 노출하지 않는다.
@DriftAccessor(tables: [Groups, Categories])
class GroupsDao extends DatabaseAccessor<AppDatabase> with _$GroupsDaoMixin {
  GroupsDao(super.db);

  Future<domain.Group?> getById(String id) async {
    final row = await (select(
      groups,
    )..where((g) => g.id.equals(id))).getSingleOrNull();
    return row == null ? null : _rowToDomain(row);
  }

  /// sortOrder asc + createdAt asc 정렬로 전체 그룹 watch.
  Stream<List<domain.Group>> watchAll() {
    final q = select(groups)
      ..orderBy([
        (g) => OrderingTerm(expression: g.sortOrder, mode: OrderingMode.asc),
        (g) => OrderingTerm(expression: g.createdAt, mode: OrderingMode.asc),
      ]);
    return q.watch().map((rows) => rows.map(_rowToDomain).toList());
  }

  /// 1회성 fetch.
  Future<List<domain.Group>> getAll() async {
    final q = select(groups)
      ..orderBy([
        (g) => OrderingTerm(expression: g.sortOrder, mode: OrderingMode.asc),
        (g) => OrderingTerm(expression: g.createdAt, mode: OrderingMode.asc),
      ]);
    final rows = await q.get();
    return rows.map(_rowToDomain).toList();
  }

  /// id 기준 upsert. 신규 그룹 (ADD) / 향후 편집 모두 같은 경로.
  Future<void> upsert(domain.Group group, {DateTime? createdAt}) {
    return into(groups).insertOnConflictUpdate(
      GroupsCompanion.insert(
        id: group.id,
        label: group.label,
        colorValue: group.colorValue,
        sortOrder: Value(group.sortOrder),
        isBuiltin: Value(group.isBuiltin),
        createdAt: createdAt ?? DateTime.now().toUtc(),
        archived: Value(group.archived),
      ),
    );
  }

  /// hard delete. 그룹 삭제는 차단하지 않는다 — 호출자(GroupsController)가
  /// 사전에 [detachCategories] 로 속한 카테고리들을 미분류(groupId=null)로 옮긴다.
  Future<int> deleteById(String id) {
    return (delete(groups)..where((g) => g.id.equals(id))).go();
  }

  /// 이 그룹에 속한 카테고리들 (groupId 매칭). 그룹 삭제 시 미분류로 옮길 대상 +
  /// syncing 경로에서 remote 에 group_id=null 을 push 하기 위한 outbox enqueue 입력.
  /// 반환되는 도메인 객체의 groupId 는 **이동 후 값(null)** 으로 미리 비워서 준다.
  Future<List<cat.Category>> categoriesInGroup(String groupId) async {
    final rows = await (select(
      categories,
    )..where((c) => c.groupId.equals(groupId))).get();
    return rows
        .map(
          (r) => cat.Category(
            id: r.id,
            label: r.label,
            iconCodePoint: r.iconCodePoint,
            colorValue: r.colorValue,
            sortOrder: r.sortOrder,
            isBuiltin: r.isBuiltin,
            groupId: null,
            archived: r.archived,
          ),
        )
        .toList();
  }

  /// 이 그룹에 속한 카테고리들의 groupId 를 null 로 (미분류로 이동). 그룹 삭제 직전 호출.
  /// 반환값 = 영향받은 카테고리 수.
  Future<int> detachCategories(String groupId) {
    return (update(categories)..where((c) => c.groupId.equals(groupId))).write(
      const CategoriesCompanion(groupId: Value(null)),
    );
  }

  // --- 매핑 헬퍼 ---------------------------------------------------------

  domain.Group _rowToDomain(GroupRow row) {
    return domain.Group(
      id: row.id,
      label: row.label,
      colorValue: row.colorValue,
      sortOrder: row.sortOrder,
      isBuiltin: row.isBuiltin,
      archived: row.archived,
    );
  }
}
