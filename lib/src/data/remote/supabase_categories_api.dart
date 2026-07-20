import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/category.dart';
import 'supabase_provider.dart';

/// 원격 categories 저장소 계약. Supabase 외 다른 백엔드 / fake 가 동일 인터페이스 구현 가능.
abstract interface class RemoteCategoriesApi {
  Future<void> upsert(Category category, String userId);
  Future<void> deleteById(String id, String userId);
  Future<List<Category>> fetchAll(String userId);

  /// realtime payload (newRecord) → 도메인 [Category] 변환.
  Category categoryFromRow(Map<String, dynamic> row);
}

/// Supabase `categories` 테이블 CRUD wrapper.
///
/// 로컬 Drift 는 camelCase (iconCodePoint) 이지만 Supabase 는 snake_case
/// (icon_code_point). 매핑은 이 클래스가 단일 출처로 관리.
///
/// RLS 정책 (schema.sql 에 SQL 포함):
///   - SELECT/INSERT/UPDATE/DELETE: `auth.uid() = user_id`
class SupabaseCategoriesApi implements RemoteCategoriesApi {
  SupabaseCategoriesApi(this._client);

  static const _schema = 'solo_todo';
  static const _table = 'categories';

  final SupabaseClient _client;

  late final _qb = _client.schema(_schema);

  @override
  Future<void> upsert(Category category, String userId) async {
    await _qb.from(_table).upsert(_toRow(category, userId));
  }

  @override
  Future<void> deleteById(String id, String userId) async {
    await _qb.from(_table).delete().eq('id', id).eq('user_id', userId);
  }

  @override
  Future<List<Category>> fetchAll(String userId) async {
    final rows = await _qb.from(_table).select().eq('user_id', userId);
    return rows.map((r) => _fromRow(r)).toList();
  }

  // ---- 매핑 헬퍼 ---------------------------------------------------------

  Map<String, dynamic> _toRow(Category c, String userId) => {
    'id': c.id,
    'user_id': userId,
    'label': c.label,
    'icon_code_point': c.iconCodePoint,
    'color_value': c.colorValue,
    'sort_order': c.sortOrder,
    'is_builtin': c.isBuiltin,
    'group_id': c.groupId,
    'archived': c.archived,
  };

  Category _fromRow(Map<String, dynamic> row) => Category(
    id: row['id'] as String,
    label: row['label'] as String,
    iconCodePoint: _toInt(row['icon_code_point']),
    colorValue: _toInt(row['color_value']),
    sortOrder: _toInt(row['sort_order']),
    isBuiltin: (row['is_builtin'] as bool?) ?? false,
    groupId: row['group_id'] as String?,
    archived: (row['archived'] as bool?) ?? false,
  );

  /// PostgREST 가 int 를 num 으로 반환할 수 있는 경우 안전 변환 (SupabaseTodosApi 와 일관).
  static int _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  /// 테스트 / 매핑 안정성 검증용으로 직접 노출.
  Map<String, dynamic> rowForTest(Category c, String userId) =>
      _toRow(c, userId);

  @override
  Category categoryFromRow(Map<String, dynamic> row) => _fromRow(row);
}

final supabaseCategoriesApiProvider = Provider<SupabaseCategoriesApi?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : SupabaseCategoriesApi(client);
});
