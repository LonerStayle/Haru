import 'claude_errors.dart';

/// Messages 스트림 이벤트(SSE data JSON) 해석.
///
/// - `content_block_delta` 의 `text_delta` 만 [onText] 로 흘린다. `thinking_delta`·
///   `signature_delta` 등은 무시한다 (Opus 5.5 는 항상 adaptive thinking).
/// - `message_delta.delta.stop_reason == 'refusal'` 이면 [ClaudeApiException] (refusal).
/// - `error` 이벤트는 `error.type` 으로 종류를 정해 던진다 (message 는 읽지 않는다).
/// - `message_start`·`content_block_start/stop`·`ping`, 서버 대체(`fallback` 블록) 는 무시.
class ClaudeStreamAccumulator {
  ClaudeStreamAccumulator({this.onText});

  final void Function(String text)? onText;

  final _text = StringBuffer();
  String? _stopReason;
  bool _stopped = false;

  /// 지금까지 흘린 텍스트가 있는지 (있으면 재시도하지 않는다).
  bool get started => _text.isNotEmpty;

  String? get stopReason => _stopReason;

  /// 이벤트 하나를 받는다. `message_stop` 이면 true.
  bool accept(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'content_block_delta':
        final delta = event['delta'];
        if (delta is Map && delta['type'] == 'text_delta') {
          final text = delta['text'];
          if (text is String && text.isNotEmpty) {
            _text.write(text);
            onText?.call(text);
          }
        }
      case 'message_delta':
        final delta = event['delta'];
        final reason = delta is Map ? delta['stop_reason'] : null;
        if (reason is String) _stopReason = reason;
        if (reason == 'refusal') {
          throw const ClaudeApiException(ClaudeErrorKind.refusal);
        }
      case 'message_stop':
        _stopped = true;
        return true;
      case 'error':
        final type = errorTypeOf(event);
        throw ClaudeApiException(kindForType(type), type: type);
    }
    return false;
  }

  /// 스트림이 끝났을 때. `message_stop` 없이 끊겼으면 연결 오류,
  /// `max_tokens` 로 잘렸으면 incomplete.
  String finish() {
    if (!_stopped) throw networkFailure;
    if (_stopReason == 'max_tokens') {
      throw const ClaudeApiException(ClaudeErrorKind.incomplete);
    }
    return _text.toString();
  }
}

/// 단발(비스트림) 응답에서 `text` 블록만 이어 붙인다. `thinking`·`fallback` 블록은 무시.
/// `stop_reason` 이 refusal·max_tokens 면 null.
String? messageText(Map<String, dynamic> message) {
  final reason = message['stop_reason'];
  if (reason == 'refusal' || reason == 'max_tokens') return null;
  final content = message['content'];
  if (content is! List) return null;
  final out = StringBuffer();
  for (final block in content) {
    if (block is Map && block['type'] == 'text') {
      final text = block['text'];
      if (text is String) out.write(text);
    }
  }
  return out.toString();
}
