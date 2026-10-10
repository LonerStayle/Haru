import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/policies/description_checklist.dart';
import '../../../domain/todo.dart';
import '../ai_call.dart';
import '../ai_gateway.dart';
import '../ai_json.dart';

/// T1 — 문장으로 적은 설명을 `- [ ]` 목록으로.
///
/// 결과는 설명 텍스트만 바꾼다. 하위 항목으로 옮기는 일은 기존 "하위 항목으로" 제안이
/// 맡는다(규칙 경로·되돌리기 그대로).
class AiChecklistService {
  const AiChecklistService();

  /// 칩을 보일지 — 설명이 길고(80자+) 아직 목록이 아닌 미완료 할 일.
  static bool applies(Todo todo) =>
      todo.type == TodoType.task &&
      !todo.isDone &&
      (todo.description?.trim().length ?? 0) >= 80 &&
      DescriptionChecklist.parse(todo.description).items.length < 2;

  static const instructions = '''
너는 할 일 앱의 설명 정리 도우미다. 사용자가 문장으로 적은 할 일 설명을 체크리스트로 바꾼다.
규칙:
1. 원문에 실제로 적힌 행동만 항목으로 만든다. 원문에 없는 단계를 지어내지 않는다.
2. 원문의 순서를 지킨다. "~하고, 끝나면 ~" 같은 문장은 의미 단위로 나눈다.
3. 각 항목은 원문 표현을 살린 한국어 한 줄, 40자 이내. 목록 기호(-, *, 1.)는 붙이지 않는다.
4. 행동이 아닌 배경·이유·메모 문장은 intro 에 원문 그대로 남긴다. 없으면 null.
5. 행동이 2개 미만이면 items 를 빈 배열로 돌려준다.
출력은 JSON 하나.''';

  static const schema = <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['intro', 'items'],
    'properties': {
      'intro': {
        'type': ['string', 'null'],
      },
      'items': {
        'type': 'array',
        'maxItems': 12,
        'items': {'type': 'string'},
      },
    },
  };

  /// 새 설명. 만들지 못하면 null.
  Future<String?> toChecklist(AiGateway gateway, Todo todo) {
    final description = todo.description ?? '';
    return aiJson(
      gateway,
      instructions: instructions,
      input: jsonEncode({
        'title': todo.title,
        'description': description.length > 2000
            ? description.substring(0, 2000)
            : description,
      }),
      schema: schema,
      parse: (json) => buildChecklistDescription(json, original: description),
    );
  }
}

/// 응답 → 새 설명. 항목이 2개 미만이거나 결과가 원문보다 지나치게 길면 null.
String? buildChecklistDescription(
  Map<String, dynamic> json, {
  required String original,
}) {
  final raw = json['items'];
  if (raw is! List) return null;
  final seen = <String>{};
  final items = <String>[
    for (final i in raw.take(12))
      if (AiJson.title(i) case final t? when seen.add(t)) t,
  ];
  if (items.length < 2) return null;
  final intro = AiJson.text(json['intro']);
  final text = [
    ?intro,
    if (intro != null) '',
    for (final i in items) '- [ ] $i',
  ].join('\n').trim();
  // 규칙 엔진이 같은 목록으로 읽는지 재확인 — 어긋나면 "하위 항목으로" 가 안 뜬다.
  if (DescriptionChecklist.parse(text).items.length < 2) return null;
  if (text.length > original.trim().length * 2 + 40) return null;
  return text;
}

final aiChecklistServiceProvider = Provider<AiChecklistService>(
  (ref) => const AiChecklistService(),
);
