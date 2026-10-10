import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../ai_gateway.dart';
import 'chatgpt_client.dart';
import 'chatgpt_errors.dart';
import 'responses_accumulator.dart';
import 'responses_request.dart';

/// 호출에 쓸 모델·추론 강도.
typedef ChatGptModelChoice = ({String slug, String effort});

/// ChatGPT 플랜 호출 창구 (사양서 D.2).
class ChatGptGateway implements AiGateway {
  ChatGptGateway({
    required ChatGptClient client,
    required Future<ChatGptModelChoice> Function() model,
    this.jsonTimeout = const Duration(seconds: 90),
  }) : _client = client,
       _model = model;

  final ChatGptClient _client;
  final Future<ChatGptModelChoice> Function() _model;
  final Duration jsonTimeout;

  /// `text.format` json_schema 가 이 경로에서 거절되면 프로세스 동안 프롬프트 JSON 모드. [미실측]
  bool _schemaUnsupported = false;

  @visibleForTesting
  bool get schemaUnsupported => _schemaUnsupported;

  @override
  Future<Map<String, dynamic>?> json({
    required String instructions,
    required String input,
    required Map<String, dynamic> schema,
  }) async {
    try {
      return await _json(instructions, input, schema).timeout(jsonTimeout);
    } catch (e) {
      debugPrint(
        '[haru.ai] JSON failed ${e is ChatGptException ? e.kind.name : e.runtimeType}',
      );
      return null;
    }
  }

  Future<Map<String, dynamic>?> _json(
    String instructions,
    String input,
    Map<String, dynamic> schema,
  ) async {
    final model = await _model();
    final cacheKey = haruCacheKey(instructions);
    final strict = _schemaUnsupported ? null : toStrictSchema(schema);
    if (strict != null) {
      final body = jsonEncode(
        buildResponsesBody(
          model: model.slug,
          instructions: instructions,
          input: input,
          effort: model.effort,
          promptCacheKey: cacheKey,
          jsonSchema: strict,
        ),
      );
      try {
        final outcome = await _client.respond(body, sessionId: cacheKey);
        if (outcome is! ResponseCompleted || outcome.hasRefusal) return null;
        Object? decoded;
        try {
          decoded = jsonDecode(outcome.text);
        } catch (_) {
          return null;
        }
        return _validated(stripAddedNulls(decoded, schema), schema);
      } on ChatGptException catch (e) {
        if (!isFormatRejection(e)) rethrow;
        debugPrint('[haru.ai] JSON schema_mode rejected → prompt mode');
        _schemaUnsupported = true;
      }
    }

    final body = jsonEncode(
      buildResponsesBody(
        model: model.slug,
        instructions:
            '$instructions\n\n출력은 JSON 하나만, 다른 글 없이. '
            '형식(JSON Schema):\n${jsonEncode(schema)}',
        input: input,
        effort: model.effort,
        promptCacheKey: cacheKey,
      ),
    );
    final outcome = await _client.respond(body, sessionId: cacheKey);
    if (outcome is! ResponseCompleted || outcome.hasRefusal) return null;
    return _validated(extractJsonObject(outcome.text), schema);
  }

  @override
  Stream<String> stream({required String instructions, required String input}) {
    final abort = Completer<void>();
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onListen: () async {
        try {
          final model = await _model();
          final cacheKey = haruCacheKey(instructions);
          final body = jsonEncode(
            buildResponsesBody(
              model: model.slug,
              instructions: instructions,
              input: input,
              effort: model.effort,
              promptCacheKey: cacheKey,
              lowVerbosity: false,
            ),
          );
          final outcome = await _client.respond(
            body,
            sessionId: cacheKey,
            abort: abort.future,
            onDelta: (d) {
              if (!controller.isClosed && !abort.isCompleted) controller.add(d);
            },
          );
          if (outcome is ResponseIncomplete && !abort.isCompleted) {
            controller.addError(
              ChatGptException(
                ChatGptErrorKind.incomplete,
                '답이 중간에 끊겼어요.',
                code: outcome.reason,
              ),
            );
          }
        } on http.RequestAbortedException {
          // 구독 취소 — 조용히 끝낸다.
        } catch (e) {
          if (!abort.isCompleted) {
            controller.addError(e is ChatGptException ? e : networkError);
          }
        } finally {
          if (!controller.isClosed) await controller.close();
        }
      },
      onCancel: () {
        if (!abort.isCompleted) abort.complete();
      },
    );
    return controller.stream;
  }
}

/// 400 이 `text.format` 을 거절한 것인지 (사양서 D.2-2).
@visibleForTesting
bool isFormatRejection(ChatGptException e) {
  if (e.kind != ChatGptErrorKind.badRequest &&
      e.kind != ChatGptErrorKind.unsupportedCapability) {
    return false;
  }
  if (e.status != null && e.status != 400) return false;
  final param = e.param;
  if (param != null && param.startsWith('text')) return true;
  final detail = e.detail?.toLowerCase();
  return e.code == null && detail != null && detail.contains('format');
}

/// 루트 객체 + 필수 key 존재만 확인한다.
Map<String, dynamic>? _validated(Object? value, Map<String, dynamic> schema) {
  if (value is! Map<String, dynamic>) return null;
  final required = schema['required'];
  if (required is List) {
    for (final k in required) {
      if (!value.containsKey(k) || value[k] == null) return null;
    }
  }
  return value;
}
