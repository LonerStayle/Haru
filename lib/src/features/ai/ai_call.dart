import 'dart:async';

import 'ai_gateway.dart';

/// JSON 호출 + 해석을 한 번에 — 타임아웃·예외·해석 실패를 전부 null 로.
///
/// 화면은 결과를 받은 뒤 `mounted` 와 "대상이 그대로인가" 를 확인하고 적용한다.
Future<T?> aiJson<T>(
  AiGateway gateway, {
  required String instructions,
  required String input,
  required Map<String, dynamic> schema,
  required T? Function(Map<String, dynamic> json) parse,
  Duration timeout = const Duration(seconds: 90),
}) async {
  try {
    final json = await gateway
        .json(instructions: instructions, input: input, schema: schema)
        .timeout(timeout);
    if (json == null) return null;
    return parse(json);
  } catch (_) {
    // 내용은 로그에 남기지 않는다(제목·설명이 담겨 있다).
    return null;
  }
}
