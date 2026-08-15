import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/auth_io.dart' as gauth;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/env.dart';
import '../../core/platform.dart';

/// Calendar 이벤트 CRUD 에 필요한 scope (읽기/쓰기 포함).
const calendarEventsScope = 'https://www.googleapis.com/auth/calendar.events';

/// 사용자의 캘린더 목록(어느 캘린더들이 있는지)을 읽기 전용으로 조회하는 scope.
/// 설정 화면에서 "할 일을 등록할 캘린더" / "가져올 캘린더" 를 대표님이 직접 고르게
/// 하려면 목록 조회가 필요하다. 전체 `calendar` scope 는 권한이 과해서 목록
/// 읽기 전용인 이 scope 만 더한다.
const calendarListScope =
    'https://www.googleapis.com/auth/calendar.calendarlist.readonly';

const _scopes = [calendarEventsScope, calendarListScope];

/// 테스트 전용 노출. `_scopes` 는 파일 프라이빗이라 외부 테스트에서 "두 scope 를
/// 모두 포함하는지" 를 직접 검증할 수 없어 얇은 public alias 를 둔다.
@visibleForTesting
const calendarScopes = _scopes;

/// 저장된 토큰의 scope 목록([storedScopes])이 현재 필요한 [requiredScopes] 를
/// 전부 포함하는지 판정하는 순수 함수. [DesktopCalendarAuth] 가 "저장된 refresh
/// token 을 재사용해도 되는지" 를 판단할 때 쓴다.
///
/// 왜 이런 대조가 필요한가 — OAuth2 refresh grant 는 서버에 scope 파라미터를
/// 보내지 않는다 (`googleapis_auth` 의 `refreshCredentials` 실제 구현이 그렇다:
/// 요청 body 는 client_id/client_secret/refresh_token/grant_type 뿐이다). 그
/// 결과 scope 가 부족한 옛 토큰으로 refresh 를 걸어도 서버는 실패시키지 않고,
/// **원래 발급받았던(과거) scope 로만 유효한** access token 을 조용히 돌려준다.
/// refresh 응답 자체는 scope 부족을 알려주지 않으므로, 앱이 저장해 둔 scope
/// 목록을 직접 대조해서 재동의가 필요한지 스스로 판단해야 한다. 이 함수 하나로
/// 판단하게 해두면, 앞으로 scope 를 더 늘릴 때도(예: 캘린더 쓰기 확대) 코드
/// 변경 없이 동일하게 동작한다.
///
/// [storedScopes] 가 null 이면(파일 없음/파싱 실패/`scopes` 키 없는 구버전
/// 토큰) 무조건 false — "옛 scope 로 발급된 토큰"으로 간주해 재동의로 보낸다.
///
// ⚠️ RISK(breaking): 토큰 파일 포맷이 `{refresh_token}` → `{refresh_token, scopes}`
// 로 바뀌었다. 기존 macOS 사용자의 토큰에는 `scopes` 키가 없으므로 이 판정에서
// 전부 false 가 되어 브라우저 재동의가 1회 강제된다 (scope 확대에 따른 의도된
// 동작). 되돌리려면 토큰 파일도 함께 고려해야 한다 — 코드만 롤백하면 새 포맷
// 파일을 옛 코드가 읽어 scopes 를 무시하고 부족한 권한으로 조용히 진행한다.
@visibleForTesting
bool storedScopesCoverRequired(
  List<String>? storedScopes,
  List<String> requiredScopes,
) {
  if (storedScopes == null) return false;
  return requiredScopes.every(storedScopes.contains);
}

/// 토큰 파일 원본 JSON 문자열을 (refreshToken, scopes) 로 파싱하는 순수 함수.
/// 파일 I/O 를 분리해 두어 "JSON 이 깨져 있어도 예외 없이 null" 동작을 파일
/// 시스템 없이 단위 테스트할 수 있다. 파싱 실패/refresh_token 누락 시 예외를
/// 던지지 않고 null 을 돌려주며, 호출자는 null 을 "재동의가 필요한 상태" 로
/// 취급한다.
@visibleForTesting
({String refreshToken, List<String>? scopes})? parseStoredToken(String raw) {
  try {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final rt = map['refresh_token'] as String?;
    if (rt == null || rt.isEmpty) return null;
    final scopesRaw = map['scopes'];
    final scopes = scopesRaw is List
        ? scopesRaw.map((e) => e.toString()).toList()
        : null;
    return (refreshToken: rt, scopes: scopes);
  } catch (_) {
    return null;
  }
}

