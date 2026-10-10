import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'siwc_config.dart';
import 'siwc_id_token.dart';

/// 토큰 응답에서 뽑은 값 (사양서 A.8).
class TokenSet {
  const TokenSet({
    required this.accessToken,
    required this.receivedAtMs,
    this.refreshToken,
    this.idToken,
    this.scope,
    this.expiresInS,
    this.earliestRefreshAtS,
    this.serverDateMs,
  });

  final String accessToken;
  final String? refreshToken;
  final String? idToken;
  final String? scope;
  final int? expiresInS;

  /// 서버 기준 절대 Unix 초.
  final int? earliestRefreshAtS;
  final int receivedAtMs;
  final int? serverDateMs;

  List<String>? get scopes =>
      scope?.split(' ').where((s) => s.isNotEmpty).toList();

  int get expiresAtMs => TokenTiming.expiresAtMs(receivedAtMs, expiresInS);

  int get earliestRefreshAtMs => TokenTiming.earliestRefreshAtMs(
    receivedAtMs: receivedAtMs,
    expiresAtMs: expiresAtMs,
    earliestRefreshAtS: earliestRefreshAtS,
    serverDateMs: serverDateMs,
    accessToken: accessToken,
  );

  @override
  String toString() => 'TokenSet(***)';
}

enum TokenFailureKind { network, server, client, malformed }

sealed class TokenResult {
  const TokenResult();
}

class TokenSuccess extends TokenResult {
  const TokenSuccess(this.tokens);

  final TokenSet tokens;
}

class TokenFailure extends TokenResult {
  const TokenFailure(this.kind, {this.status, this.code});

  final TokenFailureKind kind;
  final int? status;

  /// 서버 오류 code (정규식으로 걸러 로그에 써도 되는 값만).
  final String? code;

  bool get isTerminal =>
      kind == TokenFailureKind.client &&
      SiwcConfig.terminalRefreshCodes.contains(code);

  bool get isInvalidClient =>
      kind == TokenFailureKind.client && code == SiwcConfig.invalidClient;

  @override
  String toString() => 'TokenFailure(${kind.name}, $status, $code)';
}

enum RevokeResult { ok, retryable, rejected }

/// 토큰 엔드포인트 — 교환 / 갱신 / revoke. 본문은 form-urlencoded, client secret 없음.
class SiwcTokenEndpoint {
  SiwcTokenEndpoint({
    required http.Client client,
    int Function()? nowMs,
    this.tokenUrl = SiwcConfig.tokenUrl,
    this.revokeUrl = SiwcConfig.revokeUrl,
  }) : _client = client,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final http.Client _client;
  final int Function() _nowMs;
  final String tokenUrl;
  final String revokeUrl;

  Future<TokenResult> exchangeCode({
    required String clientId,
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) => _token({
    'grant_type': 'authorization_code',
    'client_id': clientId,
    'code': code,
    'code_verifier': codeVerifier,
    'redirect_uri': redirectUri,
    'resource': SiwcConfig.resource,
  });

  /// scope 는 보내지 않는다 (기존 grant 유지). 성공하면 refresh 도 회전한다.
  Future<TokenResult> refresh({
    required String clientId,
    required String refreshToken,
  }) => _token({
    'grant_type': 'refresh_token',
    'client_id': clientId,
    'refresh_token': refreshToken,
    'resource': SiwcConfig.resource,
  });

  Future<RevokeResult> revoke({
    required String clientId,
    required String refreshToken,
  }) async {
    try {
      final res = await _client
          .post(
            Uri.parse(revokeUrl),
            headers: const {'Accept': 'application/json'},
            body: {
              'token': refreshToken,
              'token_type_hint': 'refresh_token',
              'client_id': clientId,
            },
          )
          .timeout(SiwcConfig.tokenCallTimeout);
      if (res.statusCode == 200) return RevokeResult.ok;
      if (res.statusCode >= 500) return RevokeResult.retryable;
      debugPrint('[haru.ai] REVOKE rejected status=${res.statusCode}');
      return RevokeResult.rejected;
    } catch (_) {
      return RevokeResult.retryable;
    }
  }

  Future<TokenResult> _token(Map<String, String> form) async {
    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse(tokenUrl),
            headers: const {'Accept': 'application/json'},
            body: form,
          )
          .timeout(SiwcConfig.tokenCallTimeout);
    } catch (_) {
      return const TokenFailure(TokenFailureKind.network);
    }
    final status = res.statusCode;
    if (status >= 500) {
      return TokenFailure(
        TokenFailureKind.server,
        status: status,
        code: tokenErrorCode(_tryJson(res.body)),
      );
    }
    if (status != 200) {
      return TokenFailure(
        TokenFailureKind.client,
        status: status,
        code: tokenErrorCode(_tryJson(res.body)),
      );
    }
    final parsed = parseTokenResponse(
      res.body,
      receivedAtMs: _nowMs(),
      dateHeader: res.headers['date'],
    );
    return parsed == null
        ? const TokenFailure(TokenFailureKind.malformed, status: 200)
        : TokenSuccess(parsed);
  }
}

