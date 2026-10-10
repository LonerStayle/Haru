import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'loopback_callback_server.dart';
import 'pkce.dart';
import 'siwc_account.dart';
import 'siwc_authorize_url.dart';
import 'siwc_callback_page.dart';
import 'siwc_config.dart';
import 'siwc_credentials.dart';
import 'siwc_id_token.dart';
import 'siwc_token_endpoint.dart';

/// 브라우저 열기. 열었으면 true. ⚠️ url 에 id_token_hint 가 들어갈 수 있다 — 로그 금지.
typedef OpenUrl = Future<bool> Function(String url);

/// 로그인 실패 사유 (사양서 A.7).
enum SiwcLoginFailure {
  denied,
  authorizeError,
  registrationIncomplete,
  clientMismatch,
  missingCode,
  exchangeRejected,
  exchangeFailed,
  network,
  server,
  idTokenInvalid,
  accountMismatch,
  timeout,
  browserUnavailable,
  listenerFailed,
  signingOut,
  storeWriteFailed,
  cancelled,
  internal;

  String get userMessage => switch (this) {
    denied => 'ChatGPT 플랜 사용이 허용되지 않았어요.',
    authorizeError ||
    missingCode ||
    clientMismatch => 'ChatGPT 로그인 응답을 확인하지 못했어요. 다시 시도해 주세요.',
    registrationIncomplete => '하루 등록이 끝나지 않았어요. 다시 시도해 주세요.',
    exchangeRejected => '로그인 요청이 만료됐어요. 다시 시도해 주세요.',
    exchangeFailed || server => 'ChatGPT 서버가 응답하지 않아요. 잠시 후 다시 시도해 주세요.',
    network => '네트워크 연결을 확인해 주세요.',
    idTokenInvalid => '로그인 정보를 확인하지 못했어요. 다시 시도해 주세요.',
    accountMismatch => '전에 연결한 ChatGPT 계정과 달라요. 같은 계정으로 로그인해 주세요.',
    timeout => '로그인 시간이 지났어요. 다시 시도해 주세요.',
    browserUnavailable => '브라우저를 열지 못했어요.',
    listenerFailed => '로그인을 받을 준비를 하지 못했어요. 다시 시도해 주세요.',
    signingOut => '연결을 해제하는 중이에요. 잠시 후 다시 시도해 주세요.',
    storeWriteFailed => '로그인 정보를 저장하지 못했어요.',
    cancelled => '로그인을 취소했어요.',
    internal => '로그인 중 문제가 생겼어요. 다시 시도해 주세요.',
  };
}

class SiwcLoginError implements Exception {
  const SiwcLoginError(this.failure);

  final SiwcLoginFailure failure;

  @override
  String toString() => 'SiwcLoginError(${failure.name})';
}

final _issuedClientPattern = RegExp(r'^[A-Za-z0-9_.\-]{1,200}$');
final _errorCodePattern = RegExp(r'^[a-z_]{1,64}$');

/// 저장 기록으로 시작 모드를 정한다 (사양서 A.3 `startOptionsOf`, 계정 하나 기준).
SiwcLoginMode siwcStartMode(SiwcAccountRecord? rec) {
  if (rec == null) return const SiwcNewAccount();
  if (rec.state == SiwcAccountState.pendingRegistration) {
    return SiwcPendingRetry(rec.clientId);
  }
  if (rec.state == SiwcAccountState.needsReauth &&
      rec.needsReauthReason == SiwcReauthReason.invalidClient) {
    return const SiwcNewAccount();
  }
  if (!rec.planUsage) return SiwcReconsent(rec.clientId);
  return SiwcReauth(rec.clientId);
}

/// 로그인 시도 1회 — loopback 콜백을 받아 교환·검증·저장까지 (사양서 A.7).
class SiwcLoginFlow {
  SiwcLoginFlow({
    required SiwcCredentials credentials,
    required SiwcTokenEndpoint endpoint,
    required OpenUrl openUrl,
    required int Function() nowMs,
    Random? random,
    this.preferredPort = SiwcConfig.preferredPort,
    this.timeout = SiwcConfig.loginTimeout,
    Future<void> Function()? untilForeground,
  }) : _untilForeground = untilForeground,
       _credentials = credentials,
       _endpoint = endpoint,
       _openUrl = openUrl,
       _nowMs = nowMs,
       _random = random;

  /// 앱이 화면 앞으로 돌아올 때까지 기다린다 — Android 는 하루가 브라우저 뒤에 있는 동안
  /// 네트워크를 막아(실기기 로그 `DNS … isBlocked=true`) 토큰 교환이 network 로 실패했다.
  /// 값이 있으면 승인을 받은 즉시 브라우저에 "하루로 돌아가기" 페이지를 보내고, 앱이
  /// 앞으로 오면 그때 교환한다. null(데스크탑)이면 바로 교환한다.
  final Future<void> Function()? _untilForeground;
  final SiwcCredentials _credentials;
  final SiwcTokenEndpoint _endpoint;
  final OpenUrl _openUrl;
  final int Function() _nowMs;
  final Random? _random;
  final int preferredPort;
  final Duration timeout;

