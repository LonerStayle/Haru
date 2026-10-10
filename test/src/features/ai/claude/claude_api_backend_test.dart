import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solo_todo/src/features/ai/ai_backend.dart';
import 'package:solo_todo/src/features/ai/ai_route.dart';
import 'package:solo_todo/src/features/ai/claude/claude_api_backend.dart';
import 'package:solo_todo/src/features/ai/claude/claude_errors.dart';
import 'package:solo_todo/src/features/ai/claude/claude_key_store.dart';

import 'claude_test_support.dart';

typedef Handler = FutureOr<http.Response> Function(http.Request r);

const _schema = <String, dynamic>{
  'type': 'object',
  'additionalProperties': false,
  'required': ['ok'],
  'properties': {
    'ok': {'type': 'boolean'},
  },
};

http.Response okRes(http.Request _) => jsonRes(
  message([
    {'type': 'text', 'text': '{"ok":true}'},
  ]),
  200,
);

class _Prompter implements AiSignInPrompter {
  _Prompter(this.answer);

  final String? answer;
  final asked = <({String title, String hint})>[];

  @override
  Future<String?> askCode({required String message}) async =>
      throw StateError('askCode 는 쓰지 않는다');

  @override
  Future<String?> askSecret({
    required String title,
    required String hint,
  }) async {
    asked.add((title: title, hint: hint));
    return answer;
  }
}

