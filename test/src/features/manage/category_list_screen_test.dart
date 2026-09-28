import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/manage/category_list_screen.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';

/// 모바일 4번째 칸 "카테고리" 목록 (UX 개선 Phase 2 — 예전 관리 Drawer 대체).
void main() {
  const ga = Group(id: 'ga', label: '업무', colorValue: 0xFF3366FF);
  final cats = [
    Category.work.copyWith(groupId: 'ga'),
    Category.personalDev.copyWith(groupId: 'ga'),
    Category.daily,
  ];

  late MemoryUiPrefsStore prefs;
  setUp(() => prefs = MemoryUiPrefsStore());

  Future<(List<Category>, List<Group>)> mount(
    WidgetTester tester, {
    List<Todo> todos = const [],
    List<Override> extra = const [],
  }) async {
    final opened = <Category>[];
    final openedGroups = <Group>[];
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uiPrefsStoreProvider.overrideWithValue(prefs),
          categoriesProvider.overrideWith((_) => Stream.value(cats)),
          groupsProvider.overrideWith((_) => Stream.value(const [ga])),
          allTodosProvider.overrideWith((_) => Stream.value(todos)),
          ...extra,
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: Scaffold(
            body: CategoryListScreen(
              onSelectCategory: opened.add,
              onOpenGroup: openedGroups.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return (opened, openedGroups);
  }

  testWidgets('그룹 머리 아래 카테고리, 미분류는 맨 아래', (tester) async {
    await mount(tester);
    expect(find.text('업무'), findsOneWidget);
    expect(find.text('미분류'), findsOneWidget);
    final groupY = tester.getTopLeft(find.text('업무')).dy;
    final ungroupedY = tester.getTopLeft(find.text('미분류')).dy;
    expect(ungroupedY, greaterThan(groupY));
    // 예전 Drawer 의 "그룹 chip" 중복 표시는 없다 — 카테고리 줄마다 그룹명이 반복되지 않음.
    expect(find.text('업무'), findsOneWidget);
  });

  testWidgets('카테고리 탭 → 그 카테고리 열기', (tester) async {
    final (opened, _) = await mount(tester);
    await tester.tap(find.text(Category.work.label));
    expect(opened.single.id, 'work');
  });

  testWidgets('남은 할 일 수 표시', (tester) async {
    final t = Todo(
      id: 't',
      title: 'x',
      category: Category.work,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await mount(tester, todos: [t]);
    expect(find.byKey(const ValueKey('manage-cat-count-work')), findsOneWidget);
  });

  testWidgets('그룹 머리 탭 = 접기, 상태가 저장된다', (tester) async {
    await mount(tester);
    expect(find.text(Category.work.label), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('manage-group-header-ga')));
    await tester.pump();
    expect(find.text(Category.work.label), findsNothing);
    expect(prefs.data[CategoryListScreen.collapsedKey], {'ga'});
  });

  testWidgets('카테고리 ⋮ → 공용 메뉴 (수정·그룹 이동·보관·삭제)', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('manage-cat-menu-work')));
    await tester.pumpAndSettle();
    for (final name in ['edit', 'move', 'archive', 'delete']) {
      expect(find.byKey(ValueKey('category-menu-$name')), findsOneWidget);
    }
  });

  testWidgets('그룹 ⋮ → "전체보기에서 보기" 가 그 그룹을 연다', (tester) async {
    final (_, groupsOpened) = await mount(tester);
    await tester.tap(find.byKey(const ValueKey('manage-group-menu-ga')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-menu-open')));
    await tester.pumpAndSettle();
    expect(groupsOpened.single.id, 'ga');
  });

  testWidgets('보관할 때 미완료가 남아 있으면 숨겨진다고 알린다 (2026-09-25)', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    for (final c in cats) {
      await db.categoriesDao.upsert(c);
    }
    Todo t(String id, {DateTime? done}) => Todo(
      id: id,
      title: id,
      category: Category.work,
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 1),
      doneAt: done,
    );
    await mount(
      tester,
      todos: [
        t('a'),
        t('b'),
        t('c', done: DateTime.utc(2026, 9, 2)),
      ],
      extra: [appDatabaseProvider.overrideWithValue(db)],
    );
    await tester.tap(find.byKey(const ValueKey('manage-cat-menu-work')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-menu-archive')));
    await tester.pumpAndSettle();
    expect(find.textContaining('남은 할 일 2개도 함께 숨겨져요'), findsOneWidget);
    expect((await db.categoriesDao.getById('work'))!.archived, isTrue);
  });
}
