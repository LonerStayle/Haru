/// Anthropic Messages API 상수 — Dart 공식 SDK 가 없어 raw HTTP 로 부른다.
abstract final class ClaudeConfig {
  static const messagesUrl = 'https://api.anthropic.com/v1/messages';
  static const modelsUrl = 'https://api.anthropic.com/v1/models';

  static const apiVersion = '2023-06-01';

  /// 서버 쪽 거절 대체(`fallbacks: 'default'`) 를 켜는 beta.
  static const fallbackBeta = 'server-side-fallback-2026-07-01';

  /// 고정 모델 — 날짜 접미사를 붙이지 않는다.
  static const model = 'claude-opus-5-5';

  /// 키 형식 안내·검사용 접두사.
  static const keyPrefix = 'sk-ant-';

  static const jsonMaxTokens = 16000;
  static const streamMaxTokens = 64000;

  /// 단발 JSON 한 번의 시도(머리+본문) 한도. 넘기면 그 요청을 끊고 재시도 규칙대로.
  static const jsonAttemptTimeout = Duration(seconds: _jsonAttemptSeconds);
  static const _jsonAttemptSeconds = 90;

  /// 단발 JSON 전체 한도 — 모든 시도 + 재시도 대기 합보다 길게 둬서, 바깥 한도가
  /// 재시도를 잘라 먹지 않게 한다 (안전망일 뿐, 보통은 시도별 한도가 먼저 끝낸다).
  static const jsonTotalTimeout = Duration(
    seconds: _jsonAttemptSeconds * (maxRetries + 1) + _maxTotalWaitSeconds + 5,
  );

  /// 응답 머리(상태 코드)를 기다리는 시간.
  static const headersTimeout = Duration(seconds: 60);

  /// 스트림 이벤트 사이 최대 공백 (ping 이 주기적으로 온다).
  static const streamIdleTimeout = Duration(seconds: 90);

  /// 키 확인(GET /v1/models).
  static const verifyTimeout = Duration(seconds: 20);

  /// 429 에 retry-after 가 없을 때 쉬는 시간.
  static const defaultPause = Duration(seconds: 60);

  static const maxRetries = 2;
  static const maxTotalWait = Duration(seconds: _maxTotalWaitSeconds);
  static const _maxTotalWaitSeconds = 15;
}
