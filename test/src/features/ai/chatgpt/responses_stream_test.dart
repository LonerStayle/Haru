import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/features/ai/chatgpt/chatgpt_errors.dart';
import 'package:solo_todo/src/features/ai/chatgpt/responses_accumulator.dart';
import 'package:solo_todo/src/features/ai/chatgpt/sse.dart';

/// Andy `text_only.sse` 픽스처 (주석·event 줄 포함).
const _textOnly = '''
: keep-alive comment

event: response.created
data: {"type":"response.created","response":{"id":"resp_fx_0001","status":"in_progress","output":[]},"sequence_number":0}

event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_t1","output_index":0,"delta":"안녕","sequence_number":4}

event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_t1","output_index":0,"delta":"하세요","sequence_number":5}

event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_t1","output_index":0,"delta":"!","sequence_number":6}

event: response.output_item.done
data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_t1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"안녕하세요!","annotations":[]}]},"sequence_number":8}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_fx_0001","status":"completed","output":[{"type":"message","id":"msg_t1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"안녕하세요!","annotations":[]}]}]},"sequence_number":9}

''';

const _responseFailed = '''
data: {"type":"response.created","response":{"id":"resp_fx_0001","output":[]},"sequence_number":0}

event: response.failed
data: {"type":"response.failed","response":{"id":"resp_fx_0001","status":"failed","output":[],"error":{"code":"server_error","message":"The server had an error while processing your request."}},"sequence_number":2}

''';

const _errorEvent = '''
event: error
data: {"type":"error","code":"rate_limit_exceeded","message":"Rate limit reached.","param":null,"sequence_number":2}

''';

const _incomplete = '''
data: {"type":"response.incomplete","response":{"id":"resp_fx_0001","status":"incomplete","output":[],"incomplete_details":{"reason":"max_output_tokens"}},"sequence_number":8}

''';

const _truncated = '''
data: {"type":"response.created","response":{"id":"resp_fx_0001","output":[]},"sequence_number":0}

data: {"type":"response.output_text.delta","delta":"중간까","sequence_number":3}

''';

Stream<List<int>> _chunks(String s, {int size = 7}) async* {
  final bytes = utf8.encode(s);
  for (var i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size);
  }
}

Future<(ResponseOutcome, List<String>)> _run(String sse) async {
  final deltas = <String>[];
  final acc = ResponsesAccumulator(onTextDelta: deltas.add);
  await for (final e in sseEvents(_chunks(sse))) {
    if (acc.accept(e)) break;
  }
  return (acc.finish(), deltas);
}

