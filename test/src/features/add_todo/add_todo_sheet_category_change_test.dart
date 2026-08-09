import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';

/// 작업 1 — AddTodoSheet edit 모드에서 카테고리를 다른 그룹의 사용자 카테고리로
/// 바꾸고 저장하면 onUpdate 가 **바뀐 category** 로 호출되는지 결판.
///
/// 특히 그룹별 칩 묶음(J) 이 켜진 상태에서 선택이 제대로 반영되는지, 그리고
/// categoriesProvider 가 잠깐 builtin fallback 일 때 사용자 선택을 덮어쓰지 않는지
/// (post-frame 자동보정 가드) 까지 확인한다.
void main() {
  const daily = Category(
    id: 'daily',
    label: '일상',
    iconCodePoint: 0xf107,
    colorValue: 0xFF10B981,
    sortOrder: 2,
    isBuiltin: true,
  );
  const cogito = Category(
    id: 'cogito',
    label: '코기토',
    iconCodePoint: 0xe176,
    colorValue: 0xFF8B5CF6,
    sortOrder: 9,
    groupId: 'group-x',
  );
  const groupX = Group(
    id: 'group-x',
    label: '사이드',
    colorValue: 0xFF8B5CF6,
    sortOrder: 0,
  );

  Todo initial() => Todo(
    id: 'edit-1',
    title: '장보기',
    category: daily,
    dueAt: null,
    doneAt: null,
    createdAt: DateTime.utc(2026, 5, 28),
    updatedAt: DateTime.utc(2026, 5, 28),
    calendarEventId: null,
  );

  Future<List<Todo>> mount(
    WidgetTester tester, {
    required List<Category> categories,
    required List<Group> groups,
  }) async {
    await tester.binding.setSurfaceSize(const Size(700, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final updates = <Todo>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoriesProvider.overrideWith((_) => Stream.value(categories)),
          groupsProvider.overrideWith((_) => Stream.value(groups)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: AddTodoSheet(
              initialCategory: daily,
              initialTodo: initial(),
              onSubmit: (_) {},
              onUpdate: updates.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return updates;
  }

  testWidgets(
    'edit 모드 — 다른 그룹의 사용자 카테고리(코기토) 선택 후 저장 → onUpdate.category == 코기토',
    (tester) async {
      final updates = await mount(
        tester,
        categories: const [daily, cogito],
        groups: const [groupX],
      );

      // 아코디언(J) — 초기 선택(일상)은 미분류 섹션이라 '사이드' 그룹은 접혀 있다.
      // 그룹 헤더를 탭해 펼친 뒤 '코기토' 칩을 탭해 선택.
      await tester.tap(
        find.byKey(const ValueKey('category-group-header-group-x')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('코기토'));
      await tester.pumpAndSettle();

      final saveBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '저장'),
      );
      saveBtn.onPressed?.call();
      await tester.pumpAndSettle();

      expect(updates, hasLength(1));
      expect(
        updates.single.category.id,
        'cogito',
        reason: '저장된 카테고리가 사용자가 고른 코기토여야 — 일상으로 되돌아가면 안 됨',
      );
    },
  );

  testWidgets('아코디언 — 디폴트는 선택 카테고리 섹션만 펼침, 헤더 탭으로 전환', (tester) async {
    await mount(
      tester,
      categories: const [daily, cogito],
      groups: const [groupX],
    );

    // 그룹 헤더는 항상 전부 보인다.
    expect(
      find.byKey(const ValueKey('category-group-header-ungrouped')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('category-group-header-group-x')),
      findsOneWidget,
    );

    // 디폴트: 선택(일상)이 속한 미분류만 펼침 → 일상 칩 보임, 코기토 칩 숨김.
    expect(find.byKey(const ValueKey('category-chip-daily')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-chip-cogito')), findsNothing);

    // '사이드' 그룹 헤더 탭 → 코기토 칩이 보이고 미분류 칩은 접힌다.
    await tester.tap(
      find.byKey(const ValueKey('category-group-header-group-x')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-chip-cogito')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-chip-daily')), findsNothing);
  });

  testWidgets(
    'categoriesProvider 가 코기토를 포함하지 않는 fallback 이어도 사용자 선택을 덮어쓰지 않음',
    (tester) async {
      // initialTodo.category = 코기토 인데 provider 목록엔 코기토가 없는 상황.
      // post-frame 자동보정이 무분별하면 첫 항목(일상)으로 리셋해 버린다 → 가드 검증.
      await tester.binding.setSurfaceSize(const Size(700, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final updates = <Todo>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // 코기토 빠진 목록 (일시적 fallback 모사).
            categoriesProvider.overrideWith((_) => Stream.value(const [daily])),
            groupsProvider.overrideWith((_) => Stream.value(const <Group>[])),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: AddTodoSheet(
                initialCategory: daily,
                initialTodo: initial().copyWith(category: cogito),
                onSubmit: (_) {},
                onUpdate: updates.add,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final saveBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '저장'),
      );
      saveBtn.onPressed?.call();
      await tester.pumpAndSettle();

      expect(updates, hasLength(1));
      expect(
        updates.single.category.id,
        'cogito',
        reason: 'provider 가 코기토를 모르더라도 기존 선택(코기토)을 보존해야',
      );
    },
  );
}
