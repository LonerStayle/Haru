import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'chatgpt_errors.dart';
import 'responses_accumulator.dart';
import 'siwc_config.dart';
import 'siwc_credentials.dart';
import 'sse.dart';

/// 보조 호출 재시도 예산 (사양서 A.15 — 하루 호출은 전부 보조).
class RetryBudget {
  const RetryBudget({
    this.maxRetries = 2,
    this.maxTotalWait = const Duration(seconds: 15),
  });

  final int maxRetries;
  final Duration maxTotalWait;
}

/// `/v1/responses`·`/v1/models` 전송 — 자격·401 갱신·재시도·한도 신호.
class ChatGptClient {
  ChatGptClient({
    required http.Client client,
    required SiwcCredentials credentials,
    Future<void> Function(Duration)? sleep,
    Random? random,
    DateTime Function()? clock,
    this.budget = const RetryBudget(),
    this.onUsageLimited,
    this.onSuccess,
  }) : _client = client,
       _credentials = credentials,
       _sleep = sleep ?? Future<void>.delayed,
       _random = random ?? Random(),
       _clock = clock ?? DateTime.now;

  final http.Client _client;
  final SiwcCredentials _credentials;
  final Future<void> Function(Duration) _sleep;
  final Random _random;
  final DateTime Function() _clock;
  final RetryBudget budget;

  /// 서버가 플랜 사용량 한도를 알렸을 때.
  void Function()? onUsageLimited;

  /// 완료 응답을 받았을 때 (한도 일시 중지 해제).
  void Function()? onSuccess;

  /// 응답 하나를 끝까지 받는다. [onDelta] 로 텍스트 조각을 흘린다.
  ///
  /// 재시도는 첫 텍스트 조각이 나가기 전 실패만 — 이미 화면에 글자가 나갔으면 하지 않는다.
  /// 같은 [body] 문자열을 그대로 재전송한다.
  Future<ResponseOutcome> respond(
    String body, {
    required String sessionId,
    void Function(String delta)? onDelta,
    Future<void>? abort,
  }) async {
    final done = await _withAttempts((cred) async {
      final request = http.AbortableRequest(
        'POST',
        Uri.parse(SiwcConfig.responsesUrl),
        abortTrigger: abort,
      );
      request.headers.addAll({
        'Authorization': 'Bearer ${cred.bearer}',
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
        'X-Client-Request-Id': 'haru-${const Uuid().v4()}',
        'session_id': sessionId,
      });
      request.body = body;
      final res = await _client
          .send(request)
          .timeout(SiwcConfig.responseHeadersTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return _HttpFailure(res.statusCode, await _readError(res), res.headers);
      }
      var started = false;
      final acc = ResponsesAccumulator(
        onTextDelta: (d) {
          started = true;
          onDelta?.call(d);
        },
      );
      try {
        await for (final event in sseEvents(
          res.stream.timeout(SiwcConfig.responseIdleTimeout),
        )) {
          if (acc.accept(event)) break;
        }
        return _Done(acc.finish());
      } on ChatGptException catch (e) {
        return _StreamFailure(e, started: started);
      } on http.RequestAbortedException {
        rethrow;
      } catch (_) {
        return _StreamFailure(networkError, started: started);
      }
    });
    return (done as _Done).outcome;
  }

  /// 플랜 모델 카탈로그 원문. 플랜 응답 모양이 아니어도 그대로 돌려준다.
  Future<Map<String, dynamic>> fetchModels() async {
    final done = await _withAttempts((cred) async {
      final res = await _client
          .get(
            Uri.parse(SiwcConfig.modelsUrl),
            headers: {
              'Authorization': 'Bearer ${cred.bearer}',
              'Accept': 'application/json',
              'X-Client-Request-Id': 'haru-${const Uuid().v4()}',
            },
          )
          .timeout(SiwcConfig.responseHeadersTimeout);
      if (res.statusCode != 200) {
        return _HttpFailure(
          res.statusCode,
          ApiErrorBody.parse(res.body),
          res.headers,
        );
      }
      try {
        final json = jsonDecode(res.body);
        if (json is Map<String, dynamic>) return _Json(json);
      } catch (_) {}
      return _StreamFailure(
        const ChatGptException(
          ChatGptErrorKind.protocol,
          'ChatGPT 응답을 읽지 못했어요.',
        ),
        started: false,
      );
    }, countSuccess: false);
    return (done as _Json).json;
  }