void main() {
  group('SSE 파서', () {
    test('text_only — 주석·event 무시, 한글 바이트가 청크 중간에서 잘려도 정상', () async {
      final (outcome, deltas) = await _run(_textOnly);
      expect(deltas, ['안녕', '하세요', '!']);
      expect(outcome, isA<ResponseCompleted>());
      expect(outcome.text, '안녕하세요!');
      expect(outcome.id, 'resp_fx_0001');
    });

    test('여러 data 줄 결합·CRLF·선행 공백 1개만 제거·EOF flush', () async {
      const raw =
          'data: {"a":\r\ndata:  "x y"}\r\n\r\n'
          'data:{"b":1}\n\n'
          'data: {"c":2}';
      final events = await sseEvents(_chunks(raw, size: 3)).toList();
      expect(events, [
        {'a': 'x y'},
        {'b': 1},
        {'c': 2},
      ]);
    });

    test('[DONE] 은 종료, 깨진 JSON·배열은 길이만 알리고 skip', () async {
      final bad = <int>[];
      const raw =
          'data: not json\n\n'
          'data: [1,2]\n\n'
          'data: {"ok":true}\n\n'
          'data: [DONE]\n\n'
          'data: {"after":true}\n\n';
      final events = await sseEvents(
        Stream.value(utf8.encode(raw)),
        onMalformed: bad.add,
      ).toList();
      expect(events, [
        {'ok': true},
      ]);
      expect(bad, [8, 5]);
    });
  });

  group('누적기', () {
    test('response.failed server_error → 재시도 가능 server', () async {
      await expectLater(
        _run(_responseFailed),
        throwsA(
          isA<ChatGptException>()
              .having((e) => e.kind, 'kind', ChatGptErrorKind.server)
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });

    test('error 이벤트 rate_limit_exceeded → rateLimited', () async {
      await expectLater(
        _run(_errorEvent),
        throwsA(
          isA<ChatGptException>().having(
            (e) => e.kind,
            'kind',
            ChatGptErrorKind.rateLimited,
          ),
        ),
      );
    });

    test('스트림 사용량 한도 → usageLimited', () {
      final acc = ResponsesAccumulator();
      expect(
        () => acc.accept({
          'type': 'response.failed',
          'response': {
            'error': {'code': 'subscription_sharing_usage_limit_exceeded'},
          },
        }),
        throwsA(
          isA<ChatGptException>().having(
            (e) => e.kind,
            'kind',
            ChatGptErrorKind.usageLimited,
          ),
        ),
      );
    });

    test('incomplete → 사유', () async {
      final (outcome, _) = await _run(_incomplete);
      expect(outcome, isA<ResponseIncomplete>());
      expect((outcome as ResponseIncomplete).reason, 'max_output_tokens');
    });

    test('터미널 없는 EOF → 네트워크(재시도 대상)', () async {
      await expectLater(
        _run(_truncated),
        throwsA(
          isA<ChatGptException>()
              .having((e) => e.kind, 'kind', ChatGptErrorKind.network)
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });

    test('시퀀스 역행·중복 무시, 터미널 뒤 무시', () {
      final deltas = <String>[];
      final acc = ResponsesAccumulator(onTextDelta: deltas.add);
      acc.accept({
        'type': 'response.output_text.delta',
        'delta': 'a',
        'sequence_number': 2,
      });
      acc.accept({
        'type': 'response.output_text.delta',
        'delta': 'b',
        'sequence_number': 2,
      });
      acc.accept({
        'type': 'response.output_text.delta',
        'delta': 'c',
        'sequence_number': 1,
      });
      expect(
        acc.accept({
          'type': 'response.completed',
          'response': {},
          'sequence_number': 3,
        }),
        isTrue,
      );
      acc.accept({
        'type': 'response.output_text.delta',
        'delta': 'd',
        'sequence_number': 4,
      });
      expect(deltas, ['a']);
    });

    test('done 목록과 completed.output 이 다르면 output 채택', () {
      final acc = ResponsesAccumulator();
      acc.accept({
        'type': 'response.output_item.done',
        'output_index': 0,
        'item': {'type': 'reasoning', 'id': 'rs_1'},
      });
      acc.accept({
        'type': 'response.completed',
        'response': {
          'output': [
            {'type': 'reasoning', 'id': 'rs_1'},
            {
              'type': 'message',
              'id': 'msg_1',
              'content': [
                {'type': 'output_text', 'text': '확인할게요'},
              ],
            },
          ],
        },
      });
      expect(acc.finish().text, '확인할게요');
    });

    test('refusal 텍스트', () {
      final acc = ResponsesAccumulator();
      acc.accept({
        'type': 'response.output_item.done',
        'output_index': 0,
        'item': {
          'type': 'message',
          'id': 'm',
          'content': [
            {'type': 'refusal', 'refusal': '못 해요'},
          ],
        },
      });
      acc.accept({'type': 'response.completed', 'response': {}});
      final out = acc.finish();
      expect(out.text, '(응답 거부) 못 해요');
      expect(out.hasRefusal, isTrue);
    });
  });

  group('오류 분류', () {
    ChatGptErrorKind http(int status, String body) =>
        classifyHttp(status, ApiErrorBody.parse(body)).kind;
    String err(String code, {String? param}) => jsonEncode({
      'error': {'code': code, 'param': ?param, 'message': 'm'},
    });

    test('코드 우선 표', () {
      expect(
        http(429, err('subscription_sharing_usage_limit_exceeded')),
        ChatGptErrorKind.usageLimited,
      );
      expect(
        http(503, err('subscription_sharing_usage_unavailable')),
        ChatGptErrorKind.serviceUnavailable,
      );
      expect(
        http(503, err('subscription_sharing_user_unavailable')),
        ChatGptErrorKind.serviceUnavailable,
      );
      expect(
        http(403, err('subscription_sharing_user_not_eligible')),
        ChatGptErrorKind.notEligible,
      );
      expect(
        http(403, err('chatpass_v2_scope_not_authorized')),
        ChatGptErrorKind.permissionContext,
      );
      expect(
        http(403, err('subscription_sharing_route_not_supported')),
        ChatGptErrorKind.clientBug,
      );
      expect(
        http(401, err('subscription_sharing_invalid_user')),
        ChatGptErrorKind.authRejected,
      );
      expect(
        http(
          400,
          err('subscription_sharing_unsupported_capability', param: 'model'),
        ),
        ChatGptErrorKind.modelUnavailable,
      );
      expect(
        http(
          400,
          err(
            'subscription_sharing_unsupported_capability',
            param: 'text.format',
          ),
        ),
        ChatGptErrorKind.unsupportedCapability,
      );
      expect(
        http(404, err('model_not_found')),
        ChatGptErrorKind.modelUnavailable,
      );
    });

    test('HTTP 상태 표', () {
      expect(
        http(
          401,
          'Identity Edge route authentication policy requires an accepted credential',
        ),
        ChatGptErrorKind.authRejected,
      );
      expect(http(403, '{"detail":"nope"}'), ChatGptErrorKind.forbidden);
      expect(
        http(429, err('insufficient_quota')),
        ChatGptErrorKind.quotaExhausted,
      );
      expect(
        http(
          429,
          jsonEncode({
            'error': {'type': 'insufficient_quota'},
          }),
        ),
        ChatGptErrorKind.quotaExhausted,
      );
      expect(http(429, ''), ChatGptErrorKind.rateLimited);
      expect(
        http(
          400,
          '{"detail":"The \'gpt-nonexistent-9\' model is not supported when using Codex with a ChatGPT account."}',
        ),
        ChatGptErrorKind.modelUnavailable,
      );
      expect(http(503, ''), ChatGptErrorKind.serviceUnavailable);
      expect(http(500, ''), ChatGptErrorKind.server);
      expect(http(408, ''), ChatGptErrorKind.server);
      expect(
        http(400, err('context_length_exceeded')),
        ChatGptErrorKind.contextTooLong,
      );
      expect(http(400, err('whatever')), ChatGptErrorKind.badRequest);
      expect(classifyHttp(503, ApiErrorBody.parse('')).retryable, isTrue);
      expect(classifyHttp(400, ApiErrorBody.parse('')).retryable, isFalse);
    });

    test('본문 세 모양', () {
      expect(ApiErrorBody.parse(err('x')).shape, ErrorShape.error);
      expect(ApiErrorBody.parse('{"detail":"d"}').shape, ErrorShape.detail);
      expect(ApiErrorBody.parse('plain text').shape, ErrorShape.plain);
      expect(ApiErrorBody.parse('').shape, ErrorShape.empty);
    });

    test('Retry-After — ms 우선, 초(실수), HTTP-date, 음수', () {
      final now = DateTime.utc(2026, 10, 10, 12);
      expect(parseRetryAfter('1500', '9'), const Duration(milliseconds: 1500));
      expect(parseRetryAfter(null, '2.5'), const Duration(milliseconds: 2500));
      expect(
        parseRetryAfter(null, 'Sat, 10 Oct 2026 12:00:30 GMT', now: now),
        const Duration(seconds: 30),
      );
      expect(parseRetryAfter(null, '-1'), isNull);
      expect(parseRetryAfter('-5', null), isNull);
      expect(parseRetryAfter(null, 'garbage'), isNull);
    });
  });
}
