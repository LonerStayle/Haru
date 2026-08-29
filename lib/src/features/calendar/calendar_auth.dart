import 'package:http/http.dart' as http;

/// 플랫폼·서비스 중립 캘린더 인증 추상화.
///
/// 구현체는 셋이다:
/// - `MobileCalendarAuth` — Android 의 Google 인증 (google_sign_in / Credential Manager)
/// - `DesktopCalendarAuth` — macOS 의 Google 인증 (googleapis_auth 데스크톱 플로우)
/// - `MicrosoftCalendarAuth` — Microsoft 365 인증 (순수 Dart OAuth2 + PKCE, 양 플랫폼 공통)
///
/// 게이트웨이는 이 인터페이스만 알고, 어느 서비스의 어느 플랫폼인지는 신경 쓰지 않는다.
abstract class CalendarAuth {
  /// API 호출용 인증된 [http.Client]. 사용자가 동의를 거부/취소하면 null.
  /// 호출자가 사용 후 반드시 close() 한다.
  Future<http.Client?> authedClient();

  Future<void> signOut();
}

/// 고정 헤더만 주입하는 얇은 [http.Client].
///
/// google_sign_in 의 인가 헤더와 Microsoft 의 bearer 토큰이 같은 모양을 필요로 해
/// 한 곳에 둔다.
class HeaderClient extends http.BaseClient {
  HeaderClient(this._headers, {http.Client? inner})
    : _inner = inner ?? http.Client();

  final Map<String, String> _headers;
  final http.Client _inner;

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

/// 저장된 토큰의 scope 목록([storedScopes])이 현재 필요한 [requiredScopes] 를
/// 전부 포함하는지 판정하는 순수 함수.
///
/// 왜 이런 대조가 필요한가 — OAuth2 refresh grant 는 서버에 scope 부족을 알려주지
/// 않는다. 부족한 scope 로 발급된 옛 refresh token 으로 갱신을 걸면 서버는 실패시키지
/// 않고 **원래 발급받았던 scope 로만 유효한** access token 을 조용히 돌려준다. 그래서
/// 앱이 저장해 둔 scope 목록을 직접 대조해 재동의 필요 여부를 스스로 판단해야 한다.
///
/// [storedScopes] 가 null 이면(파일 없음/파싱 실패/`scopes` 키 없는 구버전 토큰)
/// 무조건 false — "옛 scope 로 발급된 토큰" 으로 간주해 재동의로 보낸다.
bool scopesCoverRequired(
  List<String>? storedScopes,
  List<String> requiredScopes,
) {
  if (storedScopes == null) return false;
  return requiredScopes.every(storedScopes.contains);
}
