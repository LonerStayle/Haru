import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 계정 상태 (사양서 A.10).
enum SiwcAccountState {
  pendingRegistration,
  signedIn,
  signingOut,
  signedOut,
  needsReauth;

  static SiwcAccountState? fromName(Object? raw) {
    for (final s in values) {
      if (s.name == raw) return s;
    }
    return null;
  }
}

/// 재로그인이 필요한 사유 (앱 판정). 그 밖은 서버 terminal code 문자열 그대로.
abstract final class SiwcReauthReason {
  static const invalidClient = 'invalid_client';
  static const unauthorizedAfterRefresh = 'unauthorized_after_refresh';
  static const missingRefreshToken = 'missing_refresh_token';
}

/// 이 기기의 ChatGPT 등록·토큰 한 벌.
///
/// 하루는 1인용이라 Andy 의 다중 계정 목록 대신 **계정 하나**만 둔다.
/// ⚠️ toString 에 토큰을 넣지 않는다.
class SiwcAccountRecord {
  const SiwcAccountRecord({
    required this.clientId,
    required this.state,
    this.subject,
    this.email,
    this.plan,
    this.idToken,
    this.accessToken,
    this.refreshToken,
    this.expiresAtMs = 0,
    this.earliestRefreshAtMs = 0,
    this.scopes = const [],
    this.savedAtMs = 0,
    this.createdAtMs = 0,
    this.planUsage = false,
    this.needsReauthReason,
    this.authorizationEpoch = 0,
  });

  final String clientId;
  final SiwcAccountState state;
  final String? subject;
  final String? email;
  final String? plan;
  final String? idToken;
  final String? accessToken;
  final String? refreshToken;
  final int expiresAtMs;
  final int earliestRefreshAtMs;
  final List<String> scopes;
  final int savedAtMs;
  final int createdAtMs;

  /// 토큰 scope 에 `chatgpt.tokens.use.direct` 가 있는지 — 없으면 추론하지 않는다.
  final bool planUsage;
  final String? needsReauthReason;
  final int authorizationEpoch;

  /// 로그에 써도 되는 식별자 — sha256(clientId|subject) 앞 16자.
  String? get accountKey {
    final sub = subject;
    if (sub == null) return null;
    return sha256
        .convert(utf8.encode('$clientId|$sub'))
        .toString()
        .substring(0, 16);
  }

  static const _unset = Object();

  SiwcAccountRecord copyWith({
    SiwcAccountState? state,
    Object? subject = _unset,
    Object? email = _unset,
    Object? plan = _unset,
    Object? idToken = _unset,
    Object? accessToken = _unset,
    Object? refreshToken = _unset,
    int? expiresAtMs,
    int? earliestRefreshAtMs,
    List<String>? scopes,
    int? savedAtMs,
    bool? planUsage,
    Object? needsReauthReason = _unset,
    int? authorizationEpoch,
  }) {
    T pick<T>(Object? v, T old) => identical(v, _unset) ? old : v as T;
    return SiwcAccountRecord(
      clientId: clientId,
      state: state ?? this.state,
      subject: pick(subject, this.subject),
      email: pick(email, this.email),
      plan: pick(plan, this.plan),
      idToken: pick(idToken, this.idToken),
      accessToken: pick(accessToken, this.accessToken),
      refreshToken: pick(refreshToken, this.refreshToken),
      expiresAtMs: expiresAtMs ?? this.expiresAtMs,
      earliestRefreshAtMs: earliestRefreshAtMs ?? this.earliestRefreshAtMs,
      scopes: scopes ?? this.scopes,
      savedAtMs: savedAtMs ?? this.savedAtMs,
      createdAtMs: createdAtMs,
      planUsage: planUsage ?? this.planUsage,
      needsReauthReason: pick(needsReauthReason, this.needsReauthReason),
      authorizationEpoch: authorizationEpoch ?? this.authorizationEpoch,
    );
  }

  /// 로그아웃 — 토큰 3종·만료값만 지우고 clientId·subject·email 은 남긴다(같은 등록으로 재로그인).
  SiwcAccountRecord signedOut(int nowMs) => copyWith(
    state: SiwcAccountState.signedOut,
    idToken: null,
    accessToken: null,
    refreshToken: null,
    expiresAtMs: 0,
    earliestRefreshAtMs: 0,
    needsReauthReason: null,
    savedAtMs: nowMs,
  );

  /// terminal 갱신 오류 — access·refresh 만 지우고 idToken 은 보존(재인가 `id_token_hint`).
  SiwcAccountRecord needsReauthTerminal(String code, int nowMs) => copyWith(
    state: SiwcAccountState.needsReauth,
    accessToken: null,
    refreshToken: null,
    expiresAtMs: 0,
    earliestRefreshAtMs: 0,
    needsReauthReason: code,
    savedAtMs: nowMs,
  );

  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'state': state.name,
    'subject': subject,
    'email': email,
    'plan': plan,
    'idToken': idToken,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAtMs': expiresAtMs,
    'earliestRefreshAtMs': earliestRefreshAtMs,
    'scopes': scopes,
    'savedAtMs': savedAtMs,
    'createdAtMs': createdAtMs,
    'planUsage': planUsage,
    'needsReauthReason': needsReauthReason,
    'authorizationEpoch': authorizationEpoch,
  };

  static SiwcAccountRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final clientId = json['clientId'];
    final state = SiwcAccountState.fromName(json['state']);
    if (clientId is! String || clientId.isEmpty || state == null) return null;
    String? s(String k) {
      final v = json[k];
      return v is String && v.isNotEmpty ? v : null;
    }

    int i(String k) {
      final v = json[k];
      return v is num ? v.toInt() : 0;
    }

    final scopes = json['scopes'];
    return SiwcAccountRecord(
      clientId: clientId,
      state: state,
      subject: s('subject'),
      email: s('email'),
      plan: s('plan'),
      idToken: s('idToken'),
      accessToken: s('accessToken'),
      refreshToken: s('refreshToken'),
      expiresAtMs: i('expiresAtMs'),
      earliestRefreshAtMs: i('earliestRefreshAtMs'),
      scopes: scopes is List ? scopes.whereType<String>().toList() : const [],
      savedAtMs: i('savedAtMs'),
      createdAtMs: i('createdAtMs'),
      planUsage: json['planUsage'] == true,
      needsReauthReason: s('needsReauthReason'),
      authorizationEpoch: i('authorizationEpoch'),
    );
  }

  @override
  String toString() =>
      'SiwcAccountRecord(${state.name}, key=$accountKey, planUsage=$planUsage)';
}

/// 저장 파일 한 벌 — host id + 계정.
class SiwcStoreData {
  const SiwcStoreData({this.hostId, this.account});

  /// `urn:uuid:<v4>` — 기기(host)마다 1회, 로그아웃해도 유지.
  final String? hostId;
  final SiwcAccountRecord? account;

  static const schema = 1;

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'hostId': hostId,
    'account': account?.toJson(),
  };

  static SiwcStoreData fromJson(Object? json) {
    if (json is! Map || json['schema'] != schema) return const SiwcStoreData();
    final host = json['hostId'];
    return SiwcStoreData(
      hostId: host is String && host.isNotEmpty ? host : null,
      account: SiwcAccountRecord.fromJson(json['account']),
    );
  }
}