  final _cancel = Completer<void>();

  /// 진행 중 시도를 취소한다 (비밀 폐기, 포트 해제).
  void cancel() {
    if (!_cancel.isCompleted) _cancel.complete();
  }

  /// 성공하면 저장한 기록. 실패는 [SiwcLoginError].
  Future<SiwcAccountRecord> run() async {
    final hostId = await _credentials.ensureHostId();
    if (hostId == null) {
      throw const SiwcLoginError(SiwcLoginFailure.storeWriteFailed);
    }
    final rec = _credentials.account;
    if (rec?.state == SiwcAccountState.signingOut) {
      throw const SiwcLoginError(SiwcLoginFailure.signingOut);
    }
    final mode = siwcStartMode(rec);
    final secrets = generateLoginSecrets(_random);
    final server = LoopbackCallbackServer(
      expectedState: secrets.state,
      fallbackPage: () =>
          siwcCallbackPage(SiwcCallbackPageKind.error, code: 'noResponse'),
      preferredPort: preferredPort,
    );
    debugPrint('[haru.ai] LOGIN start mode=${mode.logName}');
    try {
      try {
        await server.start();
      } catch (_) {
        throw const SiwcLoginError(SiwcLoginFailure.listenerFailed);
      }
      final redirectUri = server.redirectUri;
      final url = buildSiwcAuthorizeUrl(
        mode: mode,
        hostId: hostId,
        redirectUri: redirectUri,
        state: secrets.state,
        nonce: secrets.nonce,
        codeChallenge: secrets.challenge,
        idTokenHint: rec?.idToken,
        loginHint: rec?.email,
      );
      bool opened;
      try {
        opened = await _openUrl(url);
      } catch (_) {
        opened = false;
      }
      if (!opened) {
        throw const SiwcLoginError(SiwcLoginFailure.browserUnavailable);
      }

      final CallbackRequest callback;
      try {
        final cancelled = _cancel.future.then<CallbackRequest>(
          (_) => throw const SiwcLoginError(SiwcLoginFailure.cancelled),
        );
        callback = await Future.any([
          server.awaitCallback(),
          cancelled,
        ]).timeout(timeout);
      } on TimeoutException {
        throw const SiwcLoginError(SiwcLoginFailure.timeout);
      }

      final untilForeground = _untilForeground;
      if (untilForeground != null) {
        await callback.respond(
          siwcCallbackPage(SiwcCallbackPageKind.returnToApp),
        );
        debugPrint('[haru.ai] LOGIN waiting_foreground');
        try {
          await Future.any([
            untilForeground(),
            _cancel.future.then<void>(
              (_) => throw const SiwcLoginError(SiwcLoginFailure.cancelled),
            ),
          ]).timeout(timeout);
        } on TimeoutException {
          throw const SiwcLoginError(SiwcLoginFailure.timeout);
        }
      }

      try {
        final saved = await _handleCallback(
          callback.params,
          mode: mode,
          secrets: secrets,
          redirectUri: redirectUri,
        );
        await callback.respond(
          siwcCallbackPage(
            saved.planUsage
                ? SiwcCallbackPageKind.ok
                : SiwcCallbackPageKind.denied,
          ),
        );
        debugPrint(
          '[haru.ai] LOGIN done planUsage=${saved.planUsage} '
          'key=${saved.accountKey}',
        );
        return saved;
      } on SiwcLoginError catch (e) {
        debugPrint('[haru.ai] LOGIN failed reason=${e.failure.name}');
        await callback.respond(
          siwcCallbackPage(
            e.failure == SiwcLoginFailure.denied
                ? SiwcCallbackPageKind.denied
                : SiwcCallbackPageKind.error,
            code: e.failure.name,
          ),
        );
        rethrow;
      } catch (e) {
        // 예상 밖 예외 — 종류만 남긴다(내용엔 응답 본문이 섞일 수 있다).
        debugPrint('[haru.ai] LOGIN internal error=${e.runtimeType}');
        await callback.respond(
          siwcCallbackPage(
            SiwcCallbackPageKind.error,
            code: 'internal ${e.runtimeType}',
          ),
        );
        throw const SiwcLoginError(SiwcLoginFailure.internal);
      }
    } on SiwcLoginError {
      rethrow;
    } catch (e) {
      // 예상 밖 예외 — 종류만 남긴다(내용엔 응답 본문이 섞일 수 있다).
      debugPrint('[haru.ai] LOGIN internal error=${e.runtimeType}');
      throw const SiwcLoginError(SiwcLoginFailure.internal);
    } finally {
      await server.close();
    }
  }

