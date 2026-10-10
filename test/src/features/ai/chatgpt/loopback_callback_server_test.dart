import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/features/ai/chatgpt/loopback_callback_server.dart';

typedef _Res = ({int status, String body, HttpHeaders headers});

Future<_Res> _send(String method, Uri uri) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, uri);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return (status: res.statusCode, body: body, headers: res.headers);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late LoopbackCallbackServer server;

  Uri at(String pathAndQuery) =>
      Uri.parse('http://127.0.0.1:${server.port}$pathAndQuery');

  setUp(() async {
    server = LoopbackCallbackServer(
      expectedState: 'good-state',
      fallbackPage: () => 'FALLBACK',
      preferredPort: 0,
    );
    await server.start();
  });

  tearDown(() => server.close());

  test('127.0.0.1 bind, redirect_uri 는 127.0.0.1:<port>/auth/callback', () {
    expect(server.port, greaterThan(0));
    expect(server.redirectUri, 'http://127.0.0.1:${server.port}/auth/callback');
  });

  test('잘못된 요청은 상태 코드만 돌려주고 계속 기다린다', () async {
    expect((await _send('GET', at('/favicon.ico'))).status, 404);
    expect(
      (await _send('POST', at('/auth/callback?state=good-state'))).status,
      405,
    );
    expect((await _send('GET', at('/auth/callback?code=x'))).status, 400);
    expect(
      (await _send('GET', at('/auth/callback?state=bad&code=x'))).status,
      400,
    );
    expect(
      (await _send(
        'GET',
        at('/auth/callback?state=good-state&state=good-state&code=x'),
      )).status,
      400,
    );
    expect(
      (await _send(
        'GET',
        at('/auth/callback?state=good-state&code=a&code=b'),
      )).status,
      400,
    );

    final pending = _send(
      'GET',
      at('/auth/callback?state=good-state&code=the%20code&client_id=oaiapp_1'),
    );
    final cb = await server.awaitCallback();
    expect(cb.params['code'], 'the code');
    expect(cb.params['client_id'], 'oaiapp_1');
    await cb.respond('<p>done</p>');
    await cb.respond('ignored');
    final res = await pending;
    expect(res.status, 200);
    expect(res.body, '<p>done</p>');
    expect(res.headers.value('cache-control'), 'no-store');
    expect(res.headers.value('referrer-policy'), 'no-referrer');
    expect(res.headers.value('x-content-type-options'), 'nosniff');
    expect(res.headers.value('connection'), 'close');
    expect(res.headers.contentType?.mimeType, 'text/html');

    // 이미 결과를 받았으면 409
    expect(
      (await _send('GET', at('/auth/callback?state=good-state&code=y'))).status,
      409,
    );
  });

  test('상태 응답 본문은 text/plain "<status> <reason>"', () async {
    final res = await _send('GET', at('/nope'));
    expect(res.body, '404 Not Found\n');
    expect(res.headers.contentType?.mimeType, 'text/plain');
  });

  test('응답 상한을 넘기면 오류 페이지', () async {
    await server.close();
    server = LoopbackCallbackServer(
      expectedState: 'good-state',
      fallbackPage: () => 'FALLBACK',
      preferredPort: 0,
      responseTimeout: const Duration(milliseconds: 100),
    );
    await server.start();
    final pending = _send('GET', at('/auth/callback?state=good-state&code=x'));
    await server.awaitCallback();
    final res = await pending;
    expect(res.status, 200);
    expect(res.body, 'FALLBACK');
  });

  test('close 시 응답 못 한 콜백에 오류 페이지, 대기자는 StateError', () async {
    final pending = _send('GET', at('/auth/callback?state=good-state&code=x'));
    await server.awaitCallback();
    await server.close();
    expect((await pending).body, 'FALLBACK');

    final other = LoopbackCallbackServer(
      expectedState: 's',
      fallbackPage: () => 'F',
      preferredPort: 0,
    );
    await other.start();
    final waiting = other.awaitCallback();
    await other.close();
    await expectLater(waiting, throwsStateError);
  });

  test('선호 포트가 쓰이고 있으면 다른 포트', () async {
    final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final s = LoopbackCallbackServer(
      expectedState: 's',
      fallbackPage: () => 'F',
      preferredPort: blocker.port,
    );
    await s.start();
    expect(s.port, isNot(blocker.port));
    await s.close();
    await blocker.close();
  });
}
