import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/env.dart';
import '../../core/platform.dart';
import 'calendar_auth.dart';

/// Microsoft Graph 캘린더 연동에 필요한 **최소** 권한.
///
/// - `Calendars.ReadWrite` — 일정 조회 + 등록/수정/삭제. 캘린더 목록 조회도 포함된다.
/// - `offline_access` — refresh token. 없으면 매번 브라우저 동의를 다시 받아야 한다.
/// - `User.Read` — 로그인한 계정 확인. 관리자 동의 없이 사용자가 스스로 승인할 수 있다.
///
/// 회의 일정을 대신 만들거나 남의 캘린더를 읽는 권한(`Calendars.ReadWrite.Shared`,
/// `OnlineMeetings.*`)은 **일부러 넣지 않았다** — 조직 정책에서 관리자 동의를
/// 요구하기 쉬운 권한이라, 1인 사용자가 스스로 연결하지 못하게 된다.
const microsoftCalendarScopes = [
  'offline_access',
  'User.Read',
  'Calendars.ReadWrite',
];

/// Microsoft ID 플랫폼 v2.0 엔드포인트.
const _authorityBase = 'https://login.microsoftonline.com';

/// 브라우저 동의를 기다리는 상한. 넘으면 취소로 본다 (창을 닫고 잊어버린 경우).
const _consentTimeout = Duration(minutes: 5);

/// 만료 직전 토큰을 재사용하지 않기 위한 여유. 요청이 날아가는 동안 만료되면
/// 401 이 나고 그게 "재인증 필요" 로 잘못 분류된다.
const _expiryMargin = Duration(seconds: 60);

// ---------------------------------------------------------------------------
// 순수 함수들 — 네트워크·파일 없이 전부 단위 테스트한다.
// ---------------------------------------------------------------------------

/// PKCE `code_verifier` 로 쓸 수 있는 문자 집합 (RFC 7636 의 unreserved).
const _verifierAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

/// 43~128 자 길이의 `code_verifier` 를 만든다. [random] 주입은 테스트용.
@visibleForTesting
String createCodeVerifier({int length = 64, Random? random}) {
  final rnd = random ?? Random.secure();
  return List.generate(
    length,
    (_) => _verifierAlphabet[rnd.nextInt(_verifierAlphabet.length)],
  ).join();
}

/// `code_challenge` = base64url(SHA-256(verifier)), 패딩 없음 (S256 방식).
@visibleForTesting
String codeChallengeS256(String verifier) {
  final digest = sha256.convert(utf8.encode(verifier));
  return base64UrlEncode(digest.bytes).replaceAll('=', '');
}

/// 동의 화면 URL. 값 하나만 틀려도 "redirect 불일치" 로 튕기므로 순수 함수로 떼어
/// 테스트한다.
@visibleForTesting
Uri buildAuthorizeUrl({
  required String tenant,
  required String clientId,
  required String redirectUri,
  required List<String> scopes,
  required String state,
  required String codeChallenge,
}) {
  return Uri.parse('$_authorityBase/$tenant/oauth2/v2.0/authorize').replace(
    queryParameters: {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'response_mode': 'query',
      'scope': scopes.join(' '),
      'state': state,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      // 계정이 여럿인 조직에서 "왜 다른 계정으로 붙었지" 를 막는다.
      'prompt': 'select_account',
    },
  );
}

/// 토큰 엔드포인트 응답에서 뽑아낸 값.
class MicrosoftTokens {
  const MicrosoftTokens({
    required this.accessToken,
    required this.expiresAt,
    this.refreshToken,
    this.scopes = const [],
  });

  final String accessToken;
  final DateTime expiresAt;

  /// 갱신용 토큰. 응답에 없으면 null — 기존 것을 계속 쓴다.
  final String? refreshToken;

  /// 실제로 부여된 scope 목록.
  final List<String> scopes;

  bool isFresh(DateTime now) => expiresAt.isAfter(now.add(_expiryMargin));
}

