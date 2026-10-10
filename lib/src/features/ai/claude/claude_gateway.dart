import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../ai_gateway.dart';
import 'claude_config.dart';
import 'claude_errors.dart';
import 'claude_messages_client.dart';
import 'claude_schema.dart';
import 'claude_sse.dart';

/// Claude API 호출 창구.
class ClaudeGateway implements AiGateway {
  ClaudeGateway({
    required ClaudeMessagesClient client,
    this.jsonTimeout = ClaudeConfig.jsonTotalTimeout,
  }) : _client = client;

  final ClaudeMessagesClient _client;
  final Duration jsonTimeout;

  @override
  Future<Map<String, dynamic>?> json({
    required String instructions,
    required String input,
    required Map<String, dynamic> schema,
  }) async {
    final abort = Completer<void>();
    try {
      final message = await _client
          .create(
            buildClaudeJsonBody(
              instructions: instructions,
              input: input,
              schema: toClaudeSchema(schema),
            ),
            abort: abort.future,
          )
          .timeout(jsonTimeout);
      final text = messageText(message);
      if (text == null) return null;
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      // 내용은 남기지 않는다 — 종류만.
      debugPrint(
        '[haru.ai] CLAUDE JSON failed '
        '${e is ClaudeApiException ? e.kind.name : e.runtimeType}',
      );
      return null;
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  @override
  Stream<String> stream({required String instructions, required String input}) {
    final abort = Completer<void>();
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onListen: () async {
        try {
          await _client.stream(
            buildClaudeStreamBody(instructions: instructions, input: input),
            abort: abort.future,
            onText: (t) {
              if (!controller.isClosed && !abort.isCompleted) controller.add(t);
            },
          );
        } on http.RequestAbortedException {
          // 구독 취소 — 조용히 끝낸다.
        } catch (e) {
          if (!abort.isCompleted && !controller.isClosed) {
            controller.addError(e is ClaudeApiException ? e : networkFailure);
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
