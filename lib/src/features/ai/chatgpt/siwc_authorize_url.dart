import 'dart:convert';

import 'siwc_config.dart';

/// 로그인 시작 모드 (사양서 A.3).
sealed class SiwcLoginMode {
  const SiwcLoginMode();

  /// 로그용 이름 (client_id 는 넣지 않는다).
  String get logName;

  /// authorize 요청에 실을 client_id.
  String get requestClientId;
}

/// 새 등록 — `dynamic_agent_client` + `agent_name_hint`. 콜백이 준 발급 client_id 로 교환한다.
final class SiwcNewAccount extends SiwcLoginMode {
  const SiwcNewAccount();

  @override
  String get logName => 'new';

  @override
  String get requestClientId => SiwcConfig.dynamicClient;
}

/// 저장 계정 재인가 — 저장 client_id + (보관 시) `id_token_hint`·`login_hint`.
final class SiwcReauth extends SiwcLoginMode {
  const SiwcReauth(this.clientId);

  final String clientId;

  @override
  String get logName => 'reauth';

  @override
  String get requestClientId => clientId;
}

/// 플랜 사용 다시 허용 — Reauth + `prompt=consent`.
final class SiwcReconsent extends SiwcLoginMode {
  const SiwcReconsent(this.clientId);

  final String clientId;

  @override
  String get logName => 'reconsent';

  @override
  String get requestClientId => clientId;
}

/// 새 등록 콜백에서 client_id 는 받았지만 교환·검증이 실패해 남은 등록으로 다시.
final class SiwcPendingRetry extends SiwcLoginMode {
  const SiwcPendingRetry(this.clientId);

  final String clientId;

  @override
  String get logName => 'pending_retry';

  @override
  String get requestClientId => clientId;
}

/// authorize 파라미터 — **순서 그대로** (사양서 A.4). host id 가 비면 만들지 않는다.
List<(String, String)> siwcAuthorizeParams({
  required SiwcLoginMode mode,
  required String hostId,
  required String redirectUri,
  required String state,
  required String nonce,
  required String codeChallenge,
  String? idTokenHint,
  String? loginHint,
}) {
  if (hostId.trim().isEmpty) {
    throw ArgumentError('ext_agent_host_id missing');
  }
  final out = <(String, String)>[('client_id', mode.requestClientId)];
  if (mode is SiwcNewAccount) {
    out.add(('agent_name_hint', SiwcConfig.agentName));
  }
  out.addAll([
    ('ext_agent_host_id', hostId),
    ('response_type', 'code'),
    ('redirect_uri', redirectUri),
    ('scope', SiwcConfig.scope),
    ('resource', SiwcConfig.resource),
    ('state', state),
    ('nonce', nonce),
    ('code_challenge_method', 'S256'),
    ('code_challenge', codeChallenge),
  ]);
  if (mode is SiwcReauth || mode is SiwcReconsent) {
    if (idTokenHint != null && idTokenHint.trim().isNotEmpty) {
      out.add(('id_token_hint', idTokenHint));
    }
    if (loginHint != null && loginHint.trim().isNotEmpty) {
      out.add(('login_hint', loginHint));
    }
  }
  if (mode is SiwcReconsent) out.add(('prompt', 'consent'));
  return out;
}

/// authorize URL. ⚠️ `id_token_hint` 가 들어갈 수 있다 — 로그·예외 메시지 금지.
///
/// `Uri.replace(queryParameters:)` 는 공백을 `+` 로 만들어 Andy 와 바이트가 달라지므로
/// RFC 3986 인코딩으로 쿼리를 직접 조립한다.
String buildSiwcAuthorizeUrl({
  required SiwcLoginMode mode,
  required String hostId,
  required String redirectUri,
  required String state,
  required String nonce,
  required String codeChallenge,
  String? idTokenHint,
  String? loginHint,
  String endpoint = SiwcConfig.authorizeUrl,
}) {
  final params = siwcAuthorizeParams(
    mode: mode,
    hostId: hostId,
    redirectUri: redirectUri,
    state: state,
    nonce: nonce,
    codeChallenge: codeChallenge,
    idTokenHint: idTokenHint,
    loginHint: loginHint,
  );
  return '$endpoint?${buildQuery(params)}';
}

String buildQuery(List<(String, String)> params) => params
    .map((p) => '${encodeRfc3986(p.$1)}=${encodeRfc3986(p.$2)}')
    .join('&');

const _hex = '0123456789ABCDEF';

/// RFC 3986 퍼센트 인코딩 — `A-Z a-z 0-9 - . _ ~` 만 그대로, 나머지는 UTF-8 바이트마다 `%XX`.
String encodeRfc3986(String value) {
  final sb = StringBuffer();
  for (final b in utf8.encode(value)) {
    final unreserved =
        (b >= 0x41 && b <= 0x5A) ||
        (b >= 0x61 && b <= 0x7A) ||
        (b >= 0x30 && b <= 0x39) ||
        b == 0x2D ||
        b == 0x2E ||
        b == 0x5F ||
        b == 0x7E;
    if (unreserved) {
      sb.writeCharCode(b);
    } else {
      sb
        ..write('%')
        ..write(_hex[b >> 4])
        ..write(_hex[b & 0x0F]);
    }
  }
  return sb.toString();
}
