import 'dart:convert';

import 'package:crypto/crypto.dart';

/// `/v1/responses` 바디 — 필드 순서 고정 (사양서 A.13).
///
/// SIWC 경로 필수: `store:false`, `stream:true`, `input` 배열. `role:"system"`·
/// `max_output_tokens`·`temperature` 등 금지 필드는 만들지 않는다.
Map<String, dynamic> buildResponsesBody({
  required String model,
  required String instructions,
  required String input,
  required String effort,
  required String promptCacheKey,
  Map<String, dynamic>? jsonSchema,
  bool lowVerbosity = true,
}) {
  final text = <String, dynamic>{
    if (lowVerbosity) 'verbosity': 'low',
    if (jsonSchema != null)
      'format': {
        'type': 'json_schema',
        'name': 'haru_result',
        'schema': jsonSchema,
        'strict': true,
      },
  };
  return {
    'model': model,
    'instructions': instructions,
    'reasoning': {'effort': effort},
    if (text.isNotEmpty) 'text': text,
    'store': false,
    'stream': true,
    'prompt_cache_key': promptCacheKey,
    'input': [
      {'role': 'user', 'content': input},
    ],
  };
}

/// 기능별 캐시 키 — 지시문이 같으면 같은 키 (`haru-<지시문 해시 12자>`).
String haruCacheKey(String instructions) =>
    'haru-${sha256.convert(utf8.encode(instructions)).toString().substring(0, 12)}';

const _forbiddenKeywords = {
  'default',
  'allOf',
  'not',
  'if',
  'then',
  'else',
  'minLength',
  'maxLength',
  'oneOf',
};

/// strict json_schema 규칙으로 바꾼다 (Andy `StrictSchema` 와 같은 규칙).
///
/// 모든 object 에 `additionalProperties:false`, `required` = 모든 key, 원래 선택이던
/// 필드는 `type:[원래,"null"]`, 금지 키워드 제거. 루트가 object 가 아니거나 루트
/// `anyOf` 면 null (프롬프트 JSON 모드로 간다).
Map<String, dynamic>? toStrictSchema(Map<String, dynamic> schema) {
  if (schema['type'] != 'object' || schema.containsKey('anyOf')) return null;
  return _strict(schema) as Map<String, dynamic>;
}

Object? _strict(Object? node) {
  if (node is List) return node.map(_strict).toList();
  if (node is! Map) return node;
  final out = <String, dynamic>{};
  for (final e in node.entries) {
    final key = e.key as String;
    if (_forbiddenKeywords.contains(key)) continue;
    if (key == 'properties' || key == 'required') continue;
    out[key] = _strict(e.value);
  }
  final props = node['properties'];
  if (node['type'] == 'object' || props is Map) {
    final required = {
      for (final r in (node['required'] as List? ?? const [])) r as String,
    };
    final strictProps = <String, dynamic>{};
    if (props is Map) {
      for (final p in props.entries) {
        var child = _strict(p.value);
        if (!required.contains(p.key) && child is Map<String, dynamic>) {
          child = _nullable(child);
        }
        strictProps[p.key as String] = child;
      }
    }
    out['properties'] = strictProps;
    out['required'] = strictProps.keys.toList();
    out['additionalProperties'] = false;
  }
  return out;
}

Map<String, dynamic> _nullable(Map<String, dynamic> schema) {
  final type = schema['type'];
  if (type is String) {
    if (type == 'null') return schema;
    return {
      ...schema,
      'type': [type, 'null'],
    };
  }
  if (type is List) {
    return type.contains('null')
        ? schema
        : {
            ...schema,
            'type': [...type, 'null'],
          };
  }
  return {
    'anyOf': [
      schema,
      {'type': 'null'},
    ],
  };
}

/// strict 모드가 선택 필드에 채운 `null` 을 지운다 — 기능은 원래 스키마 모양을 받는다.
Object? stripAddedNulls(Object? value, Map<String, dynamic>? schema) {
  if (schema == null) return value;
  if (value is Map<String, dynamic>) {
    final props = schema['properties'];
    final required = {
      for (final r in (schema['required'] as List? ?? const [])) r as String,
    };
    final out = <String, dynamic>{};
    for (final e in value.entries) {
      final childSchema = props is Map ? props[e.key] : null;
      if (e.value == null && !required.contains(e.key)) continue;
      out[e.key] = stripAddedNulls(
        e.value,
        childSchema is Map<String, dynamic> ? childSchema : null,
      );
    }
    return out;
  }
  if (value is List) {
    final items = schema['items'];
    return value
        .map(
          (v) =>
              stripAddedNulls(v, items is Map<String, dynamic> ? items : null),
        )
        .toList();
  }
  return value;
}

/// 응답 텍스트에서 첫 `{` ~ 마지막 `}` 를 잘라 객체로 (Andy `parseProposals`). 실패 → null.
Map<String, dynamic>? extractJsonObject(String text) {
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final json = jsonDecode(text.substring(start, end + 1));
    return json is Map<String, dynamic> ? json : null;
  } catch (_) {
    return null;
  }
}
