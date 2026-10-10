import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'chatgpt_errors.dart';
import 'siwc_account.dart';
import 'siwc_config.dart';
import 'siwc_store.dart';
import 'siwc_token_endpoint.dart';

/// 요청에 실을 자격 한 벌. ⚠️ [bearer] 로그 금지.
class SiwcCredential {
  const SiwcCredential(this.bearer, this.accountKey);

  final String bearer;
  final String? accountKey;

  @override
  String toString() => 'SiwcCredential(key=$accountKey)';
}

/// 토큰 공급·선갱신·401 갱신·로그아웃 (사양서 A.11·A.12).
///
/// - 갱신은 **single-flight**: 진행 중인 갱신이 있으면 같은 Future 를 함께 기다린다.
///   Dart Future 는 호출자가 떠나도 끝까지 돌아 회전된 refresh 를 저장한다
///   (버리면 다음 갱신이 `refresh_token_reused` → 계열 무효화).
/// - 저장은 메모리 먼저, 디스크는 그다음. 디스크 쓰기가 실패해도 메모리 값은 유지한다.
class SiwcCredentials {
  SiwcCredentials({
    required SiwcStore store,
    required SiwcTokenEndpoint endpoint,
    required int Function() nowMs,
    Future<void> Function(Duration)? sleep,
    this.onChanged,
  }) : _store = store,
       _endpoint = endpoint,
       _nowMs = nowMs,
       _sleep = sleep ?? Future<void>.delayed;

  final SiwcStore _store;
  final SiwcTokenEndpoint _endpoint;
  final int Function() _nowMs;
  final Future<void> Function(Duration) _sleep;

  /// 계정 기록이 바뀔 때마다 (상태 스트림 갱신용).
  void Function()? onChanged;

  SiwcStoreData? _data;
  Future<SiwcStoreData>? _loading;
  Future<SiwcAccountRecord>? _inflight;
  int _refreshBackoffUntilMs = 0;
  String? _lastRejectCode;
  int _rejectCount = 0;

  SiwcAccountRecord? get account => _data?.account;

  Future<SiwcStoreData> load() async {
    final data = _data;
    if (data != null) return data;
    return _loading ??= _store.read().then((d) => _data = d);
  }

  /// host id — 없으면 만들어 저장한다. 저장 실패면 null (authorize URL 을 만들지 않는다).
  Future<String?> ensureHostId() async {
    final data = await load();
    final existing = data.hostId;
    if (existing != null) return existing;
    final next = SiwcStoreData(
      hostId: 'urn:uuid:${const Uuid().v4()}',
      account: data.account,
    );
    _data = next;
    return await _persist() ? next.hostId : null;
  }

  /// 계정 기록 교체 (로그인 결과 저장). 디스크까지 성공했는지 돌려준다.
  Future<bool> setAccount(SiwcAccountRecord? record) async {
    final data = await load();
    _data = SiwcStoreData(hostId: data.hostId, account: record);
    onChanged?.call();
    return _persist();
  }

  Future<bool> _persist() async {
    final data = _data;
    if (data == null) return false;
    try {
      await _store.write(data);
      return true;
    } catch (_) {
      debugPrint('[haru.ai] STORE write_failed (kept in memory)');
      return false;
    }
  }

  /// 지금 쓸 자격. 필요하면 선갱신한다. 실패는 [ChatGptException].
  Future<SiwcCredential> current() async {
    await load();
    final rec = _ensureUsable(account);
    final now = _nowMs();
    final accessValid = rec.accessToken != null && now < rec.expiresAtMs;
    if (!TokenTiming.needsRefresh(
      accessToken: rec.accessToken,
      expiresAtMs: rec.expiresAtMs,
      earliestRefreshAtMs: rec.earliestRefreshAtMs,
      nowMs: now,
    )) {
      return _credOf(rec);
    }
    if (accessValid && now < _refreshBackoffUntilMs) return _credOf(rec);
    if (rec.refreshToken == null) {
      if (accessValid) return _credOf(rec);
      throw await _markNeedsReauth(SiwcReauthReason.missingRefreshToken);
    }
    try {
      return _credOf(await _refreshShared());
    } on ChatGptException catch (e) {
      // 선갱신이 비-terminal 로 실패해도 access 가 아직 유효하면 그대로 쓴다.
      if (e.kind != ChatGptErrorKind.authRequired && accessValid) {
        return _credOf(rec);
      }
      rethrow;
    }
  }