/// 토큰 응답 JSON 파싱. 파싱 불가/`access_token` 누락이면 null —
/// 호출자가 "재동의 필요" 로 처리한다.
@visibleForTesting
MicrosoftTokens? parseTokenResponse(String body, {DateTime? now}) {
  try {
    final map = jsonDecode(body);
    if (map is! Map) return null;
    final access = map['access_token'];
    if (access is! String || access.isEmpty) return null;
    final expiresIn = map['expires_in'];
    final seconds = expiresIn is int
        ? expiresIn
        : int.tryParse('$expiresIn') ?? 3600;
    final scopeRaw = map['scope'];
    return MicrosoftTokens(
      accessToken: access,
      expiresAt: (now ?? DateTime.now()).add(Duration(seconds: seconds)),
      refreshToken: map['refresh_token'] is String
          ? map['refresh_token'] as String
          : null,
      scopes: scopeRaw is String
          ? scopeRaw.split(' ').where((s) => s.isNotEmpty).toList()
          : const [],
    );
  } catch (_) {
    return null;
  }
}

/// 리다이렉트로 되돌아온 요청에서 인가 코드를 꺼낸다.
///
/// [expectedState] 와 다르면 null — 다른 창에서 온 응답이거나 위조다.
/// 사용자가 동의를 거부하면 `error=access_denied` 로 오는데 이때도 null 이다.
@visibleForTesting
String? extractAuthCode(Uri redirected, String expectedState) {
  final params = redirected.queryParameters;
  if (params['state'] != expectedState) return null;
  final code = params['code'];
  if (code == null || code.isEmpty) return null;
  return code;
}

