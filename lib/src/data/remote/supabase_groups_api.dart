import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/group.dart';
import 'supabase_provider.dart';

/// 원격 groups 저장소 계약. [RemoteCategoriesApi] 미러.
abstract interface class RemoteGroupsApi {
  Future<void> upsert(Group group, String userId);
  Future<void> deleteById(String id, String userId);
  Future<List<Group>> fetchAll(String userId);

  /// realtime payload (newRecord) → 도메인 [Group] 변환.
  Group groupFromRow(Map<String, dynamic> row);
}

/// Supabase `groups` 테이블 CRUD wrapper. [SupabaseCategoriesApi] 미러.
///
/// 로컬 Drift 는 camelCase (colorValue) 이지만 Supabase 는 snake_case
/// (color_value). 매핑은 이 클래스가 단일 출처로 관리.
///
/// RLS 정책 (schema.sql 에 SQL 포함):
///   - SELECT/INSERT/UPDATE/DELETE: `auth.uid() = user_id`
class SupabaseGroupsApi implements RemoteGroupsApi {
  SupabaseGroupsApi(this._client);

  static const _schema = 'solo_todo';
  static const _table = 'groups';

  final SupabaseClient _client;

  late final _qb = _client.schema(_schema);

  @override
  Future<void> upsert(Group group, String userId) async {
    await _qb.from(_table).upsert(_toRow(group, userId));
  }

  @override
  Future<void> deleteById(String id, String userId) async {
    await _qb.from(_table).delete().eq('id', id).eq('user_id', userId);
  }

  @override
  Future<List<Group>> fetchAll(String userId) async {
    final rows = await _qb.from(_table).select().eq('user_id', userId);
    return rows.map((r) => _fromRow(r)).toList();
  }

  // ---- 매핑 헬퍼 ---------------------------------------------------------

  Map<String, dynamic> _toRow(Group g, String userId) => {
    'id': g.id,
    'user_id': userId,
    'label': g.label,
    'color_value': g.colorValue,
    'sort_order': g.sortOrder,
    'is_builtin': g.isBuiltin,
    'archived': g.archived,
  };

  Group _fromRow(Map<String, dynamic> row) => Group(
    id: row['id'] as String,
    label: row['label'] as String,
    colorValue: _toInt(row['color_value']),
    sortOrder: _toInt(row['sort_order']),
    isBuiltin: (row['is_builtin'] as bool?) ?? false,
    archived: (row['archived'] as bool?) ?? false,
  );

  /// PostgREST 가 int 를 num 으로 반환할 수 있는 경우 안전 변환.
  static int _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  /// 테스트 / 매핑 안정성 검증용으로 직접 노출.
  Map<String, dynamic> rowForTest(Group g, String userId) => _toRow(g, userId);

  @override
  Group groupFromRow(Map<String, dynamic> row) => _fromRow(row);
}

final supabaseGroupsApiProvider = Provider<SupabaseGroupsApi?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : SupabaseGroupsApi(client);
});
