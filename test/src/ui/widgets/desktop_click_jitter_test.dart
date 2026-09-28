import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/ui/widgets/click_tolerant_draggable.dart';
import 'package:solo_todo/src/ui/widgets/dismissible_todo_tile.dart';

/// 대표님 제보(2026-09-25): "클릭 자체가 잘 안 된다" (macOS).
///
/// Flutter 는 마우스(맥 트랙패드 클릭 포함)의 드래그 판정 임계가 1px 이다. 할 일 카드를
/// 감싼 "밀어서 삭제"(Dismissible) 가 가로 드래그를 듣고 있으면, 클릭하는 동안 손이
/// 1~2px 만 흔들려도 드래그가 이겨 탭·체크 클릭이 사라진다. 데스크탑에서 흔들린 클릭이
/// 그대로 클릭으로 처리되는지 검증한다.
void main() {
  setUp(() => AppPlatform.debugFormFactorOverride = FormFactor.desktop);
  tearDown(() => AppPlatform.debugFormFactorOverride = null);

  final todo = Todo(
    id: 'a',
    title: '흔들린 클릭',
    category: Category.daily,
    createdAt: DateTime.utc(2026, 9, 25),
    updatedAt: DateTime.utc(2026, 9, 25),
  );

  Future<void> mount(
    WidgetTester tester, {
    VoidCallback? onTap,
    VoidCallback? onToggle,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.mobileLight(),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            child: DismissibleTodoTile(
              todo: todo,
              onTap: onTap,
              onToggle: onToggle,
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
  }

  /// 마우스로 누른 채 [dx]px 옆으로 움직였다 떼는 클릭.
  Future<void> jitteryMouseClick(
    WidgetTester tester,
    Finder target, {
    double dx = 3,
  }) async {
    final gesture = await tester.startGesture(
      tester.getCenter(target),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(Offset(-dx, 0));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('체크 버튼 — 3px 흔들린 마우스 클릭도 완료 토글로 처리된다', (tester) async {
    var toggled = 0;
    await mount(tester, onToggle: () => toggled++);
    await jitteryMouseClick(
      tester,
      find.byKey(const ValueKey('todo-tile-check')),
    );
    expect(toggled, 1);
  });

  testWidgets('카드 본문 — 3px 흔들린 마우스 클릭도 탭으로 처리된다', (tester) async {
    var taps = 0;
    await mount(tester, onTap: () => taps++);
    await jitteryMouseClick(tester, find.text('흔들린 클릭'));
    expect(taps, 1);
  });

  testWidgets('대조군 — 흔들림 없는 마우스 클릭은 원래도 동작한다', (tester) async {
    var toggled = 0;
    await mount(tester, onToggle: () => toggled++);
    await jitteryMouseClick(
      tester,
      find.byKey(const ValueKey('todo-tile-check')),
      dx: 0,
    );
    expect(toggled, 1);
  });

  group('ClickTolerantDraggable (캘린더 패널 카드)', () {
    Future<({List<int> taps, List<int> drags})> mountDraggable(
      WidgetTester tester,
    ) async {
      final taps = <int>[];
      final drags = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ClickTolerantDraggable<String>(
                data: 'x',
                feedback: const SizedBox(width: 10, height: 10),
                onDragStarted: () => drags.add(1),
                child: GestureDetector(
                  onTap: () => taps.add(1),
                  child: const SizedBox(
                    width: 200,
                    height: 60,
                    child: Text('카드'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return (taps: taps, drags: drags);
    }

    testWidgets('3px 흔들린 클릭은 탭', (tester) async {
      final r = await mountDraggable(tester);
      await jitteryMouseClick(tester, find.text('카드'));
      expect(r.taps, hasLength(1));
      expect(r.drags, isEmpty);
    });

    testWidgets('크게 끌면(20px) 드래그', (tester) async {
      final r = await mountDraggable(tester);
      final g = await tester.startGesture(
        tester.getCenter(find.text('카드')),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(20, 0));
      await tester.pump();
      expect(r.drags, hasLength(1));
      await g.up();
      await tester.pumpAndSettle();
      expect(r.taps, isEmpty);
    });
  });
}
