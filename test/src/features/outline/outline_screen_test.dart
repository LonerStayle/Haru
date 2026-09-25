import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/outline/outline_screen.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/todo_detail/todo_detail_screen.dart';
import 'package:solo_todo/src/ui/shell_state.dart';

/// 전체보기 (UX 개선 Phase 2) — 탭 없는 단일 계층 브라우저.
void main() {
  Todo make({
    required String id,
    String title = 't',
    Category category = Category.work,
    String? parentId,
    TodoType type = TodoType.task,
    DateTime? doneAt,
  }) => Todo(
    id: id,
    title: title,
    category: category,
    doneAt: doneAt,
    createdAt: DateTime.utc(2026, 5, 27, 9),
    updatedAt: DateTime.utc(2026, 5, 27, 9),
    parentId: parentId,
    type: type,
  );

  late MemoryUiPrefsStore prefs;
  late ProviderContainer container;

  setUp(() => prefs = MemoryUiPrefsStore());
  tearDown(() => AppPlatform.debugFormFactorOverride = null);

  Future<void> mount(
    WidgetTester tester, {
    required List<Todo> allTodos,
    Map<String, List<Todo>> childrenByParent = const {},
    List<Category>? categories,
    List<Group> groups = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 카테고리별 최상위 = parentId 없는 항목.
    List<Todo> rootsOf(Category c) => [
      for (final t in allTodos)
        if (t.parentId == null && t.category.id == c.id) t,
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uiPrefsStoreProvider.overrideWithValue(prefs),
          allTodosProvider.overrideWith((_) => Stream.value(allTodos)),
          rootsOfCategoryProvider.overrideWith(
            (_, cat) => Stream.value(rootsOf(cat)),
          ),
          childrenOfProvider.overrideWith(
            (_, parentId) => Stream.value(
              childrenByParent[parentId] ??
                  [
                    for (final t in allTodos)
                      if (t.parentId == parentId) t,
                  ],
            ),
          ),
          categoriesProvider.overrideWith(
            (_) => Stream.value(categories ?? Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(groups)),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const Scaffold(body: OutlineScreen()),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    container = ProviderScope.containerOf(
      tester.element(find.byType(OutlineScreen)),
    );
  }

  group('구성', () {
    testWidgets('탭이 없다 — 체크리스트/메모 탭 대신 상태 칩 한 줄', (tester) async {
      final t = make(id: 't', title: '할 일');
      final n = make(id: 'n', title: '메모 하나', type: TodoType.note);
      await mount(tester, allTodos: [t, n]);

      expect(find.byType(TabBar), findsNothing);
      expect(find.byKey(const ValueKey('status-filter-all')), findsOneWidget);
      expect(find.byKey(const ValueKey('status-filter-note')), findsOneWidget);
      // 트리 모드에서는 할 일과 메모가 함께 보인다.
      expect(find.text('할 일'), findsOneWidget);
      expect(find.text('메모 하나'), findsOneWidget);
    });

    testWidgets('할 일이 없는 카테고리도 흐리게 보인다 ("비어 있음")', (tester) async {
      await mount(tester, allTodos: const []);
      for (final c in Category.builtinSeeds) {
        expect(find.text(c.label), findsOneWidget);
      }
      expect(find.text('비어 있음'), findsNWidgets(Category.builtinSeeds.length));
      // 할 일이 하나도 없으면 상태 칩 줄은 감춘다.
      expect(find.byKey(const ValueKey('status-filter-all')), findsNothing);
    });

    testWidgets('카테고리가 하나도 없으면 안내', (tester) async {
      await mount(tester, allTodos: const [], categories: const []);
      expect(find.text('카테고리가 없어요'), findsOneWidget);
    });

    testWidgets('진척 배지 + 완료는 "완료 N개" 접기 아래', (tester) async {
      final a = make(id: 'a', title: '캔버스 첨부 오류');
      final d = make(id: 'd', title: '오타 수정', doneAt: DateTime(2026, 5, 27));
      await mount(tester, allTodos: [a, d]);

      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('캔버스 첨부 오류'), findsOneWidget);
      expect(find.text('오타 수정'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('outline-done-toggle-work')));
      await tester.pump();
      expect(find.text('오타 수정'), findsOneWidget);
    });

    testWidgets('하위 항목은 인라인으로 펼치지 않고 개수 배지만', (tester) async {
      final p = make(id: 'p', title: '넥서스');
      final c1 = make(id: 'c1', title: '자식 1', parentId: 'p');
      await mount(tester, allTodos: [p, c1]);
      expect(find.text('넥서스'), findsOneWidget);
      expect(find.text('자식 1'), findsNothing);
      expect(find.byKey(const ValueKey('todo-tile-drill-p')), findsOneWidget);
    });
  });

  group('카테고리 머리', () {
    testWidgets('본문 탭 → 그 카테고리 화면으로 (셸 위치 변경)', (tester) async {
      await mount(
        tester,
        allTodos: [make(id: 'a', title: 'A')],
      );
      await tester.tap(find.byKey(const ValueKey('outline-category-work')));
      await tester.pump();
      expect(
        container.read(shellLocationProvider),
        const ShellLocation.category('work'),
      );
    });

    testWidgets('⌄ = 접기, 접힘은 저장된다', (tester) async {
      await mount(
        tester,
        allTodos: [make(id: 'a', title: '회사 일')],
      );
      expect(find.text('회사 일'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('outline-collapse-work')));
      await tester.pump();
      expect(find.text('회사 일'), findsNothing);
      expect(prefs.data[OutlineScreen.collapsedKey], contains('cat:work'));

      await tester.tap(find.byKey(const ValueKey('outline-collapse-work')));
      await tester.pump();
      expect(find.text('회사 일'), findsOneWidget);
    });

    testWidgets('저장된 접힘 상태로 시작한다 (앱 재시작)', (tester) async {
      prefs.data[OutlineScreen.collapsedKey] = {'cat:work'};
      await mount(
        tester,
        allTodos: [make(id: 'a', title: '회사 일')],
      );
      expect(find.text('회사 일'), findsNothing);
    });

    testWidgets('모두 접기 ↔ 모두 펼치기', (tester) async {
      final w = make(id: 'w', title: '회사 일');
      final d = make(id: 'd', title: '일상 일', category: Category.daily);
      await mount(tester, allTodos: [w, d]);

      await tester.tap(find.byKey(const ValueKey('outline-toggle-all')));
      await tester.pump();
      expect(find.text('회사 일'), findsNothing);
      expect(find.text('일상 일'), findsNothing);
      expect(find.text('모두 펼치기'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('outline-toggle-all')));
      await tester.pump();
      expect(find.text('회사 일'), findsOneWidget);
      expect(find.text('일상 일'), findsOneWidget);
    });
  });

  group('상태 칩', () {
    testWidgets('메모 칩 → 메모만 카테고리별로', (tester) async {
      final t = make(id: 't', title: '할 일');
      final n = make(id: 'n', title: '메모 하나', type: TodoType.note);
      await mount(tester, allTodos: [t, n]);

      await tester.tap(find.byKey(const ValueKey('status-filter-note')));
      await tester.pump();
      expect(find.text('메모 하나'), findsOneWidget);
      expect(find.text('할 일'), findsNothing);
    });

    testWidgets('완료 칩 → 깊은 곳의 완료도 경로와 함께', (tester) async {
      final p = make(id: 'p', title: '넥서스');
      final c = make(
        id: 'c',
        title: '끝난 자식',
        parentId: 'p',
        doneAt: DateTime(2026, 5, 27),
      );
      await mount(tester, allTodos: [p, c]);

      await tester.tap(find.byKey(const ValueKey('status-filter-done')));
      await tester.pump();
      expect(find.text('끝난 자식'), findsOneWidget);
      expect(find.text('넥서스'), findsOneWidget, reason: '경로(breadcrumb)');
      expect(
        find.byKey(const ValueKey('todo-tile-breadcrumb')),
        findsOneWidget,
      );
    });
  });

  group('그룹', () {
    const ga = Group(id: 'ga', label: '업무', colorValue: 0xFF3366FF);
    final cats = [
      Category.work.copyWith(groupId: 'ga'),
      Category.personalDev.copyWith(groupId: 'ga'),
      Category.daily,
    ];

    testWidgets('미분류는 그룹 아래', (tester) async {
      await mount(tester, allTodos: const [], categories: cats, groups: [ga]);
      final groupY = tester
          .getTopLeft(find.byKey(const ValueKey('outline-group-ga')))
          .dy;
      final ungroupedY = tester
          .getTopLeft(find.byKey(const ValueKey('outline-ungrouped-label')))
          .dy;
      expect(ungroupedY, greaterThan(groupY));
    });

    testWidgets('그룹 머리 탭 = 접기', (tester) async {
      await mount(
        tester,
        allTodos: [make(id: 'a', title: '회사 일')],
        categories: cats,
        groups: [ga],
      );
      expect(find.text('회사 일'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('outline-group-ga')));
      await tester.pump();
      expect(find.text('회사 일'), findsNothing);
      expect(
        find.text(Category.daily.label),
        findsOneWidget,
        reason: '미분류는 그대로',
      );
    });

    testWidgets('그룹 칩 → 그 그룹 카테고리만, 그룹 머리 없이', (tester) async {
      await mount(tester, allTodos: const [], categories: cats, groups: [ga]);
      await tester.tap(find.byKey(const ValueKey('group-scope-ga')));
      await tester.pump();

      expect(container.read(groupScopeProvider), 'ga');
      expect(find.byKey(const ValueKey('outline-group-ga')), findsNothing);
      expect(find.text(Category.work.label), findsOneWidget);
      expect(find.text(Category.daily.label), findsNothing);

      // 전체 칩 → 복귀.
      await tester.tap(find.byKey(const ValueKey('group-scope-all')));
      await tester.pump();
      expect(find.text(Category.daily.label), findsOneWidget);
    });

    testWidgets('그룹이 없으면 그룹 칩 줄도 없다', (tester) async {
      await mount(tester, allTodos: const []);
      expect(find.byKey(const ValueKey('group-scope-chips')), findsNothing);
    });
  });

  group('행', () {
    testWidgets('탭 = 상세 (하위가 없어도)', (tester) async {
      await mount(
        tester,
        allTodos: [make(id: 'leaf', title: '잎')],
      );
      await tester.tap(find.text('잎'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetailScreen), findsOneWidget);
    });

    testWidgets('메모는 체크 대신 메모 글리프', (tester) async {
      await mount(
        tester,
        allTodos: [make(id: 'n', title: '메모', type: TodoType.note)],
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('outline-node-n')),
          matching: find.byKey(const ValueKey('todo-tile-note-leading')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('outline-node-n')),
          matching: find.byKey(const ValueKey('todo-tile-check')),
        ),
        findsNothing,
      );
    });

    testWidgets('폰: 길게 누르면 메뉴 시트', (tester) async {
      AppPlatform.debugFormFactorOverride = FormFactor.mobile;
      await mount(
        tester,
        allTodos: [make(id: 'r', title: '보고서')],
      );
      await tester.longPress(find.text('보고서'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('todo-tile-menu-sheet')),
        findsOneWidget,
      );
      expect(find.text('진행중으로'), findsOneWidget);
      expect(find.text('편집'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
    });

    testWidgets('데스크탑: 우클릭 메뉴', (tester) async {
      AppPlatform.debugFormFactorOverride = FormFactor.desktop;
      await mount(
        tester,
        allTodos: [make(id: 'r', title: '보고서')],
      );
      await tester.tap(
        find.text('보고서'),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('진행중으로'), findsOneWidget);
    });
  });
}
