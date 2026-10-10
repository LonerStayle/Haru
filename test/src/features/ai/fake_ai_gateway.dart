import 'dart:async';

import 'package:solo_todo/src/features/ai/ai_gateway.dart';

/// 네트워크 없는 [AiGateway] — 기능 위젯 테스트용.
///
/// [jsonQueue] 에 넣은 값(Map 또는 null)을 호출 순서대로 돌려준다. 비어 있으면 null.
/// [hold] 를 넣으면 complete 될 때까지 응답을 미룬다(로딩·신선도 검증용).
class FakeAiGateway implements AiGateway {
  final List<Map<String, dynamic>?> jsonQueue = [];
  final List<String> streamChunks = [];
  Object? streamError;
  Completer<void>? hold;

  /// 스트림 구독이 취소됐는지 (Esc 로 닫기 검증용).
  bool streamCancelled = false;

  final List<
    ({String instructions, String input, Map<String, dynamic>? schema})
  >
  calls = [];

  @override
  Future<Map<String, dynamic>?> json({
    required String instructions,
    required String input,
    required Map<String, dynamic> schema,
  }) async {
    calls.add((instructions: instructions, input: input, schema: schema));
    if (hold != null) await hold!.future;
    return jsonQueue.isEmpty ? null : jsonQueue.removeAt(0);
  }

  @override
  Stream<String> stream({required String instructions, required String input}) {
    calls.add((instructions: instructions, input: input, schema: null));
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onListen: () async {
        if (hold != null) await hold!.future;
        for (final c in streamChunks) {
          if (controller.isClosed) return;
          controller.add(c);
          await Future<void>.delayed(Duration.zero);
        }
        if (controller.isClosed) return;
        if (streamError != null) controller.addError(streamError!);
        await controller.close();
      },
      onCancel: () => streamCancelled = true,
    );
    return controller.stream;
  }
}
