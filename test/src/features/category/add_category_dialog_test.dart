import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/categories_repository.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/features/category/add_category_dialog.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';

/// AddCategoryDialog widget 검증.
///
/// CategoriesController 가 `categoriesRepositoryProvider` 를 watch 하므로 fake
/// repository 로 override 해서 add() 호출 결과를 캡처.
void main() {
  Future<void> mount(WidgetTester tester, _FakeRepo repo) async {
    await tester.binding.setSurfaceSize(const Size(700, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoriesRepositoryProvider.overrideWithValue(repo),
          // v1.3 — 그룹 dropdown 이 groupsProvider 를 watch. Drift timer leak 방지.
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => AddCategoryDialog.show(ctx),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('label 비어 있으면 "추가" 비활성', (tester) async {
    final repo = _FakeRepo();
    await mount(tester, repo);
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    final addBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '추가'),
    );
    expect(addBtn.onPressed, isNull);
  });

  testWidgets('label 입력 + 추가 → controller.add 호출 + dialog 닫힘', (tester) async {
    final repo = _FakeRepo();
    await mount(tester, repo);
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '독서');
    await tester.pumpAndSettle();

    final addBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '추가'),
    );
    expect(addBtn.onPressed, isNotNull);
    addBtn.onPressed?.call();
    await tester.pumpAndSettle();

    expect(repo.upsertCalls, hasLength(1));
    expect(repo.upsertCalls.single.label, '독서');
    expect(repo.upsertCalls.single.isBuiltin, isFalse);
    expect(find.byType(AddCategoryDialog), findsNothing); // 닫힘
  });

  testWidgets('수정 모드 — 기존 값 프리필 + 같은 id 로 저장, 순서·기본 여부 보존', (tester) async {
    // UX 감사 B6 — 카테고리 이름·색·아이콘을 고칠 방법이 없었다.
    const existing = Category(
      id: 'cat-reading',
      label: '독서',
      iconCodePoint: 0xe865,
      colorValue: 0xFF3B82F6,
      sortOrder: 7,
    );
    final repo = _FakeRepo();
    await tester.binding.setSurfaceSize(const Size(700, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoriesRepositoryProvider.overrideWithValue(repo),
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => AddCategoryDialog.showEdit(ctx, existing),
                  child: const Text('수정'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('수정'));
    await tester.pumpAndSettle();

    expect(find.text('카테고리 수정'), findsOneWidget);
    expect(find.text('독서'), findsOneWidget, reason: '기존 이름이 채워져 있어야 한다');

    await tester.enterText(find.byType(TextField), '독서 모임');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();

    final saved = repo.upsertCalls.single;
    expect(saved.id, 'cat-reading');
    expect(saved.label, '독서 모임');
    expect(saved.sortOrder, 7);
    expect(saved.iconCodePoint, 0xe865);
    expect(find.byType(AddCategoryDialog), findsNothing);
  });

  testWidgets('이름 입력 후 Enter → 바로 추가', (tester) async {
    final repo = _FakeRepo();
    await mount(tester, repo);
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '운동');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(repo.upsertCalls.single.label, '운동');
  });

  testWidgets('취소 버튼 → dialog 닫힘 + controller 호출 X', (tester) async {
    final repo = _FakeRepo();
    await mount(tester, repo);
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, '취소'));
    await tester.pumpAndSettle();

    expect(repo.upsertCalls, isEmpty);
    expect(find.byType(AddCategoryDialog), findsNothing);
  });

  test('iconPalette 는 builtin 카테고리 5종 아이콘을 모두 포함', () {
    // 새 카테고리에서도 기본 카테고리와 같은 아이콘을 고를 수 있어야 한다.
    for (final seed in Category.builtinSeeds) {
      expect(
        AddCategoryDialog.iconPalette,
        contains(seed.iconCodePoint),
        reason: 'builtin "${seed.label}" 아이콘이 palette 에서 누락됨',
      );
    }
  });

  test('iconPalette 에 중복 codepoint 없음', () {
    final seen = AddCategoryDialog.iconPalette.toSet();
    expect(seen, hasLength(AddCategoryDialog.iconPalette.length));
  });

  testWidgets('색 / 아이콘 선택 → submission 에 반영', (tester) async {
    final repo = _FakeRepo();
    await mount(tester, repo);
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '운동');
    // 두 번째 색을 직접 탭하려면 InkWell 위치 알아야 — 단순화: 16 색 중 두 번째.
    // 실제 위젯 트리에서 Color circle 은 GestureDetector. tap 으로 두 번째 GestureDetector tap.
    final colorTaps = find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final dec = w.decoration;
      if (dec is! BoxDecoration) return false;
      return dec.shape == BoxShape.circle && dec.color != null;
    });
    expect(colorTaps, findsNWidgets(16));
    // 두 번째 색을 탭.
    await tester.tap(colorTaps.at(1));
    await tester.pumpAndSettle();

    final addBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '추가'),
    );
    addBtn.onPressed?.call();
    await tester.pumpAndSettle();

    expect(repo.upsertCalls, hasLength(1));
    expect(
      repo.upsertCalls.single.colorValue,
      AddCategoryDialog.colorPalette[1],
    );
  });
}

class _FakeRepo implements CategoriesRepository {
  final List<Category> upsertCalls = [];

  @override
  Future<void> upsert(Category category) async {
    upsertCalls.add(category);
  }

  @override
  Future<Category?> getById(String id) async => null;

  @override
  Future<List<Category>> getAll() async => const [];

  @override
  Stream<List<Category>> watchAll() => Stream.value(Category.builtinSeeds);

  @override
  Future<int> deleteById(String id) async => 0;

  @override
  Future<int> countTodosOfCategory(String id) async => 0;
}
