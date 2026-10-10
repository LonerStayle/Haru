import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 로그인 시도 1회의 비밀 값 — 메모리에만 두고 시도가 끝나면 버린다. 로그 금지.
class LoginSecrets {
  const LoginSecrets({
    required this.state,
    required this.nonce,
    required this.verifier,
  });

  final String state;
  final String nonce;
  final String verifier;

  String get challenge => challengeOf(verifier);

  @override
  String toString() => 'LoginSecrets(***)';
}

/// state 32B, nonce 32B, verifier 64B → base64url 무패딩 (43 / 43 / 86자).
LoginSecrets generateLoginSecrets([Random? random]) {
  final rnd = random ?? Random.secure();
  List<int> bytes(int n) => List<int>.generate(n, (_) => rnd.nextInt(256));
  return LoginSecrets(
    state: base64UrlNoPad(bytes(32)),
    nonce: base64UrlNoPad(bytes(32)),
    verifier: base64UrlNoPad(bytes(64)),
  );
}

/// S256: base64url(SHA-256(ASCII(verifier))) 무패딩.
String challengeOf(String verifier) =>
    base64UrlNoPad(sha256.convert(ascii.encode(verifier)).bytes);

String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// 상수 시간 문자열 비교 (state·nonce).
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  final n = min(x.length, y.length);
  for (var i = 0; i < n; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}
