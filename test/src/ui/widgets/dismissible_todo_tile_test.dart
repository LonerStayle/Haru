import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/ui/widgets/dismissible_todo_tile.dart';

void main() {
  // 스와이프 삭제는 모바일 전용이다 (데스크탑은 흔들린 클릭을 빼앗아 꺼 둠 —
  // desktop_click_jitter_test.dart 참고). 이 파일은 모바일 동작을 검증한다.
  setUp(() => AppPlatform.debugFormFactorOverride = FormFactor.mobile);
  tearDown(() => AppPlatform.debugFormFactorOverride = null);

  Todo make({String id = 'a'}) => Todo(
    id: id,
    title: 'x',
    category: Category.daily,
    dueAt: null,
    doneAt: null,
    createdAt: DateTime.utc(2026, 5, 27, 9),
    updatedAt: DateTime.utc(2026, 5, 27, 9),
    calendarEventId: null,
  );

  Future<void> mount(
    WidgetTester tester, {
    VoidCallback? onDelete,
    Future<bool> Function()? confirmDismiss,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.mobileLight(),
        home: Scaffold(
          body: DismissibleTodoTile(
            todo: make(),
            onDelete: onDelete,
            confirmDismiss: confirmDismiss,
          ),
        ),
      ),
    );
  }

  testWidgets('Dismissible threshold 가 실수 swipe 방지용으로 0.6 으로 설정', (
    tester,
  ) async {
    await mount(tester);
    final dismissible = tester.widget<Dismissible>(find.byType(Dismissible));
    expect(
      dismissible.dismissThresholds[DismissDirection.endToStart],
      0.6,
      reason: '0.4 같은 낮은 threshold 는 살짝 swipe 으로 실수 삭제 위험',
    );
  });

  testWidgets('confirmDismiss 콜백 미주입 → Dismissible.confirmDismiss == null', (
    tester,
  ) async {
    await mount(tester);
    final dismissible = tester.widget<Dismissible>(find.byType(Dismissible));
    expect(dismissible.confirmDismiss, isNull);
  });

  testWidgets('confirmDismiss 콜백 주입 → Dismissible.confirmDismiss 가 그 값을 호출', (
    tester,
  ) async {
    var called = false;
    await mount(
      tester,
      confirmDismiss: () async {
        called = true;
        return false; // dismiss 거부
      },
    );
    final dismissible = tester.widget<Dismissible>(find.byType(Dismissible));
    final fn = dismissible.confirmDismiss;
    expect(fn, isNotNull);

    final result = await fn!(DismissDirection.endToStart);
    expect(called, isTrue);
    expect(result, isFalse);
  });

  testWidgets('데스크탑 — 스와이프 삭제 없음 (Dismissible 미사용)', (tester) async {
    AppPlatform.debugFormFactorOverride = FormFactor.desktop;
    await mount(tester);
    expect(find.byType(Dismissible), findsNothing);
  });
}
