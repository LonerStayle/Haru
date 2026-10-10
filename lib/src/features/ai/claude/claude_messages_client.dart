import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../chatgpt/sse.dart' show sseEvents;
import 'claude_config.dart';
import 'claude_errors.dart';
import 'claude_sse.dart';

/// 단발 JSON 호출 바디 — structured outputs (`output_config.format`).
///
/// 보내지 않는 것 (Opus 5.5 에서 400): `tool_choice` any/tool, `thinking` disabled·
/// `budget_tokens`, temperature/top_p/top_k, assistant prefill. thinking 은 생략 —
/// 항상 adaptive 다.
Map<String, dynamic> buildClaudeJsonBody({
  required String instructions,
  required String input,
  required Map<String, dynamic> schema,
}) => {
  'model': ClaudeConfig.model,
  'max_tokens': ClaudeConfig.jsonMaxTokens,
  'system': instructions,
  'messages': [
    {'role': 'user', 'content': input},
  ],
  'output_config': {
    'effort': 'low',
    'format': {'type': 'json_schema', 'schema': schema},
  },
  'fallbacks': 'default',
};

/// 스트림 호출 바디.
Map<String, dynamic> buildClaudeStreamBody({
  required String instructions,
  required String input,
}) => {
  'model': ClaudeConfig.model,
  'max_tokens': ClaudeConfig.streamMaxTokens,
  'system': instructions,
  'messages': [
    {'role': 'user', 'content': input},
  ],
  'output_config': {'effort': 'low'},
  'fallbacks': 'default',
  'stream': true,
};

/// Messages API 공통 헤더. 키는 이 헤더에만 실린다 (로그·예외에 남기지 않는다).
Map<String, String> claudeHeaders(String apiKey, {bool beta = true}) => {
  'content-type': 'application/json',
  'x-api-key': apiKey,
  'anthropic-version': ClaudeConfig.apiVersion,
  if (beta) 'anthropic-beta': ClaudeConfig.fallbackBeta,
};

/// `/v1/messages`·`/v1/models` 전송 — 재시도·한도·거부 신호.
///
/// 재시도는 429·500·529·연결 오류만, 최대 [ClaudeConfig.maxRetries] 회. 대기는
/// `retry-after` 가 있으면 그 값(합계 [ClaudeConfig.maxTotalWait] 이내), 없으면 1초·2초.
/// 텍스트가 이미 나간 스트림은 재시도하지 않는다.
class ClaudeMessagesClient {
  ClaudeMessagesClient({
    required http.Client client,
    required Future<String?> Function() apiKey,
    Future<void> Function(Duration)? sleep,
    this.onRateLimited,
    this.onUnauthorized,
    this.onSuccess,
    this.jsonRequestTimeout = ClaudeConfig.jsonAttemptTimeout,
  }) : _client = client,
       _apiKey = apiKey,
       _sleep = sleep ?? Future<void>.delayed;

  final http.Client _client;
  final Future<String?> Function() _apiKey;
  final Future<void> Function(Duration) _sleep;
  final Duration jsonRequestTimeout;

  /// 재시도 후에도 429 — 서버가 준 `retry-after` (없으면 null).
  void Function(Duration? retryAfter)? onRateLimited;

  /// 키가 거부됨 (401).
  void Function()? onUnauthorized;

  /// 응답을 끝까지 받았을 때.
  void Function()? onSuccess;