Object? _tryJson(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

final _codePattern = RegExp(r'^[A-Za-z0-9_.:\-]{1,100}$');

/// 오류 code — `{"error":"x"}` / `{"error":{"code"|"type"}}` / `{"code"}`. 정규식에 맞는 값만.
@visibleForTesting
String? tokenErrorCode(Object? json) {
  if (json is! Map) return null;
  String? ok(Object? v) => v is String && _codePattern.hasMatch(v) ? v : null;
  final error = json['error'];
  if (error is String) return ok(error);
  if (error is Map) return ok(error['code']) ?? ok(error['type']);
  return ok(json['code']);
}

/// 200 응답 본문 파싱. `access_token` 이 없으면 null (MALFORMED).
@visibleForTesting
TokenSet? parseTokenResponse(
  String body, {
  required int receivedAtMs,
  String? dateHeader,
}) {
  final json = _tryJson(body);
  if (json is! Map) return null;
  final access = json['access_token'];
  if (access is! String || access.isEmpty) return null;
  String? str(String k) {
    final v = json[k];
    return v is String && v.isNotEmpty ? v : null;
  }

  int? serverDate;
  if (dateHeader != null) {
    try {
      serverDate = HttpDate.parse(dateHeader).millisecondsSinceEpoch;
    } catch (_) {}
  }
  return TokenSet(
    accessToken: access,
    refreshToken: str('refresh_token'),
    idToken: str('id_token'),
    scope: str('scope'),
    expiresInS: _intOf(json['expires_in']),
    earliestRefreshAtS: _intOf(json['earliest_refresh_at']),
    receivedAtMs: receivedAtMs,
    serverDateMs: serverDate,
  );
}

int? _intOf(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return num.tryParse(v.trim())?.toInt();
  return null;
}

/// 만료·선갱신 시각 계산 (사양서 A.8 TokenTiming).
abstract final class TokenTiming {
  static int expiresAtMs(int receivedAtMs, int? expiresInS) {
    final s = (expiresInS != null && expiresInS > 0)
        ? expiresInS
        : SiwcConfig.defaultExpiresInSeconds;
    return receivedAtMs + s * 1000;
  }

  static int earliestRefreshAtMs({
    required int receivedAtMs,
    required int expiresAtMs,
    int? earliestRefreshAtS,
    int? serverDateMs,
    String? accessToken,
  }) {
    if (earliestRefreshAtS == null || earliestRefreshAtS <= 0) return 0;
    var serverNow = serverDateMs;
    if (serverNow == null && accessToken != null) {
      final iat = decodeJwtPart(accessToken, 1)?['iat'];
      if (iat is num) serverNow = iat.toInt() * 1000;
    }
    serverNow ??= receivedAtMs;
    final derived = receivedAtMs + (earliestRefreshAtS * 1000 - serverNow);
    if (derived > expiresAtMs) {
      return expiresAtMs - SiwcConfig.refreshMargin.inMilliseconds;
    }
    return derived;
  }

  static int refreshAtMs(int expiresAtMs, int earliestRefreshAtMs) {
    final byMargin = expiresAtMs - SiwcConfig.refreshMargin.inMilliseconds;
    return earliestRefreshAtMs > byMargin ? earliestRefreshAtMs : byMargin;
  }

  static bool needsRefresh({
    required String? accessToken,
    required int expiresAtMs,
    required int earliestRefreshAtMs,
    required int nowMs,
  }) {
    if (accessToken == null || accessToken.isEmpty) return true;
    if (nowMs >= expiresAtMs) return true;
    return nowMs >= refreshAtMs(expiresAtMs, earliestRefreshAtMs);
  }
}
