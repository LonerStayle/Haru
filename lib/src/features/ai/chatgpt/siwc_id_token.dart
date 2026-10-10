import 'dart:convert';

import 'pkce.dart';
import 'siwc_config.dart';

/// 서명 검증 없이 JWT payload 를 읽는다. 구조가 깨졌으면 null.
Map<String, dynamic>? decodeJwtPart(String jwt, int index) {
  final parts = jwt.split('.');
  if (parts.length != 3 || index < 0 || index > 1) return null;
  try {
    final decoded = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[index])),
    );
    final json = jsonDecode(decoded);
    return json is Map<String, dynamic> ? json : null;
  } catch (_) {
    return null;
  }
}

class IdTokenClaims {
  const IdTokenClaims({
    required this.subject,
    required this.expiresAtS,
    this.email,
    this.planType,
  });

  final String subject;
  final String? email;
  final int expiresAtS;

  /// `https://api.openai.com/auth`.`chatgpt_plan_type` (plus / pro …). [미실측]
  final String? planType;
}

class IdTokenException implements Exception {
  const IdTokenException(this.reason);

  /// 로그에 써도 되는 사유 이름 (토큰 내용은 담지 않는다).
  final String reason;

  @override
  String toString() => 'IdTokenException($reason)';
}

/// id_token claims 검증 (사양서 C.8) — RS256 **서명 검증은 생략**한다.
///
/// 근거: OIDC Core §3.1.3.7 (6) — 토큰 엔드포인트에서 TLS 로 직접 받은 id_token 은
/// 서명 대신 TLS 서버 검증으로 갈음할 수 있다. 하루는 토큰 응답에서만 id_token 을 받는다.
IdTokenClaims verifySiwcIdTokenClaims(
  String idToken, {
  required String clientId,
  required String nonce,
  required int nowMs,
  String issuer = SiwcConfig.issuer,
}) {
  final header = decodeJwtPart(idToken, 0);
  final claims = decodeJwtPart(idToken, 1);
  if (header == null || claims == null) {
    throw const IdTokenException('malformed');
  }
  if (header['alg'] != 'RS256') throw const IdTokenException('alg');
  if (claims['iss'] != issuer) throw const IdTokenException('iss');

  final aud = claims['aud'];
  final List<String> audiences;
  if (aud is String) {
    audiences = [aud];
  } else if (aud is List) {
    audiences = aud.whereType<String>().toList();
  } else {
    throw const IdTokenException('aud');
  }
  if (!audiences.contains(clientId)) throw const IdTokenException('aud');
  final azp = claims['azp'];
  if (azp != null && azp != clientId) throw const IdTokenException('azp');
  if (audiences.length >= 2 && azp == null) {
    throw const IdTokenException('azp');
  }

  final exp = claims['exp'];
  if (exp is! num) throw const IdTokenException('exp');
  if (nowMs ~/ 1000 > exp.toInt() + SiwcConfig.idTokenLeewaySeconds) {
    throw const IdTokenException('exp');
  }

  final tokenNonce = claims['nonce'];
  if (tokenNonce is! String || !constantTimeEquals(tokenNonce, nonce)) {
    throw const IdTokenException('nonce');
  }

  final sub = claims['sub'];
  if (sub is! String || sub.isEmpty) throw const IdTokenException('sub');

  final email = claims['email'];
  final auth = claims['https://api.openai.com/auth'];
  final plan = auth is Map ? auth['chatgpt_plan_type'] : null;
  return IdTokenClaims(
    subject: sub,
    email: email is String && email.isNotEmpty ? email : null,
    expiresAtS: exp.toInt(),
    planType: plan is String && plan.isNotEmpty ? plan : null,
  );
}