  /// 401 을 받은 뒤 1회 강제 갱신. 그새 다른 호출이 갱신했으면 그 값을 쓴다.
  Future<SiwcCredential> refreshAfterUnauthorized(
    SiwcCredential rejected,
  ) async {
    await load();
    final rec = _ensureUsable(account);
    if (rec.accessToken != null && rec.accessToken != rejected.bearer) {
      return _credOf(rec);
    }
    if (rec.refreshToken == null) {
      throw await _markNeedsReauth(SiwcReauthReason.missingRefreshToken);
    }
    return _credOf(await _refreshShared());
  }

  /// 갱신한 토큰이 또 401 — 같은 이유로 연속 [SiwcConfig.unauthorizedAfterRefreshLimit] 회면
  /// 재로그인 요구(토큰은 지우지 않는다).
  Future<void> onRejectedAfterRefresh(String? code) async {
    if (code == _lastRejectCode) {
      _rejectCount++;
    } else {
      _lastRejectCode = code;
      _rejectCount = 1;
    }
    if (_rejectCount >= SiwcConfig.unauthorizedAfterRefreshLimit) {
      _rejectCount = 0;
      await _markNeedsReauth(SiwcReauthReason.unauthorizedAfterRefresh);
    }
  }

  void onSuccess() {
    _lastRejectCode = null;
    _rejectCount = 0;
  }

  Future<SiwcAccountRecord> _refreshShared() {
    final running = _inflight;
    if (running != null) return running;
    final next = _doRefresh();
    _inflight = next;
    void clear() {
      if (identical(_inflight, next)) _inflight = null;
    }

    next.then((_) => clear(), onError: (Object _) => clear());
    return next;
  }

  Future<SiwcAccountRecord> _doRefresh() async {
    final rec = _ensureUsable(account);
    final rt = rec.refreshToken!;
    final result = await _endpoint.refresh(
      clientId: rec.clientId,
      refreshToken: rt,
    );
    final latest = account;
    final now = _nowMs();
    switch (result) {
      case TokenSuccess(:final tokens):
        // 그새 재로그인으로 바뀌었으면 옛 응답을 저장하지 않고 최신 값을 쓴다.
        if (latest == null || latest.refreshToken != rt) {
          return _ensureUsable(latest);
        }
        final scopes = tokens.scopes;
        final updated = latest.copyWith(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken ?? rt,
          idToken: tokens.idToken ?? latest.idToken,
          expiresAtMs: tokens.expiresAtMs,
          earliestRefreshAtMs: tokens.earliestRefreshAtMs,
          scopes: scopes ?? latest.scopes,
          planUsage: scopes == null
              ? latest.planUsage
              : scopes.contains(SiwcConfig.planScope),
          savedAtMs: now,
        );
        _refreshBackoffUntilMs = 0;
        await setAccount(updated);
        debugPrint('[haru.ai] REFRESH ok key=${updated.accountKey}');
        return _ensureUsable(updated);
      case TokenFailure f:
        debugPrint(
          '[haru.ai] REFRESH failed kind=${f.kind.name} '
          'status=${f.status} code=${f.code}',
        );
        if (f.isTerminal) {
          if (latest != null && latest.refreshToken == rt) {
            await setAccount(latest.needsReauthTerminal(f.code!, now));
          }
          throw authRequired(ChatGptAuthReason.needsReauth, code: f.code);
        }
        if (f.isInvalidClient) {
          throw await _markNeedsReauth(SiwcReauthReason.invalidClient);
        }
        _refreshBackoffUntilMs =
            now + SiwcConfig.refreshRetryBackoff.inMilliseconds;
        throw switch (f.kind) {
          TokenFailureKind.network => networkError,
          TokenFailureKind.server => ChatGptException(
            ChatGptErrorKind.server,
            'ChatGPT 서버가 응답하지 않아요.',
            retryable: true,
            status: f.status,
          ),
          _ => ChatGptException(
            ChatGptErrorKind.refreshDeferred,
            'ChatGPT 연결을 잠시 확인하지 못했어요.',
            status: f.status,
            code: f.code,
          ),
        };
    }
  }

