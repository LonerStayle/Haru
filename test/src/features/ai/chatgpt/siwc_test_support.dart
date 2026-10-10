import 'dart:convert';

import 'package:solo_todo/src/features/ai/chatgpt/siwc_account.dart';

/// 서명 없는 가짜 JWT (claims 검사만 하므로 충분).
String fakeJwt(Map<String, dynamic> claims, {String alg = 'RS256'}) {
  String part(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${part({'alg': alg, 'kid': 'k1'})}.${part(claims)}.c2ln';
}

const testClientId = 'oaiapp_test123';
const testSubject = 'user-sub-1';

SiwcAccountRecord signedInRecord({
  String access = 'access-1',
  String? refresh = 'refresh-1',
  int expiresAtMs = 0,
  bool planUsage = true,
  String? idToken = 'id-token-1',
  String? email = 'me@example.com',
}) => SiwcAccountRecord(
  clientId: testClientId,
  state: SiwcAccountState.signedIn,
  subject: testSubject,
  email: email,
  idToken: idToken,
  accessToken: access,
  refreshToken: refresh,
  expiresAtMs: expiresAtMs,
  scopes: planUsage
      ? const ['openid', 'chatgpt.tokens.use.direct']
      : const ['openid'],
  planUsage: planUsage,
  authorizationEpoch: 1,
);

/// SSE 본문 — 이벤트마다 `data:` 한 줄 + 빈 줄.
String sseBody(List<Map<String, dynamic>> events) =>
    events.map((e) => 'data: ${jsonEncode(e)}\n\n').join();

List<Map<String, dynamic>> textResponseEvents(
  List<String> deltas, {
  String terminal = 'response.completed',
}) {
  final text = deltas.join();
  final item = {
    'type': 'message',
    'id': 'msg_1',
    'role': 'assistant',
    'content': [
      {'type': 'output_text', 'text': text},
    ],
  };
  var seq = 0;
  return [
    {
      'type': 'response.created',
      'response': {'id': 'resp_1'},
      'sequence_number': seq++,
    },
    for (final d in deltas)
      {
        'type': 'response.output_text.delta',
        'delta': d,
        'sequence_number': seq++,
      },
    {
      'type': 'response.output_item.done',
      'output_index': 0,
      'item': item,
      'sequence_number': seq++,
    },
    {
      'type': terminal,
      'response': {
        'id': 'resp_1',
        'output': [item],
        if (terminal == 'response.incomplete')
          'incomplete_details': {'reason': 'max_output_tokens'},
      },
      'sequence_number': seq++,
    },
  ];
}
