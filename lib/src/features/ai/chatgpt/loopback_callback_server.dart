import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'pkce.dart';
import 'siwc_config.dart';

/// state 가 맞는 콜백 1건. 응답은 교환·검증 뒤 [respond] 로 보낸다.
///
/// ⚠️ [params] 에 인가 code 가 들어 있다 — 로그 금지.
class CallbackRequest {
  CallbackRequest._(
    this.params,
    this._response,
    this._fallbackPage,
    Duration timeout,
  ) {
    _timer = Timer(timeout, () {
      unawaited(respond(_fallbackPage()));
    });
  }

  final Map<String, String> params;
  final HttpResponse _response;
  final String Function() _fallbackPage;
  late final Timer _timer;
  bool _responded = false;

  bool get responded => _responded;

  /// 결과 페이지(200). 1회만 — 두 번째부터는 무시.
  Future<void> respond(String html) async {
    if (_responded) return;
    _responded = true;
    _timer.cancel();
    await _write(_response, 200, html, html: true);
  }
}

/// 127.0.0.1 전용 loopback 콜백 서버 (사양서 A.6).
///
/// 다른 앱·favicon 요청이 시도를 끝내지 못하도록, state 가 맞는 첫 요청이 올 때까지
/// 나머지는 상태 코드만 돌려주고 계속 기다린다.
class LoopbackCallbackServer {
  LoopbackCallbackServer({
    required this.expectedState,
    required this.fallbackPage,
    this.preferredPort = SiwcConfig.preferredPort,
    this.path = SiwcConfig.callbackPath,
    this.responseTimeout = SiwcConfig.callbackResponseTimeout,
  });

  final String expectedState;
  final String Function() fallbackPage;
  final int preferredPort;
  final String path;

  /// 붙잡은 콜백 응답을 결과 없이 기다리는 상한 — 넘으면 오류 페이지.
  final Duration responseTimeout;

  HttpServer? _server;
  final _result = Completer<CallbackRequest>();
  CallbackRequest? _held;
  bool _closed = false;

  int get port => _server!.port;

  String get redirectUri =>
      'http://${SiwcConfig.callbackHost}:$port${SiwcConfig.callbackPath}';

  /// 127.0.0.1 에 bind. 선호 포트가 쓰이고 있으면 임의 포트(0).
  Future<void> start() async {
    HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        preferredPort,
      );
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    server
      ..autoCompress = false
      ..idleTimeout = const Duration(seconds: 5);
    server.defaultResponseHeaders.clear();
    _server = server;
    server.listen(_handle, onError: (Object _) {});
  }

  /// state 가 맞는 첫 콜백. [close] 되면 [StateError].
  Future<CallbackRequest> awaitCallback() => _result.future;

  void _handle(HttpRequest request) {
    final res = request.response;
    final reqPath = request.uri.path;
    if (reqPath != path) {
      debugPrint('[haru.ai] LOGIN stray_request status=404');
      unawaited(_status(res, 404));
      return;
    }
    if (request.method != 'GET') {
      unawaited(_status(res, 405));
      return;
    }
    if (_result.isCompleted || _closed) {
      unawaited(_status(res, 409));
      return;
    }
    Map<String, List<String>> all;
    try {
      all = request.uri.queryParametersAll;
    } catch (_) {
      unawaited(_status(res, 400));
      return;
    }
    for (final key in const ['state', 'code', 'client_id', 'error']) {
      if ((all[key]?.length ?? 0) > 1) {
        unawaited(_status(res, 400));
        return;
      }
    }
    final state = all['state']?.first;
    if (state == null || !constantTimeEquals(state, expectedState)) {
      unawaited(_status(res, 400));
      return;
    }
    final params = {
      for (final e in all.entries)
        if (e.value.isNotEmpty) e.key: e.value.first,
    };
    final held = CallbackRequest._(params, res, fallbackPage, responseTimeout);
    _held = held;
    _result.complete(held);
  }

  /// 포트를 푼다. 아직 응답 못 한 콜백에는 오류 페이지를 보낸다.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_result.isCompleted) {
      _result.completeError(StateError('callback server closed'));
      // 아무도 기다리지 않을 때 처리되지 않은 오류가 되지 않게.
      unawaited(_result.future.then((_) {}, onError: (Object _) {}));
    }
    final held = _held;
    if (held != null && !held.responded) {
      try {
        await held.respond(fallbackPage());
      } catch (_) {}
    }
    await _server?.close(force: true);
  }
}

const _reasons = {
  200: 'OK',
  400: 'Bad Request',
  404: 'Not Found',
  405: 'Method Not Allowed',
  409: 'Conflict',
};

Future<void> _status(HttpResponse res, int status) =>
    _write(res, status, '$status ${_reasons[status]}\n', html: false);

Future<void> _write(
  HttpResponse res,
  int status,
  String body, {
  required bool html,
}) async {
  try {
    final bytes = utf8.encode(body);
    res
      ..statusCode = status
      ..reasonPhrase = _reasons[status] ?? 'OK'
      ..persistentConnection = false
      ..contentLength = bytes.length;
    res.headers
      ..set(
        HttpHeaders.contentTypeHeader,
        html ? 'text/html; charset=utf-8' : 'text/plain; charset=utf-8',
      )
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('X-Content-Type-Options', 'nosniff');
    res.add(bytes);
    await res.close();
  } catch (_) {
    // 브라우저가 먼저 끊었으면 할 일이 없다.
  }
}
