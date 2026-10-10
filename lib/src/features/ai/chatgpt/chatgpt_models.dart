import 'siwc_config.dart';

/// 플랜 카탈로그 모델 하나 (사양서 A.17).
class CatalogModel {
  const CatalogModel({
    required this.slug,
    required this.displayName,
    required this.visibility,
    this.description,
    this.reasoningLevels,
  });

  final String slug;
  final String displayName;

  /// `list` 만 UI 에 낸다. `hide` 는 호출은 되지만 보이지 않는다.
  final String? visibility;
  final String? description;
  final List<String>? reasoningLevels;

  bool get listed => visibility == 'list';
}

/// `GET /v1/models` 응답 → 모델 목록 (서버 순서, 중복 slug 제거).
/// `models` 배열이 없으면 플랜 카탈로그가 아니다 → null.
List<CatalogModel>? parseModelCatalog(Map<String, dynamic> json) {
  final models = json['models'];
  if (models is! List) return null;
  final seen = <String>{};
  final out = <CatalogModel>[];
  for (final m in models) {
    if (m is! Map) continue;
    final slug = m['slug'];
    if (slug is! String || slug.isEmpty || !seen.add(slug)) continue;
    final display = m['display_name'];
    final desc = m['description'];
    final vis = m['visibility'];
    out.add(
      CatalogModel(
        slug: slug,
        displayName: display is String && display.isNotEmpty ? display : slug,
        visibility: vis is String ? vis : null,
        description: desc is String ? desc : null,
        reasoningLevels: _levels(m['supported_reasoning_levels']),
      ),
    );
  }
  return out;
}

List<String>? _levels(Object? raw) {
  if (raw is! List) return null;
  final out = <String>[];
  for (final e in raw) {
    if (e is String) {
      out.add(e);
    } else if (e is Map) {
      final v = e['effort'] ?? e['level'] ?? e['name'] ?? e['id'];
      if (v is String) out.add(v);
    }
  }
  return out;
}

/// 기본 모델 — 카탈로그에 [SiwcConfig.defaultModel] 이 있으면(hide 포함) 그 항목, 없으면
/// null. null 이면 호출부가 기본값 slug 를 그대로 쓴다 — `gpt-6-luna` 는 카탈로그에
/// 없어도 호출되고(Andy 실측 A14), 카탈로그 첫 모델은 더 무거운 상위 모델이라 한도를
/// 빨리 쓴다.
CatalogModel? chooseDefaultModel(
  List<CatalogModel>? catalog, {
  String preferred = SiwcConfig.defaultModel,
}) {
  if (catalog == null) return null;
  for (final m in catalog) {
    if (m.slug == preferred) return m;
  }
  return null;
}

const _effortRank = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh'];

/// `low` 를 쓰되, 모델이 지원 목록을 알리고 그 안에 없으면 가장 낮은 값.
String reasoningEffortFor(CatalogModel? model) {
  final levels = model?.reasoningLevels;
  if (levels == null || levels.isEmpty || levels.contains('low')) return 'low';
  final known = levels.where(_effortRank.contains).toList()
    ..sort((a, b) => _effortRank.indexOf(a) - _effortRank.indexOf(b));
  return known.isNotEmpty ? known.first : levels.first;
}
