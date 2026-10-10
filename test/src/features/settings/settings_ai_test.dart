import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/features/ai/ai_backend.dart';
import 'package:solo_todo/src/features/ai/ai_gateway.dart';
import 'package:solo_todo/src/features/ai/ai_providers.dart';
import 'package:solo_todo/src/features/ai/ai_route.dart';
import 'package:solo_todo/src/features/calendar/google_auth_service.dart';
import 'package:solo_todo/src/features/calendar/microsoft_auth_service.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/settings/settings_sheet.dart';
import 'package:solo_todo/src/features/settings/sort_mode_controller.dart';

import '../ai/fake_ai_gateway.dart';

class _MemorySort implements SortModePreference {
  @override
  Future<TodoSortMode> load() async => TodoSortMode.manual;

  @override
  Future<void> save(TodoSortMode mode) async {}
}

class _Backend implements AiBackend {
  _Backend(this.route);

  @override
  final AiRoute route;
  final status = StreamController<AiAccountStatus>.broadcast();
  AiAccountStatus current = const AiSignedOut();
  final fake = FakeAiGateway();
  int signIns = 0, signOuts = 0;
  String? pastedCode;
  bool askForCode = false;

  void emit(AiAccountStatus s) {
    current = s;
    status.add(s);
  }

  @override
  Stream<AiAccountStatus> watchStatus() async* {
    yield current;
    yield* status.stream;
  }

  @override
  Future<void> signIn(AiSignInPrompter prompter) async {
    signIns++;
    if (askForCode) {
      pastedCode = await prompter.askCode(message: 'code#state');
      if (pastedCode == null) return;
    }
    emit(const AiSignedIn(label: 'me@x.com', plan: 'Plus'));
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    emit(const AiSignedOut());
  }

  @override
  AiGateway get gateway => fake;
}

void main() {
  late _Backend backend;

  Future<(MemoryUiPrefsStore, ProviderContainer)> open(
    WidgetTester tester, {
    FormFactor form = FormFactor.desktop,
  }) async {
    AppPlatform.debugFormFactorOverride = form;
    addTearDown(() => AppPlatform.debugFormFactorOverride = null);
    await tester.binding.setSurfaceSize(const Size(1100, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = MemoryUiPrefsStore();
    final container = ProviderContainer(
      overrides: [
        uiPrefsStoreProvider.overrideWithValue(prefs),
        sortModePreferenceProvider.overrideWithValue(_MemorySort()),
        categoriesProvider.overrideWith(
          (_) => Stream.value(Category.builtinSeeds),
        ),
        groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
        googleCalendarAvailableProvider.overrideWithValue(false),
        microsoftCalendarAvailableProvider.overrideWithValue(false),
        aiBackendProvider.overrideWith((ref, route) => backend),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => SettingsSheet.show(context),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-ai-route')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    return (prefs, container);
  }

  setUp(() => backend = _Backend(AiRoute.chatgptPlan));

  testWidgets('기본은 끔 — 계정·확인·보내는 내용 줄이 없다', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('settings-section-AI')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-ai-account')), findsNothing);
    expect(find.byKey(const ValueKey('settings-ai-check')), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-ai-send-description')),
      findsNothing,
    );
  });

  testWidgets('ChatGPT 플랜을 고르면 저장되고 로그인 → 로그아웃', (tester) async {
    final (prefs, container) = await open(tester);
    await tester.tap(find.text('ChatGPT 플랜'));
    await tester.pumpAndSettle();
    expect(prefs.lists['ai.route'], ['chatgpt']);
    expect(find.text('로그인이 필요해요'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-ai-signin')));
    await tester.pumpAndSettle();
    expect(backend.signIns, 1);
    expect(find.text('me@x.com · Plus'), findsOneWidget);
    expect(container.read(aiGatewayProvider), same(backend.fake));

    await tester.tap(find.byKey(const ValueKey('settings-ai-signout')));
    await tester.pumpAndSettle();
    expect(backend.signOuts, 1);
    expect(find.text('로그인이 필요해요'), findsOneWidget);
  });

  testWidgets('Claude 처럼 코드를 붙여넣는 로그인은 대화상자로 받는다', (tester) async {
    backend = _Backend(AiRoute.claudePlan)..askForCode = true;
    await open(tester);
    await tester.tap(find.text('Claude 플랜'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-ai-signin')));
    // 로그인 중엔 진행 표시가 돌아 settle 하지 않는다.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey('settings-ai-code-dialog')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('settings-ai-code-field')),
      'abc#xyz',
    );
    await tester.tap(find.text('확인').last);
    await tester.pumpAndSettle();
    expect(backend.pastedCode, 'abc#xyz');
  });

  testWidgets('연결 확인 — 성공과 실패 안내', (tester) async {
    backend.current = const AiSignedIn(label: 'me@x.com');
    await open(tester);
    await tester.tap(find.text('ChatGPT 플랜'));
    await tester.pumpAndSettle();

    backend.fake.jsonQueue.add({'ok': true});
    await tester.tap(find.byKey(const ValueKey('settings-ai-check')));
    await tester.pumpAndSettle();
    expect(find.textContaining('연결됐어요'), findsOneWidget);
    expect(backend.fake.calls.single.input, 'ping');

    ScaffoldMessenger.of(
      tester.element(find.byKey(const ValueKey('settings-ai-check'))),
    ).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-ai-check')));
    await tester.pumpAndSettle();
    expect(find.text('AI 응답을 받지 못했어요 · 설정에서 확인'), findsOneWidget);
  });

  testWidgets('설명 보내기를 끄면 저장된다', (tester) async {
    final (prefs, _) = await open(tester);
    await tester.tap(find.text('ChatGPT 플랜'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-ai-send-description')),
    );
    await tester.pumpAndSettle();
    expect(prefs.lists['ai.sendDescription'], ['false']);
  });

  testWidgets('폰은 짧은 라벨', (tester) async {
    await open(tester, form: FormFactor.mobile);
    expect(find.text('ChatGPT'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
  });
}
