import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/search/search_screen.dart';

void main() {
  Todo make({
    required String id,
    String title = 't',
    String? description,
    Category? category,
    String? parentId,
    TodoType type = TodoType.task,
  }) => Todo(
    id: id,
    title: title,
    description: description,
    category: category ?? Category.work,
    dueAt: null,
    doneAt: null,
    createdAt: DateTime.utc(2026, 8, 15, 9),
    updatedAt: DateTime.utc(2026, 8, 15, 9),
    calendarEventId: null,
    parentId: parentId,
    type: type,
  );

  Future<void> mount(
    WidgetTester tester, {
    required List<Todo> todos,
    Set<String> archivedCategoryIds = const <String>{},
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allTodosProvider.overrideWith((_) => Stream.value(todos)),
          archivedCategoryIdsProvider.overrideWithValue(archivedCategoryIds),
        ],
        child: const MaterialApp(home: SearchScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('처음 열면 안내 문구 — 아직 검색어가 없다', (tester) async {
    await mount(
      tester,
      todos: [make(id: '1', title: '회의 준비')],
    );

    expect(find.byKey(const ValueKey('search-idle')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-hit-1')), findsNothing);
  });

  testWidgets('제목으로 검색하면 결과가 나온다', (tester) async {
    await mount(
      tester,
      todos: [
        make(id: '1', title: '결제 모듈'),
        make(id: '2', title: '장보기'),
      ],
    );

    await tester.enterText(find.byKey(const ValueKey('search-field')), '결제');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-hit-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-hit-2')), findsNothing);
  });

  testWidgets('메모 내용으로도 검색되고 발췌가 보인다', (tester) async {
    await mount(
      tester,
      todos: [
        make(id: '1', title: '주간 회고', description: '다음 주에는 결제 모듈부터 착수한다'),
      ],
    );

    await tester.enterText(find.byKey(const ValueKey('search-field')), '결제');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-hit-1')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('todo-tile-search-snippet')),
      findsOneWidget,
    );
  });

  testWidgets('결과가 없으면 빈 상태를 보여준다', (tester) async {
    await mount(
      tester,
      todos: [make(id: '1', title: '장보기')],
    );

    await tester.enterText(find.byKey(const ValueKey('search-field')), '결제');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-empty')), findsOneWidget);
  });

  testWidgets('보관된 카테고리의 항목은 검색되지 않는다', (tester) async {
    await mount(
      tester,
      todos: [
        make(id: '1', title: '결제 정리', category: Category.daily),
        make(id: '2', title: '결제 모듈', category: Category.work),
      ],
      archivedCategoryIds: {Category.daily.id},
    );

    await tester.enterText(find.byKey(const ValueKey('search-field')), '결제');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-hit-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-hit-1')), findsNothing);
  });

  testWidgets('지우기 버튼을 누르면 안내 화면으로 돌아온다', (tester) async {
    await mount(
      tester,
      todos: [make(id: '1', title: '결제 모듈')],
    );

    await tester.enterText(find.byKey(const ValueKey('search-field')), '결제');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-hit-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-clear-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-idle')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-hit-1')), findsNothing);
  });

  testWidgets('결과 타일에 소속 경로(breadcrumb)가 붙는다', (tester) async {
    await mount(
      tester,
      todos: [
        make(id: 'r', title: '넥서스'),
        make(id: '1', title: '결제 모듈', parentId: 'r'),
      ],
    );

    await tester.enterText(find.byKey(const ValueKey('search-field')), '결제');
    await tester.pumpAndSettle();

    final breadcrumb = tester.widget<Text>(
      find.byKey(const ValueKey('todo-tile-breadcrumb')),
    );
    expect(breadcrumb.data, '${Category.work.label} › 넥서스');
  });
}
