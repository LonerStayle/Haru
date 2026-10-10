import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/app_preferences.dart';
import 'ai_backend.dart';
import 'ai_gateway.dart';
import 'ai_readiness.dart';
import 'ai_route.dart';
import 'chatgpt/chatgpt_plan_backend.dart';
import 'claude/claude_api_backend.dart';

/// 설정 > AI > 사용할 AI. 기기별 설정.
class AiRouteNotifier extends SinglePrefNotifier<AiRoute> {
  static const key = 'ai.route';

  @override
  String get storageKey => key;

  @override
  AiRoute get fallback => AiRoute.off;

  @override
  AiRoute decode(String? raw) => AiRoute.fromStorage(raw);

  @override
  String encode(AiRoute value) => value.storageValue;
}

final aiRouteProvider = NotifierProvider<AiRouteNotifier, AiRoute>(
  AiRouteNotifier.new,
);

/// 여러 항목을 한 번에 보내는 기능(정리 제안·물어보기)에 설명 앞 300자를 함께 보낼지.
/// 항목 하나를 골라 부르는 기능(목록으로·다음 한 걸음)은 그 항목 설명을 항상 보낸다.
class AiSendDescriptionNotifier extends SinglePrefNotifier<bool> {
  @override
  String get storageKey => 'ai.sendDescription';

  @override
  bool get fallback => true;

  @override
  bool decode(String? raw) => raw != 'false';

  @override
  String encode(bool value) => value ? 'true' : 'false';
}

final aiSendDescriptionProvider =
    NotifierProvider<AiSendDescriptionNotifier, bool>(
      AiSendDescriptionNotifier.new,
    );

/// 경로별 백엔드.
final aiBackendProvider = Provider.family<AiBackend, AiRoute>(
  (ref, route) => switch (route) {
    AiRoute.chatgptPlan => ref.watch(chatGptPlanBackendProvider),
    AiRoute.claudeApi => ref.watch(claudeApiBackendProvider),
    AiRoute.off => NotConnectedAiBackend(route),
  },
);

final aiAccountStatusProvider = StreamProvider.family<AiAccountStatus, AiRoute>(
  (ref, route) => ref.watch(aiBackendProvider(route)).watchStatus(),
);

/// AI 기능 버튼 노출·호출 가능 여부의 단일 판정.
final aiReadinessProvider = Provider<AiReadiness>((ref) {
  final route = ref.watch(aiRouteProvider);
  if (route == AiRoute.off) return const AiReadiness.off();
  final status = ref.watch(aiAccountStatusProvider(route)).value;
  return switch (status) {
    null => AiReadiness(route: route, state: AiReadyState.loading),
    AiSignedOut() => AiReadiness(route: route, state: AiReadyState.needsSignIn),
    AiSignedIn(:final label, :final rejected) => AiReadiness.ready(
      route,
      accountLabel: label,
      keyRejected: rejected,
    ),
    AiPaused(:final label, :final until) => AiReadiness(
      route: route,
      state: AiReadyState.paused,
      accountLabel: label,
      pausedUntil: until,
    ),
  };
});

/// 준비됐을 때만 호출 창구. 아니면 null — 기능은 버튼을 눌렀을 때 안내만 한다.
final aiGatewayProvider = Provider<AiGateway?>((ref) {
  final readiness = ref.watch(aiReadinessProvider);
  if (!readiness.isReady) return null;
  return ref.watch(aiBackendProvider(readiness.route)).gateway;
});
