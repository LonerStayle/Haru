import 'ai_route.dart';

enum AiReadyState { off, loading, needsSignIn, paused, ready }

/// AI 기능 버튼을 보일지의 단일 판정 — [aiReadinessProvider].
class AiReadiness {
  const AiReadiness({
    required this.route,
    required this.state,
    this.accountLabel,
    this.pausedUntil,
    this.keyRejected = false,
  });

  const AiReadiness.off() : this(route: AiRoute.off, state: AiReadyState.off);

  const AiReadiness.ready(
    AiRoute route, {
    String? accountLabel,
    bool keyRejected = false,
  }) : this(
         route: route,
         state: AiReadyState.ready,
         accountLabel: accountLabel,
         keyRejected: keyRejected,
       );

  final AiRoute route;
  final AiReadyState state;
  final String? accountLabel;
  final DateTime? pausedUntil;

  /// 저장된 API 키가 마지막 호출에서 거부됨 (401) — 준비 상태는 유지하되 안내를 바꾼다.
  final bool keyRejected;

  bool get isReady => state == AiReadyState.ready;

  /// 기능 버튼을 보일지 — 꺼져 있으면 숨기고, 로그인 풀림·한도는 보이되 누르면 안내.
  bool get showsFeatures => route != AiRoute.off;

  /// 호출 실패 시 행 안에 띄울 안내.
  String get failureHint => switch (state) {
    AiReadyState.paused when pausedUntil != null =>
      '한도에 걸렸어요 · ${_hm(pausedUntil!)} 이후 다시',
    AiReadyState.needsSignIn when route == AiRoute.claudeApi =>
      'API 키가 필요해요 · 설정에서 입력',
    AiReadyState.needsSignIn => '로그인이 풀렸어요 · 설정에서 확인',
    AiReadyState.ready when keyRejected => 'API 키가 거부됐어요 · 설정에서 확인',
    _ => 'AI 응답을 받지 못했어요 · 설정에서 확인',
  };

  static String _hm(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
  }
}