  /// 단발 호출 — 응답 메시지 JSON 원문.
  ///
  /// 한 번의 시도(머리+본문)는 [jsonRequestTimeout] 안에 끝나야 한다. 넘기면 그
  /// 요청을 끊고(이중 과금 방지) 재시도 규칙을 따른다.
  Future<Map<String, dynamic>> create(
    Map<String, dynamic> body, {
    Future<void>? abort,
  }) {
    final encoded = jsonEncode(body);
    return _withRetries(abort: abort, (key, attemptAbort) async {
      final request = http.AbortableRequest(
        'POST',
        Uri.parse(ClaudeConfig.messagesUrl),
        abortTrigger: attemptAbort,
      );
      request.headers.addAll({
        ...claudeHeaders(key),
        'accept': 'application/json',
      });
      request.body = encoded;
      return () async {
        final res = await _client.send(request);
        final bytes = await res.stream.toBytes();
        if (res.statusCode != 200) {
          throw _httpError(res.statusCode, bytes, res.headers);
        }
        try {
          final json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
          if (json is Map<String, dynamic>) return json;
        } catch (_) {}
        throw const ClaudeApiException(ClaudeErrorKind.protocol);
      }().timeout(jsonRequestTimeout);
    });
  }

  /// 스트림 호출 — 텍스트 조각을 [onText] 로 흘리고, 끝까지 받은 전체 텍스트를 돌려준다.
  Future<String> stream(
    Map<String, dynamic> body, {
    void Function(String text)? onText,
    Future<void>? abort,
  }) {
    final encoded = jsonEncode(body);
    var started = false;
    return _withRetries(abort: abort, (key, attemptAbort) async {
      final request = http.AbortableRequest(
        'POST',
        Uri.parse(ClaudeConfig.messagesUrl),
        abortTrigger: attemptAbort,
      );
      request.headers.addAll({
        ...claudeHeaders(key),
        'accept': 'text/event-stream',
      });
      request.body = encoded;
      final res = await _client
          .send(request)
          .timeout(ClaudeConfig.headersTimeout);
      if (res.statusCode != 200) {
        final bytes = await _readError(res);
        throw _httpError(res.statusCode, bytes, res.headers);
      }
      final acc = ClaudeStreamAccumulator(
        onText: (t) {
          started = true;
          onText?.call(t);
        },
      );
      await _drain(
        res.stream.timeout(ClaudeConfig.streamIdleTimeout),
        acc,
        attemptAbort,
      );
      return acc.finish();
    }, started: () => started);
  }