  Future<SiwcAccountRecord> _handleCallback(
    Map<String, String> params, {
    required SiwcLoginMode mode,
    required LoginSecrets secrets,
    required String redirectUri,
  }) async {
    String? nonEmpty(String k) {
      final v = params[k];
      return v == null || v.isEmpty ? null : v;
    }

    final error = nonEmpty('error');
    final callbackClient = nonEmpty('client_id');
    final code = nonEmpty('code');

    final String clientId;
    if (mode is SiwcNewAccount) {
      final issued =
          callbackClient != null &&
              callbackClient != SiwcConfig.dynamicClient &&
              _issuedClientPattern.hasMatch(callbackClient)
          ? callbackClient
          : null;
      if (issued != null) {
        // 교환 전에 등록부터 남긴다 — 교환이 실패해도 다음 시도는 같은 등록으로 (App limits 항목 중복 방지).
        final existing = _credentials.account;
        if (existing == null || existing.clientId != issued) {
          final now = _nowMs();
          await _credentials.setAccount(
            SiwcAccountRecord(
              clientId: issued,
              state: SiwcAccountState.pendingRegistration,
              savedAtMs: now,
              createdAtMs: now,
            ),
          );
        }
      }
      _throwOnAuthorizeError(error);
      if (issued == null) {
        throw const SiwcLoginError(SiwcLoginFailure.registrationIncomplete);
      }
      clientId = issued;
    } else {
      final expected = mode.requestClientId;
      if (callbackClient != null && callbackClient != expected) {
        throw const SiwcLoginError(SiwcLoginFailure.clientMismatch);
      }
      _throwOnAuthorizeError(error);
      clientId = expected;
    }
    if (code == null) throw const SiwcLoginError(SiwcLoginFailure.missingCode);

    final result = await _endpoint.exchangeCode(
      clientId: clientId,
      code: code,
      codeVerifier: secrets.verifier,
      redirectUri: redirectUri,
    );
    final TokenSet tokens;
    switch (result) {
      case TokenSuccess(tokens: final t):
        tokens = t;
      case TokenFailure f:
        debugPrint(
          '[haru.ai] LOGIN exchange_failed kind=${f.kind.name} '
          'status=${f.status} code=${f.code}',
        );
        throw SiwcLoginError(switch (f.kind) {
          TokenFailureKind.client when f.code == 'invalid_grant' =>
            SiwcLoginFailure.exchangeRejected,
          TokenFailureKind.network => SiwcLoginFailure.network,
          TokenFailureKind.server => SiwcLoginFailure.server,
          _ => SiwcLoginFailure.exchangeFailed,
        });
    }

    final idToken = tokens.idToken;
    if (idToken == null) {
      throw const SiwcLoginError(SiwcLoginFailure.idTokenInvalid);
    }
    final IdTokenClaims claims;
    try {
      claims = verifySiwcIdTokenClaims(
        idToken,
        clientId: clientId,
        nonce: secrets.nonce,
        nowMs: _nowMs(),
      );
    } on IdTokenException catch (e) {
      debugPrint('[haru.ai] LOGIN id_token_invalid reason=${e.reason}');
      throw const SiwcLoginError(SiwcLoginFailure.idTokenInvalid);
    }

    // 저장 직전에 다시 확인 — 같은 등록인데 다른 계정이면 덮어쓰지 않는다.
    final latest = _credentials.account;
    final sameClient = latest != null && latest.clientId == clientId;
    if (sameClient &&
        latest.subject != null &&
        latest.subject != claims.subject) {
      throw const SiwcLoginError(SiwcLoginFailure.accountMismatch);
    }

    final scopes = tokens.scopes ?? const <String>[];
    final now = _nowMs();
    final record = SiwcAccountRecord(
      clientId: clientId,
      state: SiwcAccountState.signedIn,
      subject: claims.subject,
      email: claims.email ?? (sameClient ? latest.email : null),
      plan: claims.planType ?? (sameClient ? latest.plan : null),
      idToken: idToken,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      expiresAtMs: tokens.expiresAtMs,
      earliestRefreshAtMs: tokens.earliestRefreshAtMs,
      scopes: scopes,
      savedAtMs: now,
      createdAtMs: sameClient && latest.createdAtMs > 0
          ? latest.createdAtMs
          : now,
      planUsage: scopes.contains(SiwcConfig.planScope),
      authorizationEpoch: (latest?.authorizationEpoch ?? 0) + 1,
    );
    await _credentials.setAccount(record);
    return record;
  }

  void _throwOnAuthorizeError(String? error) {
    if (error == null) return;
    if (error == 'access_denied') {
      throw const SiwcLoginError(SiwcLoginFailure.denied);
    }
    final safe = _errorCodePattern.hasMatch(error) ? error : 'other';
    debugPrint('[haru.ai] LOGIN authorize_error code=$safe');
    throw const SiwcLoginError(SiwcLoginFailure.authorizeError);
  }
}