  Future<ChatGptException> _markNeedsReauth(String reason) async {
    await load();
    final rec = account;
    if (rec != null) {
      await setAccount(
        rec.copyWith(
          state: SiwcAccountState.needsReauth,
          needsReauthReason: reason,
          savedAtMs: _nowMs(),
        ),
      );
    }
    return authRequired(ChatGptAuthReason.needsReauth, code: reason);
  }

  /// 로그아웃 (사양서 A.12). 원격 해제를 확인했는지 돌려준다.
  Future<bool> signOut() async {
    await load();
    final rec = account;
    if (rec == null) return true;
    if (rec.state == SiwcAccountState.pendingRegistration) {
      await setAccount(null);
      return true;
    }
    if (rec.state == SiwcAccountState.signedOut) return true;

    await setAccount(
      rec.copyWith(
        state: SiwcAccountState.signingOut,
        authorizationEpoch: rec.authorizationEpoch + 1,
        savedAtMs: _nowMs(),
      ),
    );
    // 진행 중인 갱신이 끝나야 최신 refresh 로 revoke 할 수 있다.
    final running = _inflight;
    if (running != null) {
      try {
        await running;
      } catch (_) {}
    }
    final rt = account?.refreshToken;
    var confirmed = true;
    if (rt != null) {
      var result = await _endpoint.revoke(
        clientId: rec.clientId,
        refreshToken: rt,
      );
      for (final wait in SiwcConfig.revokeBackoff) {
        if (result != RevokeResult.retryable) break;
        await _sleep(wait);
        result = await _endpoint.revoke(
          clientId: rec.clientId,
          refreshToken: rt,
        );
      }
      confirmed = result == RevokeResult.ok;
      debugPrint('[haru.ai] REVOKE result=${result.name}');
    }
    final latest = account;
    if (latest != null &&
        latest.state == SiwcAccountState.signingOut &&
        latest.refreshToken == rt) {
      await setAccount(latest.signedOut(_nowMs()));
    }
    _refreshBackoffUntilMs = 0;
    return confirmed;
  }

  SiwcCredential _credOf(SiwcAccountRecord rec) =>
      SiwcCredential(rec.accessToken!, rec.accountKey);

  SiwcAccountRecord _ensureUsable(SiwcAccountRecord? rec) {
    if (rec == null) throw authRequired(ChatGptAuthReason.signedOut);
    switch (rec.state) {
      case SiwcAccountState.signingOut:
        throw authRequired(ChatGptAuthReason.signingOut);
      case SiwcAccountState.signedOut:
      case SiwcAccountState.pendingRegistration:
        throw authRequired(ChatGptAuthReason.signedOut);
      case SiwcAccountState.needsReauth:
        throw authRequired(
          ChatGptAuthReason.needsReauth,
          code: rec.needsReauthReason,
        );
      case SiwcAccountState.signedIn:
        if (!rec.planUsage) {
          throw authRequired(ChatGptAuthReason.planScopeMissing);
        }
        if (rec.accessToken == null && rec.refreshToken == null) {
          throw authRequired(ChatGptAuthReason.needsReauth);
        }
        return rec;
    }
  }
}
