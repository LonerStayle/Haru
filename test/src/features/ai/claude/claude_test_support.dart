import 'dart:convert';

import 'package:http/http.dart' as http;

const testKey = 'sk-ant-api03-test-abcd';

/// Anthropic SSE 본문 — `event:` 줄 + `data:` 줄.
String claudeSseBody(List<Map<String, dynamic>> events) =>
    events.map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n').join();

http.Response sseRes(List<Map<String, dynamic>> events) => http.Response.bytes(
  utf8.encode(claudeSseBody(events)),
  200,
  headers: {'content-type': 'text/event-stream'},
);

http.Response jsonRes(
  Object body,
  int status, {
  Map<String, String> headers = const {},
}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

/// 오류 본문 — message 에는 로그에 남으면 안 되는 문자열을 넣어 둔다.
http.Response errorRes(
  int status,
  String type, {
  Map<String, String> headers = const {},
}) => jsonRes(
  {
    'type': 'error',
    'error': {'type': type, 'message': 'SECRET-USER-TEXT in message'},
    'request_id': 'req_1',
  },
  status,
  headers: headers,
);

Map<String, dynamic> message(
  List<Map<String, dynamic>> content, {
  String stopReason = 'end_turn',
}) => {
  'id': 'msg_1',
  'type': 'message',
  'role': 'assistant',
  'model': 'claude-opus-5-5',
  'content': content,
  'stop_reason': stopReason,
  'usage': {'input_tokens': 1, 'output_tokens': 1},
};

Map<String, dynamic> textDelta(String text, {int index = 1}) => {
  'type': 'content_block_delta',
  'index': index,
  'delta': {'type': 'text_delta', 'text': text},
};

List<Map<String, dynamic>> textStream(
  List<String> parts, {
  String stopReason = 'end_turn',
  bool withThinking = true,
}) => [
  {
    'type': 'message_start',
    'message': message(const [], stopReason: 'end_turn')
      ..['stop_reason'] = null,
  },
  if (withThinking) ...[
    {
      'type': 'content_block_start',
      'index': 0,
      'content_block': {'type': 'thinking', 'thinking': '', 'signature': ''},
    },
    {
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'thinking_delta', 'thinking': 'THINKING-TEXT'},
    },
    {
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'signature_delta', 'signature': 'sig'},
    },
    {'type': 'content_block_stop', 'index': 0},
  ],
  {'type': 'ping'},
  {
    'type': 'content_block_start',
    'index': 1,
    'content_block': {'type': 'text', 'text': ''},
  },
  for (final p in parts) textDelta(p),
  {'type': 'content_block_stop', 'index': 1},
  {
    'type': 'message_delta',
    'delta': {'stop_reason': stopReason, 'stop_sequence': null},
    'usage': {'output_tokens': 5},
  },
  {'type': 'message_stop'},
];
