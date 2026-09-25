import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/category_providers.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/ui/app_shell.dart';

import 'package:solo_todo/src/ui/shell_state.dart';

/// 숫자 단축키 = 사이드바에 보이는 순서 (2026-09-25 대표님 제보: Bxg 가 맨 위인데 9번).
void main() {
  // 카테고리 sortOrder 로는 JS슈퍼(4)가 먼저지만, 사이드바는 그룹 순서(회사 → 프로젝트)라
  // Bxg(101)가 맨 위다.
  const company = Group(
    id: 'company',
    label: '회사',
    colorValue: 0,
    sortOrder: 0,
  );
  const project = Group(
    id: 'project',
    label: '프로젝트',
    colorValue: 0,
    sortOrder: 1,
  );
  final cats = [
    Category.work.copyWith(
      id: 'js',
      label: 'JS슈퍼',
      sortOrder: 4,
      groupId: 'project',
    ),
    Category.personalDev.copyWith(
      id: 'andy',
      label: '앤디',
      sortOrder: 5,
      groupId: 'project',
    ),
    Category.daily.copyWith(
      id: 'bxg',
      label: 'Bxg',
      sortOrder: 101,
      groupId: 'company',
    ),
    Category.idea.copyWith(
      id: 'etc',
      label: '회사기타',
      sortOrder: 102,
      groupId: 'company',
    ),
    Category.longterm.copyWith(id: 'loose', label: '미분류칸', sortOrder: 0),
  ];

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          watchTodayTodosProvider.overrideWith((_) => Stream.value(<Todo>[])),
          recurrenceMaterializerProvider.overrideWith((_) {}),
          watchTodosByCategoryProvider.overrideWith(
            (_, _) => Stream.value(<Todo>[]),
          ),
          outboxCountProvider.overrideWith((_) => Stream<int>.value(0)),
          allTodosProvider.overrideWith((_) => Stream.value(<Todo>[])),
          rootsOfCategoryProvider.overrideWith(
            (_, _) => Stream.value(<Todo>[]),
          ),
          childrenOfProvider.overrideWith((_, _) => Stream.value(<Todo>[])),
          categoriesProvider.overrideWith((_) => Stream.value(cats)),
          groupsProvider.overrideWith(
            (_) => Stream.value(const [project, company]),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const AppShell(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  testWidgets('3 = 사이드바 맨 위 카테고리(Bxg), 이어서 보이는 순서대로', (tester) async {
    await pump(tester);
    final expected = {
      LogicalKeyboardKey.digit3: 'Bxg',
      LogicalKeyboardKey.digit4: '회사기타',
      LogicalKeyboardKey.digit5: 'JS슈퍼',
      LogicalKeyboardKey.digit6: '앤디',
      LogicalKeyboardKey.digit7: '미분류칸',
    };
    for (final e in expected.entries) {
      await press(tester, e.key);
      expect(find.text(e.value), findsAtLeastNWidgets(1), reason: '${e.key}');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AppShell)),
      );
      final loc = container.read(shellLocationProvider);
      expect(loc.categoryId, cats.firstWhere((c) => c.label == e.value).id);
    }
  });
}
