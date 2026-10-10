import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solo_todo/src/features/ai/claude/claude_api_backend.dart';
import 'package:solo_todo/src/features/ai/claude/claude_config.dart';
import 'package:solo_todo/src/features/ai/claude/claude_errors.dart';
import 'package:solo_todo/src/features/ai/claude/claude_key_store.dart';
import 'package:solo_todo/src/features/ai/claude/claude_messages_client.dart';
import 'package:solo_todo/src/features/ai/claude/claude_schema.dart';

import 'claude_test_support.dart';

typedef Handler = FutureOr<http.Response> Function(http.Request r);

const _schema = <String, dynamic>{
  'type': 'object',
  'additionalProperties': false,
  'required': ['title', 'note'],
  'properties': {
    'title': {'type': 'string', 'maxLength': 40},
    'note': {
      'type': ['string', 'null'],
    },
  },
};

Future<(List<String>, Object?)> collect(Stream<String> stream) async {
  final parts = <String>[];
  Object? error;
  final done = Completer<void>();
  stream.listen(
    parts.add,
    onError: (Object e) => error = e,
    onDone: done.complete,
  );
  await done.future;
  return (parts, error);
}

void main() {
  late List<http.Request> requests;
  late List<Handler> queue;
  late List<Duration> sleeps;
  late ClaudeApiBackend backend;
  late List<String> logs;
  late DebugPrintCallback savedPrint;

  setUp(() {
    requests = [];
    queue = [];
    sleeps = [];
    logs = [];
    savedPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
    backend = ClaudeApiBackend(
      httpClient: MockClient((r) async {
        requests.add(r);
        if (queue.isEmpty) return errorRes(500, 'api_error');
        return queue.removeAt(0)(r);
      }),
      store: MemoryClaudeKeyStore(testKey),
      sleep: (d) async => sleeps.add(d),
    );
  });

  tearDown(() {
    backend.dispose();
    debugPrint = savedPrint;
  });

  Future<Map<String, dynamic>?> callJson() =>
      backend.gateway.json(instructions: '지시문', input: '입력', schema: _schema);

  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  group('json', () {
    test('요청 바디·헤더가 정확하다', () async {
      queue.add(
        (_) => jsonRes(
          message([
            {'type': 'text', 'text': '{"title":"a","note":null}'},
          ]),
          200,
        ),
      );
      expect(await callJson(), {'title': 'a', 'note': null});

      final r = requests.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(r.headers['x-api-key'], testKey);
      expect(r.headers['anthropic-version'], '2023-06-01');
      expect(r.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
      expect(r.headers['content-type'], startsWith('application/json'));

      final body = bodyOf(r);
      expect(body['model'], 'claude-opus-5-5');
      expect(body['max_tokens'], 16000);
      expect(body['system'], '지시문');
      expect(body['messages'], [
        {'role': 'user', 'content': '입력'},
      ]);
      expect(body['fallbacks'], 'default');
      expect(body['output_config'], {
        'effort': 'low',
        'format': {'type': 'json_schema', 'schema': toClaudeSchema(_schema)},
      });
      for (final k in [
        'tool_choice',
        'tools',
        'thinking',
        'temperature',
        'top_p',
        'top_k',
        'stream',
      ]) {
        expect(body.containsKey(k), isFalse, reason: k);
      }
      // assistant prefill 없음.
      expect(
        (body['messages'] as List).every((m) => (m as Map)['role'] == 'user'),
        isTrue,
      );
    });

    test('thinking 블록은 무시하고 text 블록을 이어 붙인다', () async {
      queue.add(
        (_) => jsonRes(
          message([
            {'type': 'thinking', 'thinking': '', 'signature': 'sig'},
            {'type': 'text', 'text': '{"title":'},
            {'type': 'text', 'text': '"b","note":"n"}'},
          ]),
          200,
        ),
      );
      expect(await callJson(), {'title': 'b', 'note': 'n'});
    });

    for (final reason in ['refusal', 'max_tokens']) {
      test('stop_reason=$reason → null', () async {
        queue.add(
          (_) => jsonRes(
            message([
              {'type': 'text', 'text': '{"title":"a","note":null}'},
            ], stopReason: reason),
            200,
          ),
        );
        expect(await callJson(), isNull);
        expect(requests, hasLength(1));
      });
    }

    test('JSON 이 아니거나 객체가 아니면 null', () async {
      queue
        ..add(
          (_) => jsonRes(
            message([
              {'type': 'text', 'text': 'not json'},
            ]),
            200,
          ),
        )
        ..add(
          (_) => jsonRes(
            message([
              {'type': 'text', 'text': '[1,2]'},
            ]),
            200,
          ),
        );
      expect(await callJson(), isNull);
      expect(await callJson(), isNull);
    });

    test('키가 없으면 보내지 않고 null', () async {
      backend.dispose();
      backend = ClaudeApiBackend(
        httpClient: MockClient((r) async {
          requests.add(r);
          return jsonRes({}, 200);
        }),
        store: MemoryClaudeKeyStore(),
      );
      expect(await callJson(), isNull);
      expect(requests, isEmpty);
    });

    test('로그에 키·오류 message·본문이 남지 않는다', () async {
      queue.add((_) => errorRes(400, 'invalid_request_error'));
      expect(await callJson(), isNull);
      final all = logs.join('\n');
      expect(all, contains('invalid_request_error'));
      expect(all, isNot(contains(testKey)));
      expect(all, isNot(contains('SECRET-USER-TEXT')));
      expect(all, isNot(contains('지시문')));
    });
  });

  group('stream', () {
    Stream<String> callStream() =>
        backend.gateway.stream(instructions: '지시문', input: '입력');

    test('요청 바디 — stream:true · 64000 · effort low · format 없음', () async {
      queue.add((_) => sseRes(textStream(['a'])));
      await collect(callStream());
      final r = requests.single;
      expect(r.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
      expect(r.headers['x-api-key'], testKey);
      final body = bodyOf(r);
      expect(body['stream'], true);
      expect(body['max_tokens'], 64000);
      expect(body['model'], 'claude-opus-5-5');
      expect(body['output_config'], {'effort': 'low'});
      expect(body['fallbacks'], 'default');
      expect(body['system'], '지시문');
      for (final k in ['tool_choice', 'thinking', 'temperature', 'top_p']) {
        expect(body.containsKey(k), isFalse, reason: k);
      }
    });

    test('text_delta 만 흘린다 — thinking_delta·ping·블록 시작/끝 무시', () async {
      queue.add((_) => sseRes(textStream(['Hel', 'lo'])));
      final (parts, error) = await collect(callStream());
      expect(parts, ['Hel', 'lo']);
      expect(error, isNull);
    });

    test('서버 대체(fallback 블록)는 건너뛰고 이어지는 텍스트를 흘린다', () async {
      final events = textStream(['앞', '뒤'], withThinking: false);
      final at = events.indexWhere((e) => e['type'] == 'content_block_stop');
      events.insertAll(at, [
        {
          'type': 'content_block_start',
          'index': 2,
          'content_block': {'type': 'fallback', 'model': 'claude-opus-5'},
        },
        {'type': 'content_block_stop', 'index': 2},
      ]);
      queue.add((_) => sseRes(events));
      final (parts, error) = await collect(callStream());
      expect(parts, ['앞', '뒤']);
      expect(error, isNull);
    });

    test('refusal → error 이벤트', () async {
      queue.add((_) => sseRes(textStream(['부분'], stopReason: 'refusal')));
      final (parts, error) = await collect(callStream());
      expect(parts, ['부분']);
      expect(
        error,
        isA<ClaudeApiException>().having(
          (e) => e.kind,
          'kind',
          ClaudeErrorKind.refusal,
        ),
      );
      expect(requests, hasLength(1));
    });

    test('max_tokens 로 잘리면 incomplete error', () async {
      queue.add((_) => sseRes(textStream(['a'], stopReason: 'max_tokens')));
      final (_, error) = await collect(callStream());
      expect((error as ClaudeApiException).kind, ClaudeErrorKind.incomplete);
    });

    test('error 이벤트 — 텍스트가 나간 뒤면 재시도 없이 error', () async {
      final events = <Map<String, dynamic>>[
        {'type': 'message_start', 'message': message(const [])},
        {
          'type': 'content_block_start',
          'index': 1,
          'content_block': {'type': 'text', 'text': ''},
        },
        textDelta('a'),
      ];
      events.add({
        'type': 'error',
        'error': {'type': 'overloaded_error', 'message': 'SECRET-USER-TEXT'},
      });
      queue.add((_) => sseRes(events));
      final (parts, error) = await collect(callStream());
      expect(parts, ['a']);
      expect(
        error,
        isA<ClaudeApiException>()
            .having((e) => e.kind, 'kind', ClaudeErrorKind.overloaded)
            .having((e) => e.type, 'type', 'overloaded_error'),
      );
      expect(requests, hasLength(1));
      expect(error.toString(), isNot(contains('SECRET')));
    });

    test('텍스트 전 error 이벤트(overloaded) 는 재시도한다', () async {
      queue
        ..add(
          (_) => sseRes([
            {'type': 'message_start', 'message': message(const [])},
            {
              'type': 'error',
              'error': {'type': 'overloaded_error', 'message': 'x'},
            },
          ]),
        )
        ..add((_) => sseRes(textStream(['ok'])));
      final (parts, error) = await collect(callStream());
      expect(parts, ['ok']);
      expect(error, isNull);
      expect(requests, hasLength(2));
      expect(sleeps, [const Duration(seconds: 1)]);
    });

    test('message_stop 없이 끊기면 연결 오류', () async {
      queue.add(
        (_) => sseRes([
          {'type': 'message_start', 'message': message(const [])},
          textDelta('a'),
        ]),
      );
      final (parts, error) = await collect(callStream());
      expect(parts, ['a']);
      expect((error as ClaudeApiException).kind, ClaudeErrorKind.network);
      expect(requests, hasLength(1), reason: '텍스트가 나갔으면 재시도 안 함');
    });

    test('구독을 취소하면 요청을 중단하고 응답 스트림을 닫는다', () async {
      final body = StreamController<List<int>>();
      var bodyCancelled = false;
      body.onCancel = () => bodyCancelled = true;
      Future<void>? abortTrigger;
      backend.dispose();
      backend = ClaudeApiBackend(
        httpClient: MockClient.streaming((request, _) async {
          if (request is http.Abortable) {
            abortTrigger = request.abortTrigger;
          }
          return http.StreamedResponse(body.stream, 200);
        }),
        store: MemoryClaudeKeyStore(testKey),
      );
      final first = Completer<String>();
      final sub = callStream().listen((t) {
        if (!first.isCompleted) first.complete(t);
      });
      body.add(
        utf8.encode(
          claudeSseBody([
            {'type': 'message_start', 'message': message(const [])},
            textDelta('첫'),
          ]),
        ),
      );
      expect(await first.future, '첫');
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(bodyCancelled, isTrue);
      expect(abortTrigger, isNotNull);
      var aborted = false;
      unawaited(abortTrigger!.then((_) => aborted = true));
      await Future<void>.delayed(Duration.zero);
      expect(aborted, isTrue);
    });
  });

  group('시도별 시간 초과', () {
    test('시간 초과된 시도는 끊은 뒤에 재시도한다 (두 요청이 겹치지 않는다)', () async {
      final triggers = <Future<void>>[];
      var aborted = 0;
      var inFlightAtSecond = -1;
      final client = ClaudeMessagesClient(
        client: MockClient.streaming((request, _) async {
          final trigger = (request as http.Abortable).abortTrigger!;
          triggers.add(trigger);
          if (triggers.length == 1) {
            // 응답이 오지 않는 첫 시도 — 끊기면 IOClient 처럼 중단 예외.
            await trigger;
            aborted++;
            throw http.RequestAbortedException(request.url);
          }
          inFlightAtSecond = triggers.length - 1 - aborted;
          final res = jsonRes(
            message([
              {'type': 'text', 'text': '{"ok":true}'},
            ]),
            200,
          );
          return http.StreamedResponse(
            Stream.value(res.bodyBytes),
            200,
            headers: res.headers,
          );
        }),
        apiKey: () async => testKey,
        sleep: (d) async => sleeps.add(d),
        jsonRequestTimeout: const Duration(milliseconds: 20),
      );
      final res = await client.create(const {'model': 'x'});
      expect(res['content'], isNotEmpty);
      expect(triggers, hasLength(2));
      expect(aborted, 1, reason: '첫 요청은 재시도 전에 끊긴다');
      expect(inFlightAtSecond, 0, reason: '두 번째 요청 때 살아 있는 요청이 없다');
      expect(sleeps, [const Duration(seconds: 1)]);
    });

    test('바깥에서 중단하면 다음 시도를 보내지 않는다', () async {
      final outer = Completer<void>();
      var sent = 0;
      final client = ClaudeMessagesClient(
        client: MockClient((r) async {
          sent++;
          return errorRes(529, 'overloaded_error');
        }),
        apiKey: () async => testKey,
        sleep: (d) async {
          if (!outer.isCompleted) outer.complete();
          await Future<void>.delayed(Duration.zero);
        },
      );
      await expectLater(
        client.create(const {'model': 'x'}, abort: outer.future),
        throwsA(isA<http.RequestAbortedException>()),
      );
      expect(sent, 1);
    });

    test('JSON 전체 한도는 모든 시도 + 재시도 대기보다 길다', () {
      expect(
        ClaudeConfig.jsonTotalTimeout,
        greaterThan(
          ClaudeConfig.jsonAttemptTimeout * (ClaudeConfig.maxRetries + 1) +
              ClaudeConfig.maxTotalWait,
        ),
      );
    });
  });
}
