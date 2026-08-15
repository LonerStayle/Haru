import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar/google_auth_service.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_day_cell.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_screen.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';

/// 모바일 밀도 — 좁고 낮은 화면에서도 오버플로 없이, 터치 타겟을 지키는지.
///
/// "기능은 양쪽 parity, 폭·줄 수·터치 타겟만 모바일 압축" 규칙의 실측 고정.
void main() {
  final now = DateTime(2026, 8, 15, 12);

  Todo undated(String id) => Todo(
    id: id,
    title: '언젠가 할 일 $id',
    category: Category.work,
    dueAt: null,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  Future<void> mount(
    WidgetTester tester, {
    required Size size,
    required FormFactor form,
    List<Todo> todos = const [],
    bool googleAvailable = false,
  }) async {
    AppPlatform.debugFormFactorOverride = form;
    addTearDown(() => AppPlatform.debugFormFactorOverride = null);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nowProvider.overrideWithValue(() => now),
          recurrenceMaterializerProvider.overrideWith((_) {}),
          allTodosProvider.overrideWith((_) => Stream.value(todos)),
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
          googleCalendarAvailableProvider.overrideWithValue(googleAvailable),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const Scaffold(body: CalendarScreen()),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  Finder cell(DateTime d) =>
      find.byKey(ValueKey('calendar-cell-${calendarDateKey(d)}'));

  group('오버플로 없음', () {
    for (final size in const [
      Size(320, 640), // 아주 작은 폰
      Size(360, 780),
      Size(412, 915), // 흔한 안드로이드
    ]) {
      testWidgets('모바일 ${size.width.toInt()}x${size.height.toInt()}', (
        tester,
      ) async {
        await mount(
          tester,
          size: size,
          form: FormFactor.mobile,
          googleAvailable: true,
          todos: [for (var i = 0; i < 30; i++) undated('u$i')],
        );
        expect(tester.takeException(), isNull);

        // 서랍을 펼친 상태에서도 넘치지 않는다.
        await tester.tap(find.byKey(const ValueKey('calendar-undated-header')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('데스크탑 좁은 창 (900x600)', (tester) async {
      await mount(
        tester,
        size: const Size(900, 600),
        form: FormFactor.desktop,
        googleAvailable: true,
        todos: [for (var i = 0; i < 30; i++) undated('u$i')],
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('calendar-undated-header')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('터치 타겟', () {
    testWidgets('흔한 폰에서 달력 한 칸이 48dp 이상', (tester) async {
      await mount(
        tester,
        size: const Size(412, 915),
        form: FormFactor.mobile,
        todos: [for (var i = 0; i < 30; i++) undated('u$i')],
      );
      final size = tester.getSize(cell(DateTime(2026, 8, 15)));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
    });

    testWidgets('서랍을 펼쳐도 칸이 48dp 이상 (서랍 상한이 그걸 지켜준다)', (tester) async {
      await mount(
        tester,
        size: const Size(412, 915),
        form: FormFactor.mobile,
        todos: [for (var i = 0; i < 30; i++) undated('u$i')],
      );
      await tester.tap(find.byKey(const ValueKey('calendar-undated-header')));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(cell(DateTime(2026, 8, 15))).height,
        greaterThanOrEqualTo(48),
      );
    });
  });
}