/// 플랫폼 중립 Calendar 인증 추상화.
///
/// macOS desktop 과 Android 는 OAuth 방식이 **근본적으로 다르다**:
/// - **Android** → [MobileCalendarAuth]: google_sign_in (Credential Manager).
///   패키지명 + SHA-1 로 Google Cloud Console 에서 자동 매칭.
/// - **macOS** → [DesktopCalendarAuth]: google_sign_in 의 GIDSignIn 은 토큰을
///   키체인에 저장하는데, 키체인 액세스 그룹 접근에는 유효한 app-identifier 서명
///   (= Apple 개발팀) 이 필요하다. ad-hoc 서명(로컬 개발) 에선 "keychain error" 로
///   실패한다. 그래서 macOS 는 googleapis_auth 의 **데스크톱 OAuth 플로우**
///   (브라우저 동의 → localhost 리다이렉트 → refresh token 로컬 저장) 로 우회한다.
///   키체인·Apple 서명이 일절 필요 없다.
abstract class CalendarAuth {
  /// Calendar API 호출용 인증된 [http.Client]. 사용자가 동의를 거부/취소하면 null.
  /// 호출자가 사용 후 반드시 close() 한다.
  Future<http.Client?> authedClient();

  Future<void> signOut();
}

// ---------------------------------------------------------------------------
// Android — google_sign_in (Credential Manager) 기반
// ---------------------------------------------------------------------------

/// 헤더만 주입하는 얇은 http.Client (google_sign_in 인가 헤더용).
class _HeaderClient extends http.BaseClient {
  _HeaderClient(this._headers);

  final Map<String, String> _headers;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

class MobileCalendarAuth implements CalendarAuth {
  MobileCalendarAuth(this._clientId);

  /// Android 활성화 게이트용. 실제 매칭은 SHA-1 + 패키지명으로 이뤄지므로 값 자체는
  /// initialize 에 넘기지 않는다 (google_sign_in 7.x Credential Manager 규칙).
  // ignore: unused_field
  final String _clientId;

  bool _initialized = false;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    // Android 7.x 는 serverClientId(웹 클라이언트 ID) 필수. 미설정이면 명확한 에러로
    // 안내되도록 그대로 넘긴다 (빈 문자열 → null).
    final serverClientId = Env.googleOAuthServerClientId;
    await GoogleSignIn.instance.initialize(
      serverClientId: serverClientId.isEmpty ? null : serverClientId,
    );
    _initialized = true;
  }

  Future<GoogleSignInAccount?> _tryRestore() async {
    try {
      return await GoogleSignIn.instance.attemptLightweightAuthentication();
    } catch (e) {
      debugPrint('[solo_todo] Google 세션 복원 실패: $e');
      return null;
    }
  }

  @override
  Future<http.Client?> authedClient() async {
    await _ensureInit();
    final account =
        await _tryRestore() ??
        await GoogleSignIn.instance.authenticate(scopeHint: _scopes);
    final client = account.authorizationClient;
    // calendar scope 미부여 시 증분 동의 프롬프트. 거부 시 throw.
    final existing = await client.authorizationForScopes(_scopes);
    if (existing == null) {
      await client.authorizeScopes(_scopes);
    }
    final headers = await client.authorizationHeaders(_scopes);
    if (headers == null) return null;
    return _HeaderClient(headers);
  }

  @override
  Future<void> signOut() async {
    try {
      await _ensureInit();
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      debugPrint('[solo_todo] Google signOut 실패: $e');
    }
  }
}

// ---------------------------------------------------------------------------
// macOS — googleapis_auth 데스크톱 OAuth 플로우 (키체인/서명 불필요)
// ---------------------------------------------------------------------------

class DesktopCalendarAuth implements CalendarAuth {
  DesktopCalendarAuth({required this.clientId, required this.clientSecret});

  /// "Desktop app" 타입 OAuth 클라이언트 (client_secret 동반). localhost 리다이렉트를
  /// Google 이 자동 허용하므로 별도 redirect URI 등록 불필요.
  final String clientId;
  final String clientSecret;

  gauth.ClientId get _id => gauth.ClientId(clientId, clientSecret);

