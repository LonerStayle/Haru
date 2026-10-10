import 'dart:async';
import 'dart:convert';

/// SSE 바이트 → data JSON 객체 (사양서 A.13).
///
/// - UTF-8 줄 단위 (CRLF / CR / LF). 멀티바이트 경계는 디코더가 이어 붙인다.
/// - `:` 주석, `event:`/`id:`/`retry:` 무시 — 분기는 data JSON 의 `type` 으로.
/// - `data:` 값의 선행 공백 1개 제거, 한 블록의 여러 data 줄은 `\n` 으로 잇는다.
/// - 빈 줄에서 dispatch, EOF 에 남은 블록도 flush. `[DONE]` 은 종료.
/// - JSON 이 깨졌거나 객체가 아니면 [onMalformed] 에 길이만 알리고 건너뛴다.
Stream<Map<String, dynamic>> sseEvents(
  Stream<List<int>> bytes, {
  void Function(int length)? onMalformed,
}) async* {
  final data = <String>[];
  var done = false;

  Map<String, dynamic>? dispatch() {
    if (data.isEmpty) return null;
    final payload = data.join('\n');
    data.clear();
    if (payload.trim() == '[DONE]') {
      done = true;
      return null;
    }
    try {
      final json = jsonDecode(payload);
      if (json is Map<String, dynamic>) return json;
    } catch (_) {}
    onMalformed?.call(payload.length);
    return null;
  }

  await for (final line
      in bytes
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())) {
    if (line.isEmpty) {
      final event = dispatch();
      if (event != null) yield event;
      if (done) return;
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    if (field != 'data') continue;
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    data.add(value);
  }
  final last = dispatch();
  if (last != null) yield last;
}