/// 저장 파일의 JSON → (refreshToken, scopes). 깨져 있으면 예외 없이 null.
@visibleForTesting
({String refreshToken, List<String>? scopes})? parseStoredMicrosoftToken(
  String raw,
) {
  try {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final rt = map['refresh_token'] as String?;
    if (rt == null || rt.isEmpty) return null;
    final scopesRaw = map['scopes'];
    return (
      refreshToken: rt,
      scopes: scopesRaw is List
          ? scopesRaw.map((e) => e.toString()).toList()
          : null,
    );
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 인증 구현
// ---------------------------------------------------------------------------

/// Microsoft 365 (Microsoft Graph) 인증. **macOS 와 Android 가 같은 코드**를 쓴다.
///
/// **왜 MSAL 플러그인을 쓰지 않았나** — 구글 연동에서 겪은 것과 같은 이유다.
/// 네이티브 SDK 는 키체인 액세스 그룹(macOS)과 서명 해시 등록(Android)을 요구해서,
/// 1인 개발자의 로컬 서명 빌드에서 조용히 실패한다. OAuth2 Authorization Code +
/// PKCE 는 client secret 없이 성립하므로 순수 Dart 로 구현할 수 있고, 그러면
/// 플랫폼 분기가 "브라우저를 어떻게 여는가" 한 줄로 줄어든다.
///
/// 리다이렉트는 **양 플랫폼 모두 loopback** (`http://localhost:<임의포트>`) 이다.
/// Azure 는 "모바일 및 데스크톱 애플리케이션" 플랫폼에 등록된 `http://localhost`
/// 를 **포트 무시**로 매칭해 주므로, 등록은 한 줄이면 되고 커스텀 스킴을 위한
/// 매니페스트 편집·딥링크 수신 플러그인이 필요 없다.
class MicrosoftCalendarAuth implements CalendarAuth {
  MicrosoftCalendarAuth({
    required this.clientId,
    required this.tenant,
    List<String>? scopes,
    http.Client Function()? httpClientFactory,
    Future<void> Function(String url)? openUrl,
    DateTime Function()? now,
  }) : scopes = scopes ?? microsoftCalendarScopes,
       _newClient = httpClientFactory ?? http.Client.new,
       _openUrl = openUrl ?? _defaultOpenUrl,
       _now = now ?? DateTime.now;

  /// Azure 앱 등록의 "애플리케이션(클라이언트) ID".
  final String clientId;

  /// 테넌트 — 조직 GUID 또는 `organizations` / `common`.
  /// 회사 계정만 쓸 것이므로 기본은 `organizations` 다.
  final String tenant;

  final List<String> scopes;

  final http.Client Function() _newClient;
  final Future<void> Function(String url) _openUrl;
  final DateTime Function() _now;

  /// 메모리 캐시 — 같은 세션에서 매번 refresh 를 걸지 않기 위함.
  MicrosoftTokens? _cached;

  @override
  Future<http.Client?> authedClient() async {
    final token = await accessToken();
    if (token == null) return null;
    return HeaderClient({'Authorization': 'Bearer $token'});
  }

  /// 유효한 access token. 없으면 refresh → 브라우저 동의 순으로 확보한다.
  /// 사용자가 거부/취소하면 null.
  Future<String?> accessToken() async {
    final cached = _cached;
    if (cached != null && cached.isFresh(_now())) return cached.accessToken;

    final stored = await _loadStoredToken();
    // 저장된 토큰의 scope 가 지금 필요한 것을 다 덮을 때만 refresh 를 시도한다.
    // refresh grant 는 scope 부족을 알려주지 않고 옛 권한 그대로의 토큰을 준다.
    if (stored != null && scopesCoverRequired(stored.scopes, scopes)) {
      final refreshed = await _refresh(stored.refreshToken);
      if (refreshed != null) {
        _remember(refreshed, fallbackRefreshToken: stored.refreshToken);
        return refreshed.accessToken;
      }
      await _clearStoredToken();
    } else if (stored != null) {
      debugPrint('[solo_todo] Microsoft 저장 토큰 scope 부족 → 폐기 후 재동의로 진행');
      await _clearStoredToken();
    }

    final fresh = await _consent();
    if (fresh == null) return null;
    _remember(fresh);
    final rt = fresh.refreshToken;
    if (rt != null && rt.isNotEmpty) await _saveRefreshToken(rt, scopes);
    return fresh.accessToken;
  }

  @override
  Future<void> signOut() async {
    _cached = null;
    await _clearStoredToken();
  }

  void _remember(MicrosoftTokens tokens, {String? fallbackRefreshToken}) {
    _cached = MicrosoftTokens(
      accessToken: tokens.accessToken,
      expiresAt: tokens.expiresAt,
      refreshToken: tokens.refreshToken ?? fallbackRefreshToken,
      scopes: tokens.scopes,
    );
  }

  Uri get _tokenEndpoint =>
      Uri.parse('$_authorityBase/$tenant/oauth2/v2.0/token');

  Future<MicrosoftTokens?> _refresh(String refreshToken) async {
    final client = _newClient();
    try {
      final res = await client.post(
        _tokenEndpoint,
        body: {
          'client_id': clientId,
          'scope': scopes.join(' '),
          'refresh_token': refreshToken,
          'grant_type': 'refresh_token',
        },
      );
      if (res.statusCode != 200) {
        debugPrint('[solo_todo] Microsoft 토큰 갱신 실패 (${res.statusCode})');
        return null;
      }
      final tokens = parseTokenResponse(res.body, now: _now());
      // 새 refresh token 이 왔으면 갈아끼운다 (MS 는 회전시킬 수 있다).
      final rotated = tokens?.refreshToken;
      if (rotated != null && rotated != refreshToken) {
        await _saveRefreshToken(rotated, scopes);
      }
      return tokens;
    } catch (e) {
      debugPrint('[solo_todo] Microsoft 토큰 갱신 오류: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// 브라우저 동의 1회 — loopback 서버를 띄우고 인가 코드를 받아 토큰으로 바꾼다.
  Future<MicrosoftTokens?> _consent() async {
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } catch (e) {
      debugPrint('[solo_todo] Microsoft 로그인용 로컬 포트 열기 실패: $e');
      return null;
    }

    final redirectUri = 'http://localhost:${server.port}';
    final verifier = createCodeVerifier();
    final state = createCodeVerifier(length: 24);
    final url = buildAuthorizeUrl(
      tenant: tenant,
      clientId: clientId,
      redirectUri: redirectUri,
      scopes: scopes,
      state: state,
      codeChallenge: codeChallengeS256(verifier),
    );

    try {
      await _openUrl(url.toString());
      final code = await _awaitCode(server, state);
      if (code == null) return null;
      return _exchangeCode(code, verifier, redirectUri);
    } catch (e) {
      debugPrint('[solo_todo] Microsoft 동의 실패/취소: $e');
      return null;
    } finally {
      await server.close(force: true);
    }
  }

  /// loopback 으로 돌아온 첫 요청에서 인가 코드를 꺼내고, 브라우저에는 안내문을 준다.
  Future<String?> _awaitCode(HttpServer server, String state) async {
    try {
      final request = await server.first.timeout(_consentTimeout);
      final code = extractAuthCode(request.uri, state);
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(
          '<html><head><meta charset="utf-8"><title>하루</title></head>'
          '<body style="font-family:-apple-system,sans-serif;text-align:center;'
          'padding-top:80px">'
          '<h2>${code == null ? '연결이 취소되었습니다.' : '연결되었습니다.'}</h2>'
          '<p>이 창을 닫고 하루 앱으로 돌아가 주세요.</p>'
          '</body></html>',
        );
      await request.response.close();
      return code;
    } on TimeoutException {
      debugPrint('[solo_todo] Microsoft 동의 대기 시간 초과');
      return null;
    }
  }

  Future<MicrosoftTokens?> _exchangeCode(
    String code,
    String verifier,
    String redirectUri,
  ) async {
    final client = _newClient();
    try {
      final res = await client.post(
        _tokenEndpoint,
        body: {
          'client_id': clientId,
          'scope': scopes.join(' '),
          'code': code,
          'redirect_uri': redirectUri,
          'grant_type': 'authorization_code',
          'code_verifier': verifier,
        },
      );
      if (res.statusCode != 200) {
        debugPrint('[solo_todo] Microsoft 코드 교환 실패 (${res.statusCode})');
        return null;
      }
      return parseTokenResponse(res.body, now: _now());
    } finally {
      client.close();
    }
  }

  // --- refresh token 로컬 저장 (구글 데스크톱 플로우와 같은 계층) ---------------

  Future<File> _tokenFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'microsoft_calendar_token.json'));
  }

  Future<({String refreshToken, List<String>? scopes})?>
  _loadStoredToken() async {
    try {
      final f = await _tokenFile();
      if (!await f.exists()) return null;
      return parseStoredMicrosoftToken(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveRefreshToken(String token, List<String> scopes) async {
    try {
      final f = await _tokenFile();
      await f.writeAsString(
        jsonEncode({'refresh_token': token, 'scopes': scopes}),
      );
    } catch (e) {
      debugPrint('[solo_todo] Microsoft refresh token 저장 실패: $e');
    }
  }

  Future<void> _clearStoredToken() async {
    try {
      final f = await _tokenFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// 기본 브라우저 열기 — macOS 는 `open`, Android 는 url_launcher 의 외부 브라우저.
///
/// macOS 에서 url_launcher 를 쓰지 않는 이유는 구글 데스크톱 플로우와 같다:
/// 플러그인 경로가 서명·엔타이틀먼트에 걸릴 여지를 남기지 않는다.
Future<void> _defaultOpenUrl(String url) async {
  if (AppPlatform.isDesktop) {
    await Process.run('open', [url]);
    return;
  }
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// 환경변수가 채워졌을 때만 non-null. 값이 없으면 Microsoft 연동 자체가 숨겨진다.
final microsoftAuthProvider = Provider<CalendarAuth?>((ref) {
  final id = Env.microsoftOAuthClientId;
  if (id.isEmpty) return null;
  return MicrosoftCalendarAuth(clientId: id, tenant: Env.microsoftOAuthTenant);
});

/// 사용자에게 Microsoft 연결 기능을 노출할지.
final microsoftCalendarAvailableProvider = Provider<bool>(
  (ref) => ref.watch(microsoftAuthProvider) != null,
);