  @override
  Future<http.Client?> authedClient() async {
    // 1) 저장된 refresh token 으로 무프롬프트 갱신 시도 — 단, 저장된 scope 가
    //    현재 필요한 _scopes 를 전부 포함할 때만 (storedScopesCoverRequired
    //    선언부 주석 참고: refresh grant 는 scope 부족을 스스로 알려주지
    //    않으므로 여기서 직접 대조해야 한다). scope 가 부족하면 refresh 를
    //    시도조차 하지 않고 곧장 2) 로 넘어간다 — 어차피 refresh 는 "조용히
    //    성공"해서 부족한 scope 그대로의 토큰을 돌려줄 뿐이라 시도할 이유가
    //    없다.
    final stored = await _loadStoredToken();
    if (stored != null && storedScopesCoverRequired(stored.scopes, _scopes)) {
      try {
        final base = http.Client();
        final stale = gauth.AccessCredentials(
          gauth.AccessToken(
            'Bearer',
            'expired',
            DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          ),
          stored.refreshToken,
          _scopes,
        );
        final fresh = await gauth.refreshCredentials(_id, stale, base);
        return gauth.autoRefreshingClient(_id, fresh, base);
      } catch (e) {
        debugPrint('[solo_todo] Calendar refresh 실패 → 브라우저 재동의로 진행: $e');
        // 토큰이 무효 — 지우고 동의 플로우로.
        await _clearRefreshToken();
      }
    } else if (stored != null) {
      debugPrint('[solo_todo] Calendar 저장 토큰 scope 부족 → 폐기 후 재동의로 진행');
      await _clearRefreshToken();
    }
    // 2) 브라우저 동의 (localhost 임시 서버로 코드 수신).
    try {
      final client = await gauth.clientViaUserConsent(_id, _scopes, _open);
      final rt = client.credentials.refreshToken;
      if (rt != null && rt.isNotEmpty) await _saveRefreshToken(rt, _scopes);
      return client;
    } catch (e) {
      debugPrint('[solo_todo] Calendar OAuth 동의 실패/취소: $e');
      return null;
    }
  }

  /// macOS 기본 브라우저로 동의 URL 열기 (url_launcher 의존 없이 `open`).
  void _open(String url) {
    Process.run('open', [url]);
  }

  @override
  Future<void> signOut() => _clearRefreshToken();

  // --- refresh token 로컬 저장 (키체인 X — 평문 파일, 1인 개인 앱 전제) ---------

  Future<File> _tokenFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'google_calendar_token.json'));
  }

  /// 토큰 파일을 읽어 (refreshToken, scopes) 로 반환. 파일 없음/읽기 실패/파싱
  /// 실패 모두 예외 없이 null — 실제 파싱 규칙은 [parseStoredToken] 참고.
  Future<({String refreshToken, List<String>? scopes})?>
  _loadStoredToken() async {
    try {
      final f = await _tokenFile();
      if (!await f.exists()) return null;
      return parseStoredToken(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// refresh token 과 함께 그 토큰이 발급받은 [scopes] 도 저장한다. 다음 실행
  /// 때 [_loadStoredToken] + [storedScopesCoverRequired] 로 대조해 재동의
  /// 필요 여부를 판단하는 데 쓰인다.
  Future<void> _saveRefreshToken(String token, List<String> scopes) async {
    try {
      final f = await _tokenFile();
      await f.writeAsString(
        jsonEncode({'refresh_token': token, 'scopes': scopes}),
      );
    } catch (e) {
      debugPrint('[solo_todo] refresh token 저장 실패: $e');
    }
  }

  Future<void> _clearRefreshToken() async {
    try {
      final f = await _tokenFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// 현재 플랫폼에 맞는 [CalendarAuth]. 환경변수 미설정 시 null — Calendar 연동 비활성.
final calendarAuthProvider = Provider<CalendarAuth?>((ref) {
  if (AppPlatform.isDesktop) {
    final id = Env.googleOAuthClientIdDesktop;
    final secret = Env.googleOAuthClientSecretDesktop;
    // 데스크톱 플로우는 client id + secret 둘 다 필요.
    if (id.isEmpty || secret.isEmpty) return null;
    return DesktopCalendarAuth(clientId: id, clientSecret: secret);
  }
  final id = Env.googleOAuthClientIdAndroid;
  return id.isEmpty ? null : MobileCalendarAuth(id);
});

/// 사용자에게 Calendar 연결 기능을 노출할지 결정하는 plain bool.
final googleCalendarAvailableProvider = Provider<bool>(
  (ref) => ref.watch(calendarAuthProvider) != null,
);
