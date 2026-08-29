/// 컴파일 타임 환경변수 (`--dart-define-from-file=.env.local`).
///
/// 비어 있을 수 있으니 사용처에서 [isSupabaseConfigured] 등으로 가드하고,
/// 누락된 키가 있을 때는 [missingKeys] / [diagnostics] 로 정확히 어떤 키가 빠졌는지
/// 알려준다.
class Env {
  const Env._();

  // --- raw values ---------------------------------------------------------

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
  );
  static const String googleOAuthClientIdDesktop = String.fromEnvironment(
    'GOOGLE_OAUTH_CLIENT_ID_DESKTOP',
  );

  /// macOS 데스크톱 OAuth 플로우용 client secret ("Desktop app" 타입 클라이언트의 비밀).
  /// googleapis_auth 데스크톱 플로우는 client_secret 을 토큰 교환에 사용한다.
  static const String googleOAuthClientSecretDesktop = String.fromEnvironment(
    'GOOGLE_OAUTH_CLIENT_SECRET_DESKTOP',
  );

  static const String googleOAuthClientIdAndroid = String.fromEnvironment(
    'GOOGLE_OAUTH_CLIENT_ID_ANDROID',
  );

  /// Android google_sign_in 7.x 의 `serverClientId` — "웹 애플리케이션" 타입 OAuth
  /// 클라이언트 ID. Credential Manager 가 토큰 교환에 요구한다 (없으면
  /// "serverClientId must be provided on Android" 로 실패).
  static const String googleOAuthServerClientId = String.fromEnvironment(
    'GOOGLE_OAUTH_SERVER_CLIENT_ID',
  );

  /// Azure 앱 등록의 "애플리케이션(클라이언트) ID" — Microsoft 365(Teams) 캘린더 연동.
  /// 비어 있으면 Microsoft 연동 항목 자체가 설정 화면에서 숨겨진다.
  static const String microsoftOAuthClientId = String.fromEnvironment(
    'MS_OAUTH_CLIENT_ID',
  );

  /// Microsoft 로그인 테넌트. 회사 계정(직장/학교) 전용이므로 기본은
  /// `organizations` 다. 조직 정책이 특정 테넌트만 허용하면 그 GUID 를 넣는다.
  static const String microsoftOAuthTenant = String.fromEnvironment(
    'MS_OAUTH_TENANT',
    defaultValue: 'organizations',
  );

  // --- configured flags ---------------------------------------------------

  /// Supabase 두 키 (URL + anon key) 가 모두 채워졌을 때만 true.
  static bool get isSupabaseConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// Google Calendar 는 desktop / Android 한쪽이라도 채워지면 true
  /// (실제로 두 플랫폼에서 모두 쓰려면 둘 다 필요하지만,
  /// 첫 빌드 단계에서 한쪽만으로도 동작 가능하므로 OR 로 둔다).
  static bool get isGoogleCalendarConfigured =>
      googleOAuthClientIdDesktop.isNotEmpty ||
      googleOAuthClientIdAndroid.isNotEmpty;

  /// Microsoft 365 캘린더 연동이 설정됐는가. 클라이언트 ID 하나면 충분하다 —
  /// PKCE 플로우라 client secret 이 없다.
  static bool get isMicrosoftCalendarConfigured =>
      microsoftOAuthClientId.isNotEmpty;

  // --- diagnostics --------------------------------------------------------

  /// 채워지지 않은 모든 환경변수 키의 목록. 빈 리스트면 모든 의존이 설정됨.
  ///
  /// Supabase 두 키는 둘 다 필요 (개별 누락 모두 보고).
  /// Google OAuth 는 desktop / Android 둘 중 하나라도 있으면 OK 로 보지만,
  /// 둘 다 비어 있으면 둘 다 누락으로 보고.
  ///
  /// Microsoft 키는 **누락으로 보고하지 않는다** — 선택 연동이라 비어 있는 것이
  /// 정상 상태이고, 없으면 설정 화면에서 항목이 조용히 숨겨질 뿐이다.
  static List<String> get missingKeys {
    final missing = <String>[];
    if (supabaseUrl.isEmpty) missing.add('SUPABASE_URL');
    if (supabaseAnonKey.isEmpty) missing.add('SUPABASE_ANON_KEY');
    if (googleOAuthClientIdDesktop.isEmpty &&
        googleOAuthClientIdAndroid.isEmpty) {
      missing.addAll([
        'GOOGLE_OAUTH_CLIENT_ID_DESKTOP',
        'GOOGLE_OAUTH_CLIENT_ID_ANDROID',
      ]);
    }
    return missing;
  }

  /// 사람이 읽을 수 있는 진단 메시지. 모든 의존이 설정되어 있으면 null.
  static String? diagnostics() {
    final missing = missingKeys;
    if (missing.isEmpty) return null;
    final buf = StringBuffer()
      ..writeln(
        '환경변수 ${missing.length}개 누락. `.env.local` 또는 빌드 시 '
        '--dart-define-from-file 로 주입해 주십시오:',
      );
    for (final key in missing) {
      buf.writeln('  - $key');
    }
    buf.writeln('템플릿: ./.env.example 참고');
    return buf.toString().trimRight();
  }
}
