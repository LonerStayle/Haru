import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solo_todo/src/features/ai/ai_backend.dart';
import 'package:solo_todo/src/features/ai/chatgpt/chatgpt_errors.dart';
import 'package:solo_todo/src/features/ai/chatgpt/chatgpt_gateway.dart';
import 'package:solo_todo/src/features/ai/chatgpt/chatgpt_models.dart';
import 'package:solo_todo/src/features/ai/chatgpt/chatgpt_plan_backend.dart';
import 'package:solo_todo/src/features/ai/chatgpt/responses_request.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_account.dart';
import 'package:solo_todo/src/features/ai/chatgpt/siwc_store.dart';

import 'siwc_test_support.dart';

typedef Handler = FutureOr<http.Response> Function(http.Request r);

http.Response sse(List<Map<String, dynamic>> events) => http.Response.bytes(
  utf8.encode(sseBody(events)),
  200,
  headers: {'content-type': 'text/event-stream'},
);

http.Response jsonRes(Object body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

const _forbidden = [
  'background',
  'conversation',
  'max_output_tokens',
  'max_tool_calls',
  'metadata',
  'moderation',
  'multi_agent',
  'prompt',
  'prompt_cache_retention',
  'safety_identifier',
  'temperature',
  'top_logprobs',
  'top_p',
  'truncation',
  'user',
  'previous_response_id',
  'prompt_cache_options',
];

void main() {
  const hour = 3600 * 1000;
  const t0 = 1700000000000;
  late int nowMs;
  late MemorySiwcStore store;
  late List<http.Request> responses;
  late List<http.Request> tokenCalls;
  late List<http.Request> revokeCalls;
  late List<Handler> responseQueue;
  late Handler modelsReply;
  late Handler tokenReply;
  late List<Duration> sleeps;
  late ChatGptPlanBackend backend;

  final schema = {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'note': {'type': 'string'},
    },
    'required': ['title'],
  };

  ChatGptPlanBackend make({OpenUrl? openUrl, String? model}) =>
      ChatGptPlanBackend(
        httpClient: MockClient((r) async {
          final path = r.url.path;
          if (path.endsWith('/v1/models')) return modelsReply(r);
          if (path.endsWith('/v1/responses')) {
            responses.add(r);
            return responseQueue.removeAt(0)(r);
          }
          if (path.endsWith('/oauth/revoke')) {
            revokeCalls.add(r);
            return http.Response('', 200);
          }
          if (path.endsWith('/oauth/token')) {
            tokenCalls.add(r);
            return tokenReply(r);
          }
          return http.Response('', 404);
        }),
        store: store,
        openUrl: openUrl ?? (_) async => false,
        clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
        sleep: (d) async => sleeps.add(d),
        preferredPort: 0,
        model: model,
      );

  setUp(() {
    nowMs = t0;
    responses = [];
    tokenCalls = [];
    revokeCalls = [];
    responseQueue = [];
    sleeps = [];
    modelsReply = (_) => jsonRes({
      'models': [
        {
          'slug': 'gpt-6-astra',
          'display_name': 'GPT-6 Astra',
          'visibility': 'list',
          'supported_reasoning_levels': [
            {'effort': 'medium'},
            {'effort': 'high'},
          ],
        },
        {'slug': 'gpt-5.6-luna', 'visibility': 'list'},
        {'slug': 'gpt-6-astra', 'visibility': 'list'},
      ],
    }, 200);
    tokenReply = (_) => jsonRes({
      'access_token': 'access-2',
      'refresh_token': 'refresh-2',
      'expires_in': 3600,
    }, 200);
    store = MemorySiwcStore(
      SiwcStoreData(
        hostId: 'urn:uuid:h',
        account: signedInRecord(expiresAtMs: t0 + hour),
      ),
    );
    backend = make();
  });

  tearDown(() => backend.dispose());

  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  group('모델', () {
    test('카탈로그 파싱 — models 없으면 null, list 만 서버 순서, 중복 제거, 레벨 두 모양', () {
      expect(parseModelCatalog({'object': 'list', 'data': []}), isNull);
      final c = parseModelCatalog({
        'models': [
          {
            'slug': 'a',
            'visibility': 'hide',
            'supported_reasoning_levels': ['low', 'high'],
          },
          {'slug': 'b', 'display_name': 'B', 'visibility': 'list'},
          {'slug': 'b', 'visibility': 'list'},
          {'display_name': 'no slug'},
        ],
      })!;
      expect(c.map((m) => m.slug), ['a', 'b']);
      expect(c.first.displayName, 'a');
      expect(c.first.reasoningLevels, ['low', 'high']);
      expect(c.where((m) => m.listed).map((m) => m.slug), ['b']);
    });

    test('기본값이 카탈로그에 있으면(hide 포함) 그것, 없으면 null(기본 slug 사용)', () {
      final withLuna = parseModelCatalog({
        'models': [
          {'slug': 'x', 'visibility': 'list'},
          {'slug': 'gpt-6-luna', 'visibility': 'hide'},
        ],
      });
      expect(chooseDefaultModel(withLuna)!.slug, 'gpt-6-luna');
      final noLuna = parseModelCatalog({
        'models': [
          {'slug': 'h', 'visibility': 'hide'},
          {'slug': 'x', 'visibility': 'list'},
        ],
      });
      expect(chooseDefaultModel(noLuna), isNull);
      expect(chooseDefaultModel(null), isNull);
    });

    test('effort — low 지원하면 low, 아니면 가장 낮은 값', () {
      expect(reasoningEffortFor(null), 'low');
      expect(
        reasoningEffortFor(
          const CatalogModel(
            slug: 's',
            displayName: 's',
            visibility: 'list',
            reasoningLevels: ['high', 'medium'],
          ),
        ),
        'medium',
      );
    });

    test('listModels 는 list 만, 6시간 캐시', () async {
      var calls = 0;
      final inner = modelsReply;
      modelsReply = (r) {
        calls++;
        return inner(r);
      };
      expect((await backend.listModels()).map((m) => m.slug), [
        'gpt-6-astra',
        'gpt-5.6-luna',
      ]);
      await backend.listModels();
      expect(calls, 1);
      nowMs += 7 * hour - hour; // 6시간 지남
      // 토큰이 만료 근처라 갱신이 끼어들 수 있으니 갱신 응답도 준비돼 있다.
      await backend.listModels();
      expect(calls, 2);
    });
  });

  group('json()', () {
    test('schema 모드 — 바디 순서·필수 필드·헤더, 선택 필드 null 제거', () async {
      responseQueue.add(
        (_) => sse(textResponseEvents(['{"title":"사과","note":null}'])),
      );
      final out = await backend.gateway.json(
        instructions: '정리해',
        input: '사과 사기',
        schema: schema,
      );
      expect(out, {'title': '사과'});

      final r = responses.single;
      final body = bodyOf(r);
      expect(body.keys.toList(), [
        'model',
        'instructions',
        'reasoning',
        'text',
        'store',
        'stream',
        'prompt_cache_key',
        'input',
      ]);
      expect(body['model'], 'gpt-6-luna', reason: '카탈로그에 없어도 기본 slug(호출 확인됨)');
      expect(body['reasoning'], {'effort': 'low'});
      expect(body['store'], false);
      expect(body['stream'], true);
      expect(body['input'], [
        {'role': 'user', 'content': '사과 사기'},
      ]);
      final text = body['text'] as Map;
      expect(text['verbosity'], 'low');
      final format = text['format'] as Map;
      expect(format['type'], 'json_schema');
      expect(format['name'], 'haru_result');
      expect(format['strict'], true);
      final strict = format['schema'] as Map;
      expect(strict['additionalProperties'], false);
      expect(strict['required'], ['title', 'note']);
      expect((strict['properties'] as Map)['note'], {
        'type': ['string', 'null'],
      });
      for (final f in _forbidden) {
        expect(body.containsKey(f), isFalse, reason: f);
      }
      expect(r.body, isNot(contains('"system"')));

      expect(r.headers['Authorization'], 'Bearer access-1');
      expect(r.headers['Accept'], 'text/event-stream');
      expect(r.headers['Content-Type'], startsWith('application/json'));
      expect(r.headers['X-Client-Request-Id'], startsWith('haru-'));
      expect(r.headers['session_id'], haruCacheKey('정리해'));
      expect(body['prompt_cache_key'], haruCacheKey('정리해'));
    });

    test('기본 모델 gpt-6-luna 가 카탈로그에 있으면 그것', () async {
      modelsReply = (_) => jsonRes({
        'models': [
          {'slug': 'gpt-6-astra', 'visibility': 'list'},
          {'slug': 'gpt-6-luna', 'visibility': 'hide'},
        ],
      }, 200);
      responseQueue.add((_) => sse(textResponseEvents(['{"title":"a"}'])));
      await backend.gateway.json(instructions: 'i', input: 'x', schema: schema);
      expect(bodyOf(responses.single)['model'], 'gpt-6-luna');
      expect(bodyOf(responses.single)['reasoning'], {'effort': 'low'});
    });

    test('카탈로그를 못 받으면 gpt-6-luna', () async {
      modelsReply = (_) => http.Response('', 500);
      responseQueue.add((_) => sse(textResponseEvents(['{"title":"a"}'])));
      await backend.gateway.json(instructions: 'i', input: 'x', schema: schema);
      expect(bodyOf(responses.single)['model'], 'gpt-6-luna');
    });

    test('text.format 거절(400) → 프롬프트 JSON 모드 1회 재요청, 이후 계속 프롬프트 모드', () async {
      responseQueue
        ..add(
          (_) => jsonRes({
            'error': {
              'type': 'invalid_request_error',
              'code': 'unsupported_parameter',
              'param': 'text.format',
              'message': 'nope',
            },
          }, 400),
        )
        ..add((_) => sse(textResponseEvents(['결과입니다: {"title":"우유"} 끝'])))
        ..add((_) => sse(textResponseEvents(['{"title":"빵"}'])));
      final first = await backend.gateway.json(
        instructions: 'i',
        input: 'x',
        schema: schema,
      );
      expect(first, {'title': '우유'});
      expect(responses, hasLength(2));
      final prompt = bodyOf(responses[1]);
      expect(prompt.containsKey('text'), isTrue);
      expect((prompt['text'] as Map).containsKey('format'), isFalse);
      expect(prompt['instructions'], contains('출력은 JSON 하나만'));
      expect(prompt['instructions'], contains('"required":["title"]'));

      await backend.gateway.json(instructions: 'i', input: 'y', schema: schema);
      expect(responses, hasLength(3));
      expect(
        ((bodyOf(responses[2])['text'] as Map)).containsKey('format'),
        isFalse,
      );
    });

    test('detail 에 format 이 있는 400 도 거절로 본다', () {
      expect(
        isFormatRejection(
          const ChatGptException(
            ChatGptErrorKind.badRequest,
            'x',
            status: 400,
            detail: 'Unsupported text.format for this route',
          ),
        ),
        isTrue,
      );
      expect(
        isFormatRejection(
          const ChatGptException(
            ChatGptErrorKind.badRequest,
            'x',
            status: 400,
            code: 'other',
            detail: 'format',
          ),
        ),
        isFalse,
      );
    });

    test('프롬프트 모드에서 JSON 이 깨지면 null, 필수 key 없으면 null', () async {
      responseQueue.add(
        (_) => jsonRes({
          'error': {'param': 'text', 'message': 'bad'},
        }, 400),
      );
      responseQueue.add((_) => sse(textResponseEvents(['{"title": 깨짐'])));
      expect(
        await backend.gateway.json(
          instructions: 'i',
          input: 'x',
          schema: schema,
        ),
        isNull,
      );
      responseQueue.add((_) => sse(textResponseEvents(['{"note":"x"}'])));
      expect(
        await backend.gateway.json(
          instructions: 'i',
          input: 'x',
          schema: schema,
        ),
        isNull,
      );
    });

    test('401 → 강제 갱신 → 같은 body 재전송', () async {
      responseQueue
        ..add(
          (_) =>
              http.Response('Identity Edge route authentication policy', 401),
        )
        ..add((_) => sse(textResponseEvents(['{"title":"a"}'])));
      final out = await backend.gateway.json(
        instructions: 'i',
        input: 'x',
        schema: schema,
      );
      expect(out, {'title': 'a'});
      expect(tokenCalls, hasLength(1));
      expect(responses[0].body, responses[1].body);
      expect(responses[0].headers['Authorization'], 'Bearer access-1');
      expect(responses[1].headers['Authorization'], 'Bearer access-2');
      expect(
        responses[0].headers['X-Client-Request-Id'],
        isNot(responses[1].headers['X-Client-Request-Id']),
      );
      expect(store.data.account!.refreshToken, 'refresh-2');
    });

    test('갱신 뒤에도 401 → null, 같은 이유로 2번이면 재로그인 필요', () async {
      for (var i = 0; i < 4; i++) {
        responseQueue.add((_) => http.Response('denied', 401));
      }
      var n = 0;
      tokenReply = (_) {
        n++;
        return jsonRes({
          'access_token': 'access-r$n',
          'refresh_token': 'refresh-r$n',
          'expires_in': 3600,
        }, 200);
      };
      expect(
        await backend.gateway.json(
          instructions: 'i',
          input: 'x',
          schema: schema,
        ),
        isNull,
      );
      expect(await backend.watchStatus().first, isA<AiSignedIn>());
      expect(
        await backend.gateway.json(
          instructions: 'i',
          input: 'x',
          schema: schema,
        ),
        isNull,
      );
      expect(store.data.account!.state, SiwcAccountState.needsReauth);
      expect(await backend.watchStatus().first, isA<AiSignedOut>());
    });

    test('429 usage_limit_exceeded → null + AiPaused 30분, 성공하면 해제', () async {
      responseQueue.add(
        (_) => jsonRes({
          'error': {'code': 'subscription_sharing_usage_limit_exceeded'},
        }, 429),
      );
      expect(
        await backend.gateway.json(
          instructions: 'i',
          input: 'x',
          schema: schema,
        ),
        isNull,
      );
      expect(responses, hasLength(1), reason: '한도는 재시도하지 않는다');
      final status = await backend.watchStatus().first;
      expect(status, isA<AiPaused>());
      expect(
        (status as AiPaused).until,
        DateTime.fromMillisecondsSinceEpoch(t0 + 30 * 60000),
      );

      responseQueue.add((_) => sse(textResponseEvents(['{"title":"a"}'])));
      await backend.gateway.json(instructions: 'i', input: 'x', schema: schema);
      expect(await backend.watchStatus().first, isA<AiSignedIn>());
    });

    test('503 → 백오프 재시도(1초 하한) → 성공', () async {
      responseQueue
        ..add((_) => http.Response('', 503))
        ..add(
          (_) => jsonRes({
            'error': {'code': 'subscription_sharing_usage_unavailable'},
          }, 503),
        )
        ..add((_) => sse(textResponseEvents(['{"title":"a"}'])));
      final out = await backend.gateway.json(
        instructions: 'i',
        input: 'x',
        schema: schema,
      );
      expect(out, {'title': 'a'});
      expect(responses, hasLength(3));
      final responseSleeps = sleeps.where(
        (d) => d >= const Duration(seconds: 1),
      );
      expect(responseSleeps, hasLength(2));
      expect(responses[0].body, responses[2].body);
    });

    test('재시도는 최대 2회', () async {
      for (var i = 0; i < 5; i++) {
        responseQueue.add((_) => http.Response('', 500));
      }
      expect(
        await backend.gateway.json(
          instructions: 'i',
          input: 'x',
          schema: schema,
        ),
        isNull,
      );
      expect(responses, hasLength(3));
    });

    test('incomplete·refusal → null', () async {
      responseQueue.add(
        (_) => sse(
          textResponseEvents(['{"title":'], terminal: 'response.incomplete'),
        ),
      );
      expect(
        await backend.gateway.json(
          instructions: 'i',
          input: 'x',
          schema: schema,
        ),
        isNull,
      );
    });

    test('로그인 안 됨 → 요청 없이 null', () async {
      store.data = const SiwcStoreData();
      backend.dispose();
      backend = make();
      expect(
        await backend.gateway.json(
          instructions: 'i',
          input: 'x',
          schema: schema,
        ),
        isNull,
      );
      expect(responses, isEmpty);
    });
  });

  group('stream()', () {
    test('텍스트 델타를 그대로', () async {
      responseQueue.add((_) => sse(textResponseEvents(['안녕', '하세요', '!'])));
      final parts = await backend.gateway
          .stream(instructions: 'i', input: 'x')
          .toList();
      expect(parts, ['안녕', '하세요', '!']);
      final body = bodyOf(responses.single);
      expect(body.containsKey('text'), isFalse);
      expect(body['stream'], true);
      expect(body['store'], false);
    });

    test('incomplete → 델타 뒤 error', () async {
      responseQueue.add(
        (_) => sse(textResponseEvents(['반'], terminal: 'response.incomplete')),
      );
      final (parts, error) = await collect(
        backend.gateway.stream(instructions: 'i', input: 'x'),
      );
      expect(parts, ['반']);
      expect(
        error,
        isA<ChatGptException>().having(
          (e) => e.kind,
          'kind',
          ChatGptErrorKind.incomplete,
        ),
      );
    });

    test('스트림 도중 실패는 재시도하지 않는다', () async {
      responseQueue.add(
        (_) => http.Response.bytes(
          utf8.encode(
            sseBody([
              {'type': 'response.output_text.delta', 'delta': '중간까'},
            ]),
          ),
          200,
        ),
      );
      final (parts, error) = await collect(
        backend.gateway.stream(instructions: 'i', input: 'x'),
      );
      expect(parts, ['중간까']);
      expect(error, isA<ChatGptException>());
      expect(responses, hasLength(1));
    });
  });

  group('상태·로그아웃', () {
    test('첫 상태 = 로그인됨(이메일·플랜)', () async {
      store.data = SiwcStoreData(
        account: signedInRecord(expiresAtMs: t0 + hour).copyWith(plan: 'plus'),
      );
      backend.dispose();
      backend = make();
      final s = await backend.watchStatus().first;
      expect(s, isA<AiSignedIn>());
      expect((s as AiSignedIn).label, 'me@example.com');
      expect(s.plan, 'Plus');
    });

    test('planUsage=false 는 로그아웃 상태로 보인다', () async {
      store.data = SiwcStoreData(account: signedInRecord(planUsage: false));
      backend.dispose();
      backend = make();
      expect(await backend.watchStatus().first, isA<AiSignedOut>());
    });

    test('로그아웃 → revoke 후 토큰 삭제, 상태 스트림 갱신', () async {
      final seen = <AiAccountStatus>[];
      final sub = backend.watchStatus().listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      await backend.signOut();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(revokeCalls.single.bodyFields['token'], 'refresh-1');
      expect(store.data.account!.refreshToken, isNull);
      expect(backend.lastSignOutRevokeConfirmed, isTrue);
      expect(seen.first, isA<AiSignedIn>());
      expect(seen.last, isA<AiSignedOut>());
    });

    test('SIGNING_OUT 으로 남아 있으면 시작할 때 이어서 끝낸다', () async {
      store.data = SiwcStoreData(
        account: signedInRecord().copyWith(state: SiwcAccountState.signingOut),
      );
      backend.dispose();
      backend = make();
      await backend.watchStatus().first;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(revokeCalls, hasLength(1));
      expect(store.data.account!.state, SiwcAccountState.signedOut);
    });
  });

  group('로그인 (실제 loopback + 가짜 브라우저)', () {
    late String? lastNonce;
    late List<String> authorizeUrls;
    late Completer<String> page;
    late Map<String, String> Function(Map<String, String> q) callbackParams;
    late Map<String, dynamic> Function() idClaims;
    late String scope;

    Future<bool> browser(String url) async {
      authorizeUrls.add(url);
      final q = Uri.parse(url).queryParameters;
      lastNonce = q['nonce'];
      final redirect = Uri.parse(q['redirect_uri']!);
      final target = redirect.replace(
        queryParameters: {'state': q['state']!, ...callbackParams(q)},
      );
      unawaited(() async {
        final client = HttpClient();
        try {
          final res = await (await client.getUrl(target)).close();
          page.complete(await res.transform(utf8.decoder).join());
        } catch (e) {
          page.complete('ERR $e');
        } finally {
          client.close(force: true);
        }
      }());
      return true;
    }

    setUp(() {
      nowMs = DateTime.now().millisecondsSinceEpoch;
      lastNonce = null;
      authorizeUrls = [];
      page = Completer<String>();
      scope = 'openid email offline_access chatgpt.tokens.use.direct';
      callbackParams = (_) => {'code': 'auth-code', 'client_id': 'oaiapp_new'};
      idClaims = () => {
        'iss': 'https://auth.openai.com',
        'aud': 'oaiapp_new',
        'exp': nowMs ~/ 1000 + 3600,
        'nonce': lastNonce,
        'sub': 'sub-new',
        'email': 'new@example.com',
      };
      tokenReply = (_) => jsonRes({
        'access_token': 'acc',
        'refresh_token': 'ref',
        'id_token': fakeJwt(idClaims()),
        'expires_in': 3600,
        'scope': scope,
      }, 200);
      store = MemorySiwcStore();
      backend.dispose();
      backend = make(openUrl: browser);
    });

    test('새 등록 성공 — 발급 client_id 로 교환, 저장, 결과 페이지', () async {
      await backend.signIn(_NoPrompt());
      final url = authorizeUrls.single;
      expect(url, contains('client_id=dynamic_agent_client'));
      expect(url, contains('agent_name_hint=Haru'));
      expect(url, isNot(contains('+')));
      final form = tokenCalls.single.bodyFields;
      expect(form['client_id'], 'oaiapp_new');
      expect(form['code'], 'auth-code');
      expect(
        form['redirect_uri'],
        Uri.parse(url).queryParameters['redirect_uri'],
      );
      final rec = store.data.account!;
      expect(rec.state, SiwcAccountState.signedIn);
      expect(rec.clientId, 'oaiapp_new');
      expect(rec.planUsage, isTrue);
      expect(rec.email, 'new@example.com');
      expect(store.data.hostId, startsWith('urn:uuid:'));
      expect(await page.future, contains('연결됐어요'));
      expect(await backend.watchStatus().first, isA<AiSignedIn>());
    });

    test('콜백에 client_id 없음 → 등록 미완료', () async {
      callbackParams = (_) => {'code': 'c'};
      await expectLater(
        backend.signIn(_NoPrompt()),
        throwsA(isA<AiSignInException>()),
      );
      expect(tokenCalls, isEmpty);
      expect(await page.future, contains('연결하지 못했어요'));
    });

    test('dynamic_agent_client 를 돌려주면 등록 미완료', () async {
      callbackParams = (_) => {
        'code': 'c',
        'client_id': 'dynamic_agent_client',
      };
      await expectLater(
        backend.signIn(_NoPrompt()),
        throwsA(isA<AiSignInException>()),
      );
      expect(store.data.account, isNull);
    });

    test(
      '교환 invalid_grant → 실패, 발급 client_id 는 PENDING 으로 남아 다음은 PendingRetry',
      () async {
        tokenReply = (_) => jsonRes({'error': 'invalid_grant'}, 400);
        await expectLater(
          backend.signIn(_NoPrompt()),
          throwsA(isA<AiSignInException>()),
        );
        expect(store.data.account!.state, SiwcAccountState.pendingRegistration);
        expect(store.data.account!.clientId, 'oaiapp_new');

        page = Completer<String>();
        tokenReply = (_) => jsonRes({
          'access_token': 'acc',
          'refresh_token': 'ref',
          'id_token': fakeJwt(idClaims()),
          'scope': scope,
        }, 200);
        callbackParams = (_) => {'code': 'c2'};
        await backend.signIn(_NoPrompt());
        final second = authorizeUrls.last;
        expect(second, contains('client_id=oaiapp_new'));
        expect(second, isNot(contains('agent_name_hint')));
        expect(store.data.account!.state, SiwcAccountState.signedIn);
      },
    );

    test('access_denied → 거절 페이지', () async {
      callbackParams = (_) => {
        'error': 'access_denied',
        'client_id': 'oaiapp_new',
      };
      await expectLater(
        backend.signIn(_NoPrompt()),
        throwsA(
          isA<AiSignInException>().having(
            (e) => e.message,
            'message',
            contains('허용되지 않았어요'),
          ),
        ),
      );
      expect(await page.future, contains('허용되지 않았어요'));
    });

    test('재인가 콜백 client_id 불일치 → 실패, 덮어쓰지 않음', () async {
      store.data = SiwcStoreData(
        hostId: 'urn:uuid:h',
        account: signedInRecord().signedOut(0),
      );
      callbackParams = (_) => {'code': 'c', 'client_id': 'oaiapp_other'};
      await expectLater(
        backend.signIn(_NoPrompt()),
        throwsA(isA<AiSignInException>()),
      );
      expect(authorizeUrls.single, contains('client_id=$testClientId'));
      expect(authorizeUrls.single, contains('login_hint=me%40example.com'));
      expect(store.data.account!.state, SiwcAccountState.signedOut);
    });

    test('재인가에서 다른 계정(sub) → ACCOUNT_MISMATCH, 덮어쓰지 않음', () async {
      store.data = SiwcStoreData(
        hostId: 'urn:uuid:h',
        account: signedInRecord().signedOut(0),
      );
      callbackParams = (_) => {'code': 'c'};
      idClaims = () => {
        'iss': 'https://auth.openai.com',
        'aud': testClientId,
        'exp': nowMs ~/ 1000 + 3600,
        'nonce': lastNonce,
        'sub': 'someone-else',
      };
      await expectLater(
        backend.signIn(_NoPrompt()),
        throwsA(
          isA<AiSignInException>().having(
            (e) => e.message,
            'message',
            contains('같은 계정'),
          ),
        ),
      );
      expect(store.data.account!.subject, testSubject);
    });

    test('nonce 불일치 id_token → 실패', () async {
      idClaims = () => {
        'iss': 'https://auth.openai.com',
        'aud': 'oaiapp_new',
        'exp': nowMs ~/ 1000 + 3600,
        'nonce': 'forged',
        'sub': 'sub-new',
      };
      await expectLater(
        backend.signIn(_NoPrompt()),
        throwsA(isA<AiSignInException>()),
      );
    });

    test('plan scope 없음 → 저장(planUsage=false)·DENIED 페이지·다시 허용 안내', () async {
      scope = 'openid email offline_access';
      await expectLater(
        backend.signIn(_NoPrompt()),
        throwsA(isA<AiSignInException>()),
      );
      expect(store.data.account!.planUsage, isFalse);
      expect(store.data.account!.state, SiwcAccountState.signedIn);
      expect(await page.future, contains('허용되지 않았어요'));
      expect(await backend.watchStatus().first, isA<AiSignedOut>());
    });

    test('브라우저를 못 열면 실패', () async {
      backend.dispose();
      backend = make(openUrl: (_) async => false);
      await expectLater(
        backend.signIn(_NoPrompt()),
        throwsA(
          isA<AiSignInException>().having(
            (e) => e.message,
            'message',
            contains('브라우저'),
          ),
        ),
      );
    });

    test('진행 중 취소', () async {
      backend.dispose();
      backend = make(openUrl: (_) async => true);
      final attempt = backend.signIn(_NoPrompt());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      backend.cancelSignIn();
      await expectLater(
        attempt,
        throwsA(
          isA<AiSignInException>().having(
            (e) => e.message,
            'message',
            contains('취소'),
          ),
        ),
      );
    });
  });
}

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

class _NoPrompt implements AiSignInPrompter {
  @override
  Future<String?> askCode({required String message}) async => null;
}
