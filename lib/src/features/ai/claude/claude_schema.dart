/// 기능 스키마(OpenAI strict 모양) → Anthropic structured outputs 가 받는 모양.
///
/// - 모든 object 에 `additionalProperties: false`.
/// - 타입 배열(`type: ['string', 'null']`) → `anyOf: [{type: string}, {type: null}]`.
/// - 지원하지 않는 제약 제거 (숫자 범위·길이·개수·pattern). 검증은 기능 쪽이 한다.
/// - `enum` 은 유지. 원본은 건드리지 않고 깊은 복사본을 돌려준다.
Map<String, dynamic> toClaudeSchema(Map<String, dynamic> schema) =>
    _schema(schema) as Map<String, dynamic>;

const _unsupported = {
  'minimum',
  'maximum',
  'exclusiveMinimum',
  'exclusiveMaximum',
  'multipleOf',
  'minLength',
  'maxLength',
  'minItems',
  'maxItems',
  'pattern',
};

/// 값이 "이름 → 스키마" 맵인 키워드.
const _schemaMaps = {'properties', r'$defs', 'definitions'};

/// 값이 스키마 하나인 키워드.
const _schemaValues = {'items', 'not'};

/// 값이 스키마 목록인 키워드.
const _schemaLists = {'anyOf', 'allOf', 'oneOf', 'prefixItems'};

/// 타입 배열을 anyOf 로 풀 때 바깥에 남기는 설명 키워드.
const _annotations = {'description', 'title'};

Object? _schema(Object? node) {
  if (node is! Map) return _copy(node);
  final out = <String, dynamic>{};
  for (final e in node.entries) {
    final key = e.key as String;
    final value = e.value;
    if (_unsupported.contains(key)) continue;
    if (_schemaMaps.contains(key) && value is Map) {
      out[key] = {
        for (final p in value.entries) p.key as String: _schema(p.value),
      };
    } else if (_schemaValues.contains(key) && value is Map) {
      out[key] = _schema(value);
    } else if (_schemaLists.contains(key) && value is List) {
      out[key] = value.map(_schema).toList();
    } else {
      out[key] = _copy(value);
    }
  }
  final type = out['type'];
  if (type is List) return _splitTypes(out, type);
  return _closeObject(out);
}

/// `type: [a, b, 'null']` → `anyOf: [{type: a, …}, {type: b, …}, {type: null}]`.
Map<String, dynamic> _splitTypes(Map<String, dynamic> node, List types) {
  final rest = <String, dynamic>{
    for (final e in node.entries)
      if (e.key != 'type' && !_annotations.contains(e.key)) e.key: e.value,
  };
  final branches = <Map<String, dynamic>>[];
  for (final t in types) {
    if (t == 'null') {
      branches.add({'type': 'null'});
      continue;
    }
    final branch = <String, dynamic>{'type': t, ..._copy(rest) as Map};
    final values = branch['enum'];
    if (values is List && values.contains(null)) {
      branch['enum'] = values.where((v) => v != null).toList();
    }
    branches.add(_closeObject(branch));
  }
  if (branches.length == 1) {
    return {
      for (final e in node.entries)
        if (_annotations.contains(e.key)) e.key: e.value,
      ...branches.single,
    };
  }
  return {
    for (final e in node.entries)
      if (_annotations.contains(e.key)) e.key: e.value,
    'anyOf': branches,
  };
}

Map<String, dynamic> _closeObject(Map<String, dynamic> node) {
  if (node['type'] == 'object' || node['properties'] is Map) {
    node['additionalProperties'] = false;
  }
  return node;
}

Object? _copy(Object? v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) e.key as String: _copy(e.value),
    };
  }
  if (v is List) return v.map(_copy).toList();
  return v;
}
