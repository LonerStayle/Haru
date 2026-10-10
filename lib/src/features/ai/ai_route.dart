/// 앱 안 AI 기능이 쓸 경로 — 설정 > AI > 사용할 AI.
///
/// 하나만 켠다. 기본은 [off] — 고르기 전엔 AI 버튼이 어디에도 보이지 않는다.
enum AiRoute {
  off,
  chatgptPlan,

  /// Anthropic API 키. 저장값은 예전 'Claude 플랜' 슬롯과 같은 'claude' (설정 호환).
  claudeApi;

  String get storageValue => switch (this) {
    off => 'off',
    chatgptPlan => 'chatgpt',
    claudeApi => 'claude',
  };

  static AiRoute fromStorage(String? raw) => switch (raw) {
    'chatgpt' => chatgptPlan,
    'claude' => claudeApi,
    _ => off,
  };

  /// 설정 세그먼트 라벨. 폰은 폭이 좁아 짧게.
  String label({required bool compact}) => switch (this) {
    off => '끔',
    chatgptPlan => compact ? 'ChatGPT' : 'ChatGPT 플랜',
    claudeApi => compact ? 'Claude' : 'Claude API',
  };
}
