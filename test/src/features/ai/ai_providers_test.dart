import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/features/ai/ai_backend.dart';
import 'package:solo_todo/src/features/ai/ai_gateway.dart';
import 'package:solo_todo/src/features/ai/ai_providers.dart';
import 'package:solo_todo/src/features/ai/ai_readiness.dart';
import 'package:solo_todo/src/features/ai/ai_route.dart';

import 'fake_ai_gateway.dart';

class _Backend implements AiBackend {
  _Backend(this.route);

  @override
  final AiRoute route;
  final status = StreamController<AiAccountStatus>.broadcast();
  final fake = FakeAiGateway();

  @override
  Stream<AiAccountStatus> watchStatus() => status.stream;

  @override
  Future<void> signIn(AiSignInPrompter prompter) async {}

  @override
  Future<void> signOut() async {}

  @override
  AiGateway get gateway => fake;
}

void main() {
  late MemoryUiPrefsStore store;
  late _Backend backend;

  ProviderContainer make() {
    final c = ProviderContainer(
      overrides: [
        uiPrefsStoreProvider.overrideWithValue(store),
        aiBackendProvider.overrideWith((ref, route) => backend),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    store = MemoryUiPrefsStore();
    backend = _Backend(AiRoute.chatgptPlan);
  });

  test('기본은 꺼짐 — 준비 안 됨, 창구 없음', () async {
    final c = make();
    await c.read(aiRouteProvider.notifier).restored;
    expect(c.read(aiReadinessProvider).state, AiReadyState.off);
    expect(c.read(aiGatewayProvider), isNull);
  });

  test('로그인 상태에 따라 준비 판정', () async {
    final c = make();
    c.listen(aiReadinessProvider, (_, _) {});
    await c.read(aiRouteProvider.notifier).set(AiRoute.chatgptPlan);
    expect(c.read(aiReadinessProvider).state, AiReadyState.loading);

    backend.status.add(const AiSignedOut());
    await Future<void>.delayed(Duration.zero);
    expect(c.read(aiReadinessProvider).state, AiReadyState.needsSignIn);
    expect(c.read(aiGatewayProvider), isNull);

    backend.status.add(const AiSignedIn(label: 'me@x.com', plan: 'Plus'));
    await Future<void>.delayed(Duration.zero);
    expect(c.read(aiReadinessProvider).isReady, isTrue);
    expect(c.read(aiReadinessProvider).accountLabel, 'me@x.com');
    expect(c.read(aiGatewayProvider), same(backend.fake));

    final until = DateTime(2026, 10, 10, 15, 30);
    backend.status.add(AiPaused(label: 'me@x.com', until: until));
    await Future<void>.delayed(Duration.zero);
    final r = c.read(aiReadinessProvider);
    expect(r.state, AiReadyState.paused);
    expect(r.failureHint, contains('15:30'));
    expect(c.read(aiGatewayProvider), isNull);
  });

  test('Claude API — 키 없음·거부됨 안내는 API 키 문구', () async {
    backend = _Backend(AiRoute.claudeApi);
    final c = make();
    c.listen(aiReadinessProvider, (_, _) {});
    await c.read(aiRouteProvider.notifier).set(AiRoute.claudeApi);
    expect(c.read(aiReadinessProvider).state, AiReadyState.loading);

    backend.status.add(const AiSignedOut());
    await Future<void>.delayed(Duration.zero);
    expect(c.read(aiReadinessProvider).state, AiReadyState.needsSignIn);
    expect(c.read(aiReadinessProvider).failureHint, 'API 키가 필요해요 · 설정에서 입력');

    backend.status.add(
      const AiSignedIn(label: 'API 키 ····abcd · 거부됨', rejected: true),
    );
    await Future<void>.delayed(Duration.zero);
    final r = c.read(aiReadinessProvider);
    expect(r.isReady, isTrue);
    expect(r.keyRejected, isTrue);
    expect(r.failureHint, 'API 키가 거부됐어요 · 설정에서 확인');

    backend.status.add(const AiSignedIn(label: 'API 키 ····abcd'));
    await Future<void>.delayed(Duration.zero);
    expect(c.read(aiReadinessProvider).failureHint, 'AI 응답을 받지 못했어요 · 설정에서 확인');
  });

  test('ChatGPT 플랜 — 로그아웃 안내는 로그인 문구', () {
    expect(
      const AiReadiness(
        route: AiRoute.chatgptPlan,
        state: AiReadyState.needsSignIn,
      ).failureHint,
      '로그인이 풀렸어요 · 설정에서 확인',
    );
  });

  test('경로는 저장되고 다시 열면 복원된다', () async {
    final c = make();
    await c.read(aiRouteProvider.notifier).set(AiRoute.claudeApi);
    expect(store.lists['ai.route'], ['claude']);

    final c2 = make();
    await c2.read(aiRouteProvider.notifier).restored;
    expect(c2.read(aiRouteProvider), AiRoute.claudeApi);
  });

  test('설명 전송은 기본 켬, 끄면 저장', () async {
    final c = make();
    expect(c.read(aiSendDescriptionProvider), isTrue);
    await c.read(aiSendDescriptionProvider.notifier).set(false);
    expect(store.lists['ai.sendDescription'], ['false']);
  });
}