  /// 키 확인 — `GET /v1/models` 의 상태 코드. 연결 실패는 예외.
  /// 키 확인 — 상태 코드와, 실패면 서버의 오류 종류·문구. 이 요청엔 사용자 데이터가 없어
  /// 문구를 그대로 화면에 보여도 된다(예: "credit balance is too low").
  Future<({int status, String? type, String? message})> verifyKey(
    String apiKey,
  ) async {
    final res = await _client
        .get(
          Uri.parse(ClaudeConfig.modelsUrl),
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': ClaudeConfig.apiVersion,
            'accept': 'application/json',
          },
        )
        .timeout(ClaudeConfig.verifyTimeout);
    if (res.statusCode == 200) {
      return (status: 200, type: null, message: null);
    }
    String? type, message;
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      final error = body is Map ? body['error'] : null;
      if (error is Map) {
        type = error['type'] is String ? error['type'] as String : null;
        message = error['message'] is String
            ? error['message'] as String
            : null;
      }
    } catch (_) {}
    return (status: res.statusCode, type: type, message: message);
  }

  /// [attempt] 는 시도마다 새 중단 신호를 받는다 — 바깥 [abort] 가 오거나 그 시도가
  /// 끝나면(시간 초과 포함) 완료된다. 시간 초과된 요청이 서버에서 계속 돌며 재시도와
  /// 함께 두 번 과금되지 않게, 다음 시도 전에 반드시 끊는다.
  Future<T> _withRetries<T>(
    Future<T> Function(String key, Future<void> attemptAbort) attempt, {
    Future<void>? abort,
    bool Function()? started,
  }) async {
    final key = await _apiKey();
    if (key == null) {
      throw const ClaudeApiException(ClaudeErrorKind.noKey);
    }
    var outerAborted = false;
    Completer<void>? current;
    abort?.whenComplete(() {
      outerAborted = true;
      final c = current;
      if (c != null && !c.isCompleted) c.complete();
    });
    var retries = 0;
    var waited = Duration.zero;
    while (true) {
      if (outerAborted) throw http.RequestAbortedException();
      final attemptAbort = current = Completer<void>();
      ClaudeApiException error;
      try {
        final result = await attempt(key, attemptAbort.future);
        onSuccess?.call();
        return result;
      } on http.RequestAbortedException {
        rethrow;
      } on ClaudeApiException catch (e) {
        error = e;
      } on TimeoutException {
        error = networkFailure;
      } on http.ClientException {
        error = networkFailure;
      } on IOException {
        error = networkFailure;
      } finally {
        // 끝난 시도(성공·실패·시간 초과)의 요청은 여기서 끊는다 — 이미 끝났으면 무해.
        if (!attemptAbort.isCompleted) attemptAbort.complete();
      }
      if (outerAborted) throw http.RequestAbortedException();

      if (error.kind == ClaudeErrorKind.unauthorized) onUnauthorized?.call();
      debugPrint(
        '[haru.ai] CLAUDE call failed kind=${error.kind.name} '
        'status=${error.status} type=${safeErrorType(error.type)}',
      );

      Duration? wait;
      final mayRetry =
          error.kind.retryable &&
          retries < ClaudeConfig.maxRetries &&
          !(started?.call() ?? false);
      if (mayRetry) {
        final next = error.retryAfter ?? Duration(seconds: retries + 1);
        if (waited + next <= ClaudeConfig.maxTotalWait) wait = next;
      }
      if (wait == null) {
        if (error.kind == ClaudeErrorKind.rateLimited) {
          onRateLimited?.call(error.retryAfter);
        }
        throw error;
      }
      retries++;
      waited += wait;
      await _sleep(wait);
    }
  }

  /// 스트림을 끝까지 읽는다. [abort] 가 오면 응답 바이트 구독을 직접 끊는다
  /// (async* 해석기는 다음 바이트가 올 때까지 취소가 번지지 않아서).
  Future<void> _drain(
    Stream<List<int>> body,
    ClaudeStreamAccumulator acc,
    Future<void>? abort,
  ) {
    final done = Completer<void>();
    StreamSubscription<List<int>>? bodySub;
    final source = StreamController<List<int>>(sync: true);
    source.onListen = () {
      bodySub = body.listen(
        source.add,
        onError: source.addError,
        onDone: () => unawaited(source.close()),
      );
    };
    late final StreamSubscription<Map<String, dynamic>> sub;
    void finish([Object? error]) {
      if (!done.isCompleted) {
        error == null ? done.complete() : done.completeError(error);
      }
      unawaited(bodySub?.cancel());
      unawaited(sub.cancel());
    }

    sub = sseEvents(source.stream).listen(
      (event) {
        if (done.isCompleted) return;
        try {
          if (acc.accept(event)) finish();
        } catch (e) {
          finish(e);
        }
      },
      onError: (Object e) => finish(
        e is ClaudeApiException || e is http.RequestAbortedException
            ? e
            : networkFailure,
      ),
      onDone: finish,
      cancelOnError: true,
    );
    abort?.then((_) => finish(http.RequestAbortedException()));
    return done.future;
  }

  ClaudeApiException _httpError(
    int status,
    List<int> bytes,
    Map<String, String> headers,
  ) {
    String? type;
    try {
      type = errorTypeOf(jsonDecode(utf8.decode(bytes, allowMalformed: true)));
    } catch (_) {}
    var kind = kindForStatus(status);
    if (kind == ClaudeErrorKind.other) kind = kindForType(type);
    return ClaudeApiException(
      kind,
      status: status,
      type: type,
      retryAfter: parseRetryAfterSeconds(headers['retry-after']),
    );
  }

  Future<List<int>> _readError(http.StreamedResponse res) async {
    try {
      return await res.stream.toBytes().timeout(const Duration(seconds: 20));
    } catch (_) {
      return const [];
    }
  }
}
