/// ChatGPT 플랜 로그인(Sign in with ChatGPT, SIWC) 상수.
///
/// 값은 Andy `SiwcConfig.kt` 에서 옮겼다 (사양서 A.1). 바꾸면 실계정 재점검이 필요하다.
abstract final class SiwcConfig {
  static const issuer = 'https://auth.openai.com';
  static const authorizeUrl = 'https://auth.openai.com/api/accounts/authorize';
  static const tokenUrl = 'https://auth.openai.com/api/accounts/oauth/token';
  static const revokeUrl = 'https://auth.openai.com/api/accounts/oauth/revoke';

  /// authorize·교환·갱신 모두 `resource` 로 보낸다.
  static const resource = 'https://api.openai.com/v1';
  static const apiBase = 'https://api.openai.com/v1';
  static const responsesUrl = '$apiBase/responses';
  static const modelsUrl = '$apiBase/models';

  static const scope =
      'openid profile email offline_access resource.invoke '
      'chatgpt.tokens.use.direct';

  /// 토큰 응답 scope 에 이게 없으면 로그인은 유지하되 추론은 하지 않는다.
  static const planScope = 'chatgpt.tokens.use.direct';

  /// 첫 등록 진입점. 저장·교환에는 쓰지 않는다.
  static const dynamicClient = 'dynamic_agent_client';

  /// 등록 앱 이름 — 한 번 정하면 모든 설치에서 같은 값을 써야 한다.
  static const agentName = 'Haru';

  /// `localhost` 금지 — 등록된 redirect 와 바이트까지 같아야 한다.
  static const callbackHost = '127.0.0.1';
  static const callbackPath = '/auth/callback';
  static const preferredPort = 1455;

  static const loginTimeout = Duration(minutes: 10);
  static const callbackResponseTimeout = Duration(seconds: 30);
  static const refreshMargin = Duration(minutes: 5);
  static const refreshRetryBackoff = Duration(seconds: 30);
  static const idTokenLeewaySeconds = 60;
  static const defaultExpiresInSeconds = 3600;

  /// 한도 일시 중지 뒤 다시 시도해 볼 간격 (리셋 시각이 아니다).
  static const usagePause = Duration(minutes: 30);
  static const revokeBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  /// 갱신 뒤에도 같은 이유로 연속 거절되면 재로그인을 요구하는 횟수.
  static const unauthorizedAfterRefreshLimit = 2;

  static const usageUrl = 'https://chatgpt.com/settings/usage';

  /// 갱신 응답이 이 code 면 refresh 계열이 죽었다 → 토큰 삭제 + 재로그인.
  static const terminalRefreshCodes = {
    'invalid_grant',
    'invalid_refresh_token',
    'token_expired',
    'refresh_token_expired',
    'refresh_token_invalidated',
    'refresh_token_reused',
  };
  static const invalidClient = 'invalid_client';

  /// 보조 호출 기본 모델 (Andy aux, 카탈로그 밖이지만 호출 확인됨 — 사양서 A.17).
  static const defaultModel = 'gpt-6-luna';
  static const modelCacheTtl = Duration(hours: 6);

  static const tokenCallTimeout = Duration(seconds: 30);
  static const responseHeadersTimeout = Duration(seconds: 60);
  static const responseIdleTimeout = Duration(seconds: 120);
}