void main() {
  final t0 = DateTime.utc(2026, 10, 10, 12);
  late DateTime now;
  late List<http.Request> requests;
  late List<Handler> queue;
  late List<Duration> sleeps;
  late MemoryClaudeKeyStore store;
  late ClaudeApiBackend backend;

  ClaudeApiBackend make({DateTime Function()? clock}) => ClaudeApiBackend(
    httpClient: MockClient((r) async {
      requests.add(r);
      if (queue.isEmpty) return okRes(r);
      return queue.removeAt(0)(r);
    }),
    store: store,
    clock: clock ?? () => now,
    sleep: (d) async => sleeps.add(d),
  );

  setUp(() {
    now = t0;
    requests = [];
    queue = [];
    sleeps = [];
    store = MemoryClaudeKeyStore(testKey);
    backend = make();
  });

  tearDown(() => backend.dispose());

  Future<Map<String, dynamic>?> callJson() =>
      backend.gateway.json(instructions: '확인', input: 'ping', schema: _schema);

  Future<AiAccountStatus> statusNow() => backend.watchStatus().first;

  test('경로는 claudeApi, 저장값은 예전과 같은 claude', () {
    expect(backend.route, AiRoute.claudeApi);
    expect(AiRoute.claudeApi.storageValue, 'claude');
    expect(AiRoute.fromStorage('claude'), AiRoute.claudeApi);
    expect(AiRoute.claudeApi.label(compact: false), 'Claude API');
    expect(AiRoute.claudeApi.label(compact: true), 'Claude');
  });

  group('상태', () {
    test('키 없음 → AiSignedOut, 있음 → 끝 4자만 보인다', () async {
      final s = await statusNow();
      expect(s, isA<AiSignedIn>());
      expect((s as AiSignedIn).label, 'API 키 ····abcd');
      expect(s.plan, isNull);

      backend.dispose();
      store = MemoryClaudeKeyStore();
      backend = make();
      expect(await statusNow(), isA<AiSignedOut>());
    });
  });

  group('오류·재시도', () {
    test('529 → 재시도 후 성공 (1초 대기)', () async {
      queue
        ..add((_) => errorRes(529, 'overloaded_error'))
        ..add(okRes);
      expect(await callJson(), {'ok': true});
      expect(requests, hasLength(2));
      expect(sleeps, [const Duration(seconds: 1)]);
    });

    test('500 이 계속되면 2회까지만 (1초·2초) 후 null', () async {
      queue.addAll([
        (_) => errorRes(500, 'api_error'),
        (_) => errorRes(500, 'api_error'),
        (_) => errorRes(500, 'api_error'),
      ]);
      expect(await callJson(), isNull);
      expect(requests, hasLength(3));
      expect(sleeps, [const Duration(seconds: 1), const Duration(seconds: 2)]);
    });

    test('연결 오류도 재시도한다', () async {
      queue
        ..add((_) => throw http.ClientException('reset'))
        ..add(okRes);
      expect(await callJson(), {'ok': true});
      expect(requests, hasLength(2));
    });

    for (final (status, type) in [
      (400, 'invalid_request_error'),
      (403, 'permission_error'),
      (404, 'not_found_error'),
      (413, 'request_too_large'),
    ]) {
      test('$status 는 재시도하지 않는다', () async {
        queue.add((_) => errorRes(status, type));
        expect(await callJson(), isNull);
        expect(requests, hasLength(1));
        expect(sleeps, isEmpty);
      });
    }

    test('429 retry-after 는 그 값만큼 기다려 재시도, 계속이면 AiPaused', () async {
      Handler limited(String ra) =>
          (_) =>
              errorRes(429, 'rate_limit_error', headers: {'retry-after': ra});
      queue.addAll([limited('3'), limited('3'), limited('7')]);
      final seen = <AiAccountStatus>[];
      final sub = backend.watchStatus().listen(seen.add);
      await Future<void>.delayed(Duration.zero);

      expect(await callJson(), isNull);
      expect(requests, hasLength(3));
      expect(sleeps, [const Duration(seconds: 3), const Duration(seconds: 3)]);
      await Future<void>.delayed(Duration.zero);
      final paused = seen.last as AiPaused;
      expect(paused.until, t0.add(const Duration(seconds: 7)));
      expect(paused.label, 'API 키 ····abcd');
      await sub.cancel();
    });

    test('retry-after 가 15초 합을 넘으면 바로 멈추고 그만큼 쉰다', () async {
      queue.add(
        (_) =>
            errorRes(429, 'rate_limit_error', headers: {'retry-after': '60'}),
      );
      expect(await callJson(), isNull);
      expect(requests, hasLength(1));
      expect(sleeps, isEmpty);
      final s = await statusNow();
      expect((s as AiPaused).until, t0.add(const Duration(seconds: 60)));
    });

    test('retry-after 가 없으면 1초·2초 재시도 후 60초 쉰다, 시간이 지나면 풀린다', () {
      fakeAsync((async) {
        backend.dispose();
        backend = make(clock: () => t0.add(async.elapsed));
        queue.addAll([
          (_) => errorRes(429, 'rate_limit_error'),
          (_) => errorRes(429, 'rate_limit_error'),
          (_) => errorRes(429, 'rate_limit_error'),
        ]);
        final seen = <AiAccountStatus>[];
        backend.watchStatus().listen(seen.add);
        Map<String, dynamic>? result = {'pending': true};
        callJson().then((r) => result = r);
        async.flushMicrotasks();
        expect(result, isNull);
        expect(sleeps, [
          const Duration(seconds: 1),
          const Duration(seconds: 2),
        ]);
        expect(seen.last, isA<AiPaused>());
        expect(
          (seen.last as AiPaused).until,
          t0.add(const Duration(seconds: 60)),
        );
        async.elapse(const Duration(seconds: 61));
        expect(seen.last, isA<AiSignedIn>());
      });
    });

    test('401 → 키는 남기고 "거부됨" 표시, 성공하면 지워진다', () async {
      queue.add((_) => errorRes(401, 'authentication_error'));
      final seen = <AiAccountStatus>[];
      final sub = backend.watchStatus().listen(seen.add);
      await Future<void>.delayed(Duration.zero);

      expect(await callJson(), isNull);
      expect(requests, hasLength(1), reason: '401 은 재시도하지 않는다');
      await Future<void>.delayed(Duration.zero);
      expect(store.apiKey, testKey);
      expect(seen.last, isA<AiSignedIn>());
      expect((seen.last as AiSignedIn).label, 'API 키 ····abcd · 거부됨');
      expect((seen.last as AiSignedIn).rejected, isTrue);

      expect(await callJson(), {'ok': true});
      await Future<void>.delayed(Duration.zero);
      expect((seen.last as AiSignedIn).label, 'API 키 ····abcd');
      expect((seen.last as AiSignedIn).rejected, isFalse);
      await sub.cancel();
    });

    test('스트림 429 (텍스트 전) → error 이벤트 + AiPaused', () async {
      queue.addAll([
        for (var i = 0; i < 3; i++) (_) => errorRes(429, 'rate_limit_error'),
      ]);
      Object? error;
      await backend.gateway
          .stream(instructions: 'x', input: 'y')
          .handleError((Object e) => error = e)
          .drain<void>();
      expect((error as ClaudeApiException).kind, ClaudeErrorKind.rateLimited);
      expect(await statusNow(), isA<AiPaused>());
    });

    test('오류 문자열에 키·서버 message 가 없다', () {
      const e = ClaudeApiException(
        ClaudeErrorKind.badRequest,
        status: 400,
        type: 'invalid_request_error',
      );
      expect(e.toString(), contains('badRequest'));
      expect(e.toString(), isNot(contains('sk-ant')));
      expect(
        const ClaudeApiException(
          ClaudeErrorKind.other,
          type: 'sk-ant-leak message',
        ).toString(),
        isNot(contains('sk-ant')),
      );
    });
  });

  group('키 입력', () {
    setUp(() {
      backend.dispose();
      store = MemoryClaudeKeyStore();
      backend = make();
    });

    test('앞뒤 공백을 지우고 GET /v1/models 로 확인한 뒤 저장한다', () async {
      queue.add((_) => jsonRes({'data': []}, 200));
      final seen = <AiAccountStatus>[];
      final sub = backend.watchStatus().listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      final prompter = _Prompter('  sk-ant-api03-new-wxyz \n');

      await backend.signIn(prompter);
      expect(prompter.asked.single.title, 'Anthropic API 키');
      expect(prompter.asked.single.hint, contains('sk-ant-'));
      final r = requests.single;
      expect(r.method, 'GET');
      expect(r.url.toString(), 'https://api.anthropic.com/v1/models');
      expect(r.headers['x-api-key'], 'sk-ant-api03-new-wxyz');
      expect(r.headers['anthropic-version'], '2023-06-01');
      expect(store.apiKey, 'sk-ant-api03-new-wxyz');
      await Future<void>.delayed(Duration.zero);
      expect(seen.first, isA<AiSignedOut>());
      expect((seen.last as AiSignedIn).label, 'API 키 ····wxyz');
      await sub.cancel();
    });

    test('취소(null)면 아무것도 하지 않는다', () async {
      await backend.signIn(_Prompter(null));
      expect(requests, isEmpty);
      expect(store.writes, 0);
    });

    test('sk-ant- 로 시작하지 않으면 확인 요청 없이 안내', () async {
      await expectLater(
        backend.signIn(_Prompter('sk-proj-abc')),
        throwsA(
          isA<AiSignInException>().having(
            (e) => e.message,
            'message',
            'Anthropic API 키(sk-ant-…)를 넣어 주세요',
          ),
        ),
      );
      expect(requests, isEmpty);
      expect(store.apiKey, isNull);
    });

    test('서버가 잠시 바쁘면(529) 키는 저장하고 실제 호출에서 다시 확인', () async {
      queue.add((_) => jsonRes({}, 529));
      await backend.signIn(_Prompter('sk-ant-api03-busy-wxyz'));
      expect(store.apiKey, 'sk-ant-api03-busy-wxyz');
    });

    for (final (label, Handler reply, text) in [
      ('401', (_) => jsonRes({}, 401), '키가 맞지 않아요'),
      (
        '403',
        (_) => jsonRes({}, 403),
        '이 키로는 쓸 수 없어요 · 콘솔에서 권한을 확인해 주세요 (HTTP 403)',
      ),
      ('404', (_) => jsonRes({}, 404), '확인하지 못했어요 (HTTP 404)'),
      (
        '400 크레딧 부족',
        (_) => jsonRes({
          'type': 'error',
          'error': {
            'type': 'invalid_request_error',
            'message':
                'Your credit balance is too low to access the Anthropic API.',
          },
        }, 400),
        'API 크레딧이 부족해요 · Anthropic 콘솔 Billing 에서 충전해 주세요 '
            '(HTTP 400 · Your credit balance is too low to access the Anthropic API.)',
      ),
      (
        '400 그 밖',
        (_) => jsonRes({
          'type': 'error',
          'error': {'type': 'invalid_request_error', 'message': 'bad thing'},
        }, 400),
        '확인하지 못했어요 (HTTP 400 · bad thing)',
      ),
      (
        '연결 오류',
        (_) => throw const SocketException('down'),
        '확인하지 못했어요 · 잠시 후 다시 (SocketException)',
      ),
    ]) {
      test('확인 실패 $label → "$text", 저장 안 함', () async {
        queue.add(reply);
        await expectLater(
          backend.signIn(_Prompter('sk-ant-bad')),
          throwsA(
            isA<AiSignInException>().having((e) => e.message, 'message', text),
          ),
        );
        expect(store.apiKey, isNull);
        expect(await statusNow(), isA<AiSignedOut>());
      });
    }

    test('키 지우기 → 저장소에서 삭제, AiSignedOut', () async {
      queue.add((_) => jsonRes({'data': []}, 200));
      await backend.signIn(_Prompter('sk-ant-x-1234'));
      final seen = <AiAccountStatus>[];
      final sub = backend.watchStatus().listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      await backend.signOut();
      await Future<void>.delayed(Duration.zero);
      expect(store.apiKey, isNull);
      expect(seen.first, isA<AiSignedIn>());
      expect(seen.last, isA<AiSignedOut>());
      expect(await callJson(), isNull);
      expect(requests, hasLength(1), reason: '키가 없으면 보내지 않는다');
      await sub.cancel();
    });
  });

  test('키 지우기가 실패하면 상태를 비우지 않고 실패를 올린다', () async {
    final seen = <AiAccountStatus>[];
    final sub = backend.watchStatus().listen(seen.add);
    await Future<void>.delayed(Duration.zero);
    store.failDeletes = true;
    await expectLater(backend.signOut(), throwsA(isA<FileSystemException>()));
    await Future<void>.delayed(Duration.zero);
    expect(store.apiKey, testKey);
    expect(seen, hasLength(1));
    expect(await statusNow(), isA<AiSignedIn>());
    await sub.cancel();
  });

  group('파일 저장소', () {
    late Directory dir;
    late ClaudeKeyFileStore fileStore;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('haru_claude_key');
      fileStore = ClaudeKeyFileStore(directory: () async => dir);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    File file(String name) => File('${dir.path}/$name');

    test('원자적 쓰기 — .tmp 를 남기지 않고 같은 이름으로 저장', () async {
      expect(await fileStore.read(), isNull);
      await fileStore.write(testKey);
      expect(file('ai_claude_api_key.json').existsSync(), isTrue);
      expect(file('ai_claude_api_key.json.tmp').existsSync(), isFalse);
      expect(jsonDecode(file('ai_claude_api_key.json').readAsStringSync()), {
        'apiKey': testKey,
      });
      expect(await fileStore.read(), testKey);

      await fileStore.write('sk-ant-second');
      expect(await fileStore.read(), 'sk-ant-second');
    });

    test('지우기는 본 파일과 .tmp 를 모두 지운다', () async {
      await fileStore.write(testKey);
      file('ai_claude_api_key.json.tmp').writeAsStringSync('half');
      await fileStore.delete();
      expect(file('ai_claude_api_key.json').existsSync(), isFalse);
      expect(file('ai_claude_api_key.json.tmp').existsSync(), isFalse);
      expect(await fileStore.read(), isNull);
      await fileStore.delete(); // 없어도 조용히
    });

    test('깨진 파일은 없는 것으로', () async {
      file('ai_claude_api_key.json').writeAsStringSync('{not json');
      expect(await fileStore.read(), isNull);
      file('ai_claude_api_key.json').writeAsStringSync('{"apiKey":""}');
      expect(await fileStore.read(), isNull);
    });

    test('백엔드 — 파일에 저장된 키를 읽어 시작하고, 지우면 파일이 사라진다', () async {
      await fileStore.write(testKey);
      final b = ClaudeApiBackend(
        httpClient: MockClient((r) async => jsonRes({}, 200)),
        store: fileStore,
      );
      addTearDown(b.dispose);
      final s = await b.watchStatus().first;
      expect((s as AiSignedIn).label, 'API 키 ····abcd');
      await b.signOut();
      expect(file('ai_claude_api_key.json').existsSync(), isFalse);
    });
  });
}
