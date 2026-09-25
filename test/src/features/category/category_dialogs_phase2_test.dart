import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/categories_repository.dart';
import 'package:solo_todo/src/data/groups_repository.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/features/category/add_category_dialog.dart';
import 'package:solo_todo/src/features/category/add_group_dialog.dart';

/// Phase 2 — 카테고리·그룹 다이얼로그: 중복 이름 막기, 맨 뒤 순서, Enter 저장, 그룹 프리셀렉트.
void main() {
  const g1 = Group(id: 'g1', label: '회사', colorValue: 0xFF3366FF, sortOrder: 7);

  Future<void> mount(
    WidgetTester tester, {
    required _CatRepo cats,
    required _GroupRepo groups,
    required Future<void> Function(BuildContext) open,
  }) async {
    await tester.binding.setSurfaceSize(const Size(700, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoriesRepositoryProvider.overrideWithValue(cats),
          groupsRepositoryProvider.overrideWithValue(groups),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => open(ctx),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
  }

  group('카테고리', () {
    testWidgets('같은 이름이 있으면 안내 + 추가 비활성 (대소문자·공백 무시)', (tester) async {
      final cats = _CatRepo();
      await mount(
        tester,
        cats: cats,
        groups: _GroupRepo(),
        open: (ctx) => AddCategoryDialog.show(ctx),
      );
      await tester.enterText(
        find.byType(TextField),
        ' ${Category.work.label} ',
      );
      await tester.pumpAndSettle();

      expect(find.text('같은 이름의 카테고리가 이미 있어요'), findsOneWidget);
      final add = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '추가'),
      );
      expect(add.onPressed, isNull);
    });

    testWidgets('수정 모드에서 자기 이름은 중복이 아니다', (tester) async {
      final cats = _CatRepo();
      await mount(
        tester,
        cats: cats,
        groups: _GroupRepo(),
        open: (ctx) => AddCategoryDialog.showEdit(ctx, Category.work),
      );
      expect(find.text('같은 이름의 카테고리가 이미 있어요'), findsNothing);
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '저장'),
      );
      expect(save.onPressed, isNotNull);
    });

    testWidgets('새 카테고리는 맨 뒤 (최대 sortOrder + 1)', (tester) async {
      final cats = _CatRepo();
      await mount(
        tester,
        cats: cats,
        groups: _GroupRepo(),
        open: (ctx) => AddCategoryDialog.show(ctx),
      );
      await tester.enterText(find.byType(TextField), '독서');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final maxOrder = Category.builtinSeeds
          .map((c) => c.sortOrder)
          .reduce((a, b) => a > b ? a : b);
      expect(cats.upserts.single.sortOrder, greaterThan(maxOrder));
      expect(cats.upserts.single.sortOrder, greaterThanOrEqualTo(100));
    });

    testWidgets('그룹 메뉴에서 연 추가 — 그 그룹이 미리 선택돼 있다', (tester) async {
      final cats = _CatRepo();
      await mount(
        tester,
        cats: cats,
        groups: _GroupRepo([g1]),
        open: (ctx) => AddCategoryDialog.show(ctx, initialGroupId: 'g1'),
      );
      await tester.enterText(find.byType(TextField), '독서');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '추가'));
      await tester.pumpAndSettle();
      expect(cats.upserts.single.groupId, 'g1');
    });
  });

  group('그룹', () {
    testWidgets('같은 이름이 있으면 안내 + 추가 비활성', (tester) async {
      await mount(
        tester,
        cats: _CatRepo(),
        groups: _GroupRepo([g1]),
        open: (ctx) => AddGroupDialog.show(ctx),
      );
      await tester.enterText(find.byType(TextField), '회사');
      await tester.pumpAndSettle();
      expect(find.text('같은 이름의 그룹이 이미 있어요'), findsOneWidget);
      final add = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '추가'),
      );
      expect(add.onPressed, isNull);
    });

    testWidgets('Enter 로 저장 + 맨 뒤 순서', (tester) async {
      final groups = _GroupRepo([g1]);
      await mount(
        tester,
        cats: _CatRepo(),
        groups: groups,
        open: (ctx) => AddGroupDialog.show(ctx),
      );
      await tester.enterText(find.byType(TextField), '개인');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(groups.upserts, hasLength(1));
      expect(groups.upserts.single.label, '개인');
      expect(groups.upserts.single.sortOrder, greaterThanOrEqualTo(100));
      expect(find.byType(AddGroupDialog), findsNothing);
    });
  });
}

class _CatRepo implements CategoriesRepository {
  final List<Category> upserts = [];

  @override
  Future<void> upsert(Category category) async => upserts.add(category);

  @override
  Future<Category?> getById(String id) async => null;

  @override
  Future<List<Category>> getAll() async => Category.builtinSeeds;

  @override
  Stream<List<Category>> watchAll() => Stream.value(Category.builtinSeeds);

  @override
  Future<int> deleteById(String id) async => 0;

  @override
  Future<int> countTodosOfCategory(String id) async => 0;
}

class _GroupRepo implements GroupsRepository {
  _GroupRepo([this.initial = const []]);

  final List<Group> initial;
  final List<Group> upserts = [];

  @override
  Future<Group?> getById(String id) async => null;

  @override
  Future<List<Group>> getAll() async => initial;

  @override
  Stream<List<Group>> watchAll() => Stream.value(initial);

  @override
  Future<void> upsert(Group group) async => upserts.add(group);

  @override
  Future<int> deleteById(String id) async => 0;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
