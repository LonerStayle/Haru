import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/ui/widgets/in_progress_triangle.dart';
import 'package:solo_todo/src/ui/widgets/undone_square.dart';

import '../../../helpers/add_todo_sheet_helpers.dart';

/// 편집 시트의 "상태" 섹션 — □ 미완료 / △ 진행중 / ◯ 완료.
///
/// 고정하는 경계:
///  - 편집 모드에서만 보이고, 현재 상태 칸만 채워진다.
///  - 칩 탭 = 즉시 저장. 단 일반 편집(onUpdate)이 아니라 **순서 보존 콜백**
///    (onStatusChanged) 으로 나간다 — 상태 변경은 목록 타일의 체크·세모 토글과 같은
///    행위라 자리(sortOrder)가 튀면 안 된다.
///  - note 는 상태 개념이 없어 섹션이 사라진다 (시트 안 종류 토글에도 반응).
///  - 즉시 저장한 상태가 닫힘 자동 저장의 옛 스냅샷에 덮이지 않는다.
void main() {
  const undoneKey = ValueKey('status-undone');
  const progressKey = ValueKey('status-inProgress');
  const doneKey = ValueKey('status-done');

  Future<({List<Todo> updates, List<Todo> statusSaves})> mountSheet(
    WidgetTester tester, {
    Todo? initialTodo,
    bool wireStatusCallback = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(700, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final updates = <Todo>[];
    final statusSaves = <Todo>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  key: const ValueKey('open-sheet'),
                  onPressed: () => AddTodoSheet.show(
                    context,
                    initialCategory: Category.work,
                    initialTodo: initialTodo,
                    onSubmit: (_) {},
                    onUpdate: updates.add,
                    onStatusChanged: wireStatusCallback
                        ? statusSaves.add
                        : null,
                  ),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-sheet')));
    await tester.pumpAndSettle();
    await openSheetMore(tester);
    return (updates: updates, statusSaves: statusSaves);
  }

  Todo makeTodo({
    DateTime? doneAt,
    DateTime? startedAt,
    TodoType type = TodoType.task,
  }) => Todo(
    id: 'edit-1',
    title: '상태 바꿀 항목',
    category: Category.work,
    doneAt: doneAt,
    startedAt: startedAt,
    createdAt: DateTime.utc(2026, 8, 20),
    updatedAt: DateTime.utc(2026, 8, 20),
    type: type,
    sortOrder: 7,
  );

  /// 해당 칸의 기호가 "채움"인지 — 세 기호 모두 active 플래그로 채움/외곽선을 가른다.
  bool filled(WidgetTester tester, ValueKey<String> key) {
    if (key == progressKey) {
      return tester
          .widget<InProgressTriangle>(
            find.descendant(
              of: find.byKey(key),
              matching: find.byType(InProgressTriangle),
            ),
          )
          .active;
    }
    if (key == undoneKey) {
      return tester
          .widget<UndoneSquare>(
            find.descendant(
              of: find.byKey(key),
              matching: find.byType(UndoneSquare),
            ),
          )
          .active;
    }
    final icon = tester.widget<Icon>(
      find.descendant(of: find.byKey(key), matching: find.byType(Icon)),
    );
    return icon.icon == Icons.check_circle_rounded;
  }

  Future<void> tapStatus(WidgetTester tester, ValueKey<String> key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  // 시트 밖(화면 최상단) 탭 = modal barrier 탭 → 시트 닫힘 + 자동 저장.
  Future<void> tapBarrier(WidgetTester tester) async {
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  }

  testWidgets('편집 모드 — 상태 섹션 노출 + 현재 상태만 채움', (tester) async {
    await mountSheet(tester, initialTodo: makeTodo());

    expect(find.text('상태'), findsOneWidget);
    expect(find.byKey(undoneKey), findsOneWidget);
    expect(find.byKey(progressKey), findsOneWidget);
    expect(find.byKey(doneKey), findsOneWidget);
    expect(find.text('미완료'), findsOneWidget);
    expect(find.text('진행중'), findsOneWidget);
    expect(find.text('완료'), findsOneWidget);

    expect(filled(tester, undoneKey), isTrue, reason: '미완료 항목 → □ 가 채워짐');
    expect(filled(tester, progressKey), isFalse);
    expect(filled(tester, doneKey), isFalse);
  });

  testWidgets('편집 모드 — 진행중 항목은 △ 가 채워진 채 열린다', (tester) async {
    await mountSheet(
      tester,
      initialTodo: makeTodo(startedAt: DateTime.utc(2026, 8, 25)),
    );

    expect(filled(tester, progressKey), isTrue);
    expect(filled(tester, undoneKey), isFalse);
    expect(filled(tester, doneKey), isFalse);
  });

  testWidgets('△ 탭 → 진행중으로 즉시 저장 (시트는 열린 채)', (tester) async {
    final r = await mountSheet(tester, initialTodo: makeTodo());

    await tapStatus(tester, progressKey);

    expect(find.byType(AddTodoSheet), findsOneWidget, reason: '시트는 닫히지 않는다');
    expect(r.statusSaves, hasLength(1));
    expect(r.updates, isEmpty, reason: '순서를 bump 하는 일반 편집 경로로 새면 안 된다');
    expect(r.statusSaves.single.startedAt, isNotNull);
    expect(r.statusSaves.single.doneAt, isNull);
    expect(r.statusSaves.single.sortOrder, 7, reason: '상태 변경이 순서를 건드리면 안 된다');
    expect(filled(tester, progressKey), isTrue);
  });

  testWidgets('상태 저장 payload 는 입력 중인 제목을 싣지 않는다 (내용 편집은 닫힘 저장 몫)', (
    tester,
  ) async {
    final r = await mountSheet(tester, initialTodo: makeTodo());

    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      '고치는 중',
    );
    await tester.pump();
    await tapStatus(tester, progressKey);

    expect(r.statusSaves.single.title, '상태 바꿀 항목', reason: '저장된 스냅샷 + 상태만');
  });

  testWidgets('onStatusChanged 미연결 시 onUpdate 로 폴백한다 (안전망)', (tester) async {
    final r = await mountSheet(
      tester,
      initialTodo: makeTodo(),
      wireStatusCallback: false,
    );

    await tapStatus(tester, progressKey);

    expect(r.statusSaves, isEmpty);
    expect(r.updates, hasLength(1));
    expect(r.updates.single.startedAt, isNotNull);
  });

  testWidgets('◯ 탭 → 완료로 즉시 저장 (진행중 표식 제거)', (tester) async {
    final r = await mountSheet(
      tester,
      initialTodo: makeTodo(startedAt: DateTime.utc(2026, 8, 25)),
    );

    await tapStatus(tester, doneKey);

    expect(r.statusSaves, hasLength(1));
    expect(r.statusSaves.single.doneAt, isNotNull);
    expect(r.statusSaves.single.startedAt, isNull, reason: '완료 = 진행중 아님');
    expect(filled(tester, doneKey), isTrue);
  });

  testWidgets('□ 탭 → 미완료로 즉시 저장 (둘 다 비움)', (tester) async {
    final r = await mountSheet(
      tester,
      initialTodo: makeTodo(doneAt: DateTime.utc(2026, 8, 26)),
    );

    expect(filled(tester, doneKey), isTrue, reason: '완료 항목으로 열렸는지 먼저 확인');

    await tapStatus(tester, undoneKey);

    expect(r.statusSaves, hasLength(1));
    expect(r.statusSaves.single.doneAt, isNull);
    expect(r.statusSaves.single.startedAt, isNull);
    expect(filled(tester, undoneKey), isTrue);
  });

  testWidgets('같은 칸을 다시 눌러도 저장하지 않는다 (헛저장 방지)', (tester) async {
    final r = await mountSheet(tester, initialTodo: makeTodo());

    await tapStatus(tester, undoneKey);

    expect(r.statusSaves, isEmpty);
    expect(r.updates, isEmpty);
  });

  testWidgets('note 타입 — 상태 섹션이 없다', (tester) async {
    await mountSheet(tester, initialTodo: makeTodo(type: TodoType.note));

    expect(find.text('상태'), findsNothing);
    expect(find.byKey(undoneKey), findsNothing);
  });

  testWidgets('시트 안에서 종류를 메모로 바꾸면 상태 섹션이 사라지고, 할 일로 되돌리면 다시 나온다', (
    tester,
  ) async {
    await mountSheet(tester, initialTodo: makeTodo());
    expect(find.byKey(undoneKey), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('type-note')));
    await tester.pumpAndSettle();
    expect(find.text('상태'), findsNothing);
    expect(find.byKey(undoneKey), findsNothing);

    await tester.tap(find.byKey(const ValueKey('type-task')));
    await tester.pumpAndSettle();
    expect(find.byKey(undoneKey), findsOneWidget);
  });

  testWidgets('신규 추가 모드 — 상태 섹션이 없다', (tester) async {
    await mountSheet(tester);

    expect(find.text('상태'), findsNothing);
    expect(find.byKey(progressKey), findsNothing);
  });

  testWidgets('상태를 바꾸고 시트를 닫아도 옛 스냅샷으로 되돌아가지 않는다', (tester) async {
    final r = await mountSheet(tester, initialTodo: makeTodo());

    await tapStatus(tester, progressKey);
    await tapBarrier(tester);

    expect(find.byType(AddTodoSheet), findsNothing);
    expect(r.statusSaves, hasLength(1), reason: '즉시 저장 (순서 보존 경로)');
    expect(r.updates, hasLength(1), reason: '닫힘 자동 저장 (일반 편집 경로)');
    final closed = r.updates.single;
    expect(closed.startedAt, isNotNull, reason: '닫힘 저장이 진행중을 되돌리면 안 된다');
    expect(closed.doneAt, isNull);
    // 타임스탬프까지 같아야 컨트롤러의 무변경 판정이 서고, 보존된 순서가 다시
    // bump 되지 않는다.
    expect(closed.startedAt, r.statusSaves.single.startedAt);
    expect(closed.sortOrder, 7);
  });

  testWidgets('완료로 바꾸고 닫아도 완료가 유지된다', (tester) async {
    final r = await mountSheet(tester, initialTodo: makeTodo());

    await tapStatus(tester, doneKey);
    await tapBarrier(tester);

    expect(r.updates.single.doneAt, isNotNull);
    expect(r.updates.single.doneAt, r.statusSaves.single.doneAt);
    expect(r.updates.single.startedAt, isNull);
  });
}