  Future<_Attempt> _withAttempts(
    Future<_Attempt> Function(SiwcCredential cred) attempt, {
    bool countSuccess = true,
  }) async {
    var cred = await _credentials.current();
    var refreshedFor401 = false;
    var retries = 0;
    var waited = Duration.zero;
    while (true) {
      _Attempt result;
      try {
        result = await attempt(cred);
      } on http.RequestAbortedException {
        rethrow;
      } on TimeoutException {
        result = const _StreamFailure(networkError, started: false);
      } on http.ClientException {
        result = const _StreamFailure(networkError, started: false);
      }

      final ChatGptException error;
      switch (result) {
        case _Done(:final outcome):
          _credentials.onSuccess();
          if (countSuccess && outcome is ResponseCompleted) onSuccess?.call();
          return result;
        case _Json():
          _credentials.onSuccess();
          return result;
        case _HttpFailure(:final status, :final body, :final headers):
          if (status == 401) {
            if (!refreshedFor401) {
              refreshedFor401 = true;
              cred = await _credentials.refreshAfterUnauthorized(cred);
              continue; // 같은 body 즉시 재전송 (재시도 예산 밖)
            }
            await _credentials.onRejectedAfterRefresh(body.code);
          }
          error = classifyHttp(
            status,
            body,
            retryAfter: parseRetryAfter(
              headers['retry-after-ms'],
              headers['retry-after'],
              now: _clock(),
            ),
          );
        case _StreamFailure(:final exception, :final started):
          if (started) {
            _signal(exception);
            throw exception;
          }
          error = exception;
      }

      _signal(error);
      debugPrint(
        '[haru.ai] CALL failed kind=${error.kind.name} '
        'status=${error.status} code=${_safe(error.code)} '
        'param=${_safe(error.param)}',
      );
      if (!error.retryable || retries >= budget.maxRetries) throw error;
      retries++;
      final wait = _waitFor(error, retries);
      if (wait == null || waited + wait > budget.maxTotalWait) throw error;
      waited += wait;
      await _sleep(wait);
      cred = await _credentials.current();
    }
  }

  void _signal(ChatGptException e) {
    if (e.kind == ChatGptErrorKind.usageLimited) onUsageLimited?.call();
  }

  /// 서버 힌트가 있으면 max(힌트, 백오프)+지터, 503 힌트 없으면 1초+백오프.
  Duration? _waitFor(ChatGptException e, int retry) {
    final cap = min(8000, 500 * pow(2, retry - 1).toInt());
    final backoff = Duration(milliseconds: _random.nextInt(cap + 1));
    final hint = e.retryAfter;
    if (hint != null) {
      final base = hint > backoff ? hint : backoff;
      return base + Duration(milliseconds: _random.nextInt(251));
    }
    if (e.kind == ChatGptErrorKind.serviceUnavailable) {
      return const Duration(seconds: 1) + backoff;
    }
    return backoff;
  }

  Future<ApiErrorBody> _readError(http.StreamedResponse res) async {
    try {
      final bytes = await res.stream.toBytes().timeout(
        const Duration(seconds: 20),
      );
      return ApiErrorBody.parse(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return const ApiErrorBody(shape: ErrorShape.empty);
    }
  }
}

final _safePattern = RegExp(r'^[A-Za-z0-9_.:\-]{1,100}$');

/// 로그에는 기계 값 모양일 때만.
String? _safe(String? v) =>
    v == null ? null : (_safePattern.hasMatch(v) ? v : 'other');

sealed class _Attempt {
  const _Attempt();
}

class _Done extends _Attempt {
  const _Done(this.outcome);

  final ResponseOutcome outcome;
}

class _Json extends _Attempt {
  const _Json(this.json);

  final Map<String, dynamic> json;
}

class _HttpFailure extends _Attempt {
  const _HttpFailure(this.status, this.body, this.headers);

  final int status;
  final ApiErrorBody body;
  final Map<String, String> headers;
}

class _StreamFailure extends _Attempt {
  const _StreamFailure(this.exception, {required this.started});

  final ChatGptException exception;
  final bool started;
}
