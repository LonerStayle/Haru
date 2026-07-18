import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/settings/archive_screen.dart';

/// 보관함 화면 렌더링 검증 — 보관된 그룹/카테고리 목록 + 복원 버튼 + 빈 상태.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<Category> categories,
    required List<Group> groups,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoriesProvider.overrideWith((_) => Stream.value(categories)),
          groupsProvider.overrideWith((_) => Stream.value(groups)),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const ArchiveScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('보관된 항목 없으면 빈 상태 노출', (tester) async {
    await pump(tester, categories: Category.builtinSeeds, groups: const []);
    expect(find.text('보관된 항목이 없어요'), findsOneWidget);
  });

  testWidgets('보관된 그룹 + 카테고리 목록 + 복원 버튼 노출', (tester) async {
    const archivedGroup = Group(
      id: 'g-old',
      label: '지난회사',
      colorValue: 0xFF2A66FF,
      archived: true,
    );
    // g-old 소속 (cascade 보관된) 카테고리 — 그룹 항목으로 대표되어 카테고리 섹션엔 안 뜸.
    final inGroup = Category.work.copyWith(groupId: 'g-old', archived: true);
    // 개별 보관된 미분류 카테고리 — 카테고리 섹션에 뜸.
    final standalone = Category.idea.copyWith(archived: true);

    await pump(
      tester,
      categories: [inGroup, standalone, Category.daily],
      groups: const [archivedGroup],
    );

    // 그룹 섹션.
    expect(find.text('지난회사'), findsOneWidget);
    expect(find.byKey(const ValueKey('restore-group-g-old')), findsOneWidget);
    // 그룹에 카테고리 1개 포함 표시.
    expect(find.text('카테고리 1개'), findsOneWidget);

    // 카테고리 섹션 — standalone 만 (inGroup 은 그룹으로 대표되어 제외).
    expect(
      find.byKey(ValueKey('restore-cat-${Category.idea.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('restore-cat-${Category.work.id}')),
      findsNothing,
      reason: '보관 그룹에 속한 카테고리는 카테고리 섹션에서 제외',
    );
  });
}
