import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/outline/outline_screen.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';

void main() {
  Todo make({
    required String id,
    String title = 't',
    Category category = Category.work,
    String? parentId,
    TodoType type = TodoType.task,
    DateTime? doneAt,
    String? description,
  }) => Todo(
    id: id,
    title: title,
    description: description,
    category: category,
    dueAt: null,
    doneAt: doneAt,
    createdAt: DateTime.utc(2026, 5, 27, 9),
    updatedAt: DateTime.utc(2026, 5, 27, 9),
    calendarEventId: null,
    parentId: parentId,
    type: type,
  );

  /// OutlineScreen 을 in-memory override 로 mount.
  ///
  /// [rootsByCategory] : 각 카테고리의 root todos (task + note 섞임 가능).
  /// [childrenByParent] : 각 parentId → 자식 list.
  /// [allTodos] : computeSubtreeProgress walk + 메모 탭 note 필터의 출처.
  ///
  /// 파생 provider (taskRootsOf / childTasksOf / notesOfCategory) 는 base provider
  /// 의 stream override 를 그대로 받아 in-memory 필터링하므로 별도 override 불필요.
  Future<void> mount(
    WidgetTester tester, {
    required Map<Category, List<Todo>> rootsByCategory,
    Map<String, List<Todo>> childrenByParent = const {},
    required List<Todo> allTodos,
    List<Category>? categories,
    List<Group> groups = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allTodosProvider.overrideWith((_) => Stream.value(allTodos)),
          rootsOfCategoryProvider.overrideWith(
            (_, cat) => Stream.value(rootsByCategory[cat] ?? const <Todo>[]),
          ),
          childrenOfProvider.overrideWith(
            (_, parentId) =>
                Stream.value(childrenByParent[parentId] ?? const <Todo>[]),
          ),
          categoriesProvider.overrideWith(
            (_) => Stream.value(categories ?? Category.builtinSeeds),
          ),
          // 작업 3 (L) — 그룹 계층. 기본은 빈 목록(= 그룹 헤더 없는 평면).
          groupsProvider.overrideWith((_) => Stream.value(groups)),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const Scaffold(body: OutlineScreen()),
        ),
      ),
    );
    // stream emit 흐름 확보 — 손자까지 watch 가 도착하려면 depth 만큼 frame 필요.
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  /// 메모 탭으로 전환 (default 는 체크리스트 탭). 탭 전환 애니메이션 + stream emit
  /// 완료까지 settle.
  Future<void> openNotesTab(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(Tab, '메모'));
    await tester.pumpAndSettle();
  }

  group('탭 구조', () {
    testWidgets('빈 트리 — 체크리스트 없는 카테고리는 모두 숨김 + 안내 노출', (tester) async {
      await mount(tester, rootsByCategory: const {}, allTodos: const []);

      expect(find.text('전체보기'), findsOneWidget);
      expect(find.text('체크리스트'), findsOneWidget);
      expect(find.text('메모'), findsOneWidget);
      // task root 가 없는 카테고리 헤더는 더 이상 노출되지 않는다 (메모만/빈 카테고리 숨김).
      for (final c in Category.values) {
        expect(find.text(c.label), findsNothing);
      }
      // 대신 빈 안내가 노출.
      expect(find.text('체크리스트가 없어요'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^\d+/\d+$')), findsNothing);
    });
  });

  group('체크리스트 탭 (task 트리)', () {
    testWidgets('카테고리에 task root 2건 (1 done) → 헤더 1/2 + 완료는 접기 행 아래로', (
      tester,
    ) async {
      final root1 = make(id: 'r1', title: '캔버스 첨부 오류');
      final root2Done = make(
        id: 'r2',
        title: '오타 수정',
        doneAt: DateTime(2026, 5, 27, 10),
      );
      await mount(
        tester,
        rootsByCategory: {
          Category.work: [root1, root2Done],
        },
        allTodos: [root1, root2Done],
      );

      // 진척 배지는 완료 포함 그대로 (allTodos 기반).
      expect(find.text('1/2'), findsOneWidget);
      // 미완료 root 는 노출.
      expect(find.text('캔버스 첨부 오류'), findsOneWidget);
      // 완료 root 는 기본 접힘 — "완료 1개" 행 아래로 숨는다.
      expect(find.text('오타 수정'), findsNothing);
      expect(find.text('완료 1개'), findsOneWidget);

      // 완료 접기 행 탭 → 완료 root 노출.
      await tester.tap(find.byKey(const ValueKey('outline-done-toggle-work')));
      await tester.pump();
      expect(find.text('오타 수정'), findsOneWidget);
    });

    testWidgets('완료 root 가 없으면 "완료 N개" 접기 행이 없다', (tester) async {
      final root1 = make(id: 'r1', title: '미완료 A');
      final root2 = make(id: 'r2', title: '미완료 B');
      await mount(
        tester,
        rootsByCategory: {
          Category.work: [root1, root2],
        },
        allTodos: [root1, root2],
      );

      expect(find.text('미완료 A'), findsOneWidget);
      expect(find.text('미완료 B'), findsOneWidget);
      // 완료가 하나도 없으면 접기 행 미표시.
      expect(
        find.byKey(const ValueKey('outline-done-toggle-work')),
        findsNothing,
      );
    });

    testWidgets('완료 접기 행 왕복 — 펼쳤다 다시 접으면 완료가 숨는다', (tester) async {
      final active = make(id: 'a', title: '진행중');
      final done = make(
        id: 'd',
        title: '끝난 일',
        doneAt: DateTime(2026, 5, 27, 10),
      );
      await mount(
        tester,
        rootsByCategory: {
          Category.work: [active, done],
        },
        allTodos: [active, done],
      );

      final toggle = find.byKey(const ValueKey('outline-done-toggle-work'));
      // 기본 접힘.
      expect(find.text('끝난 일'), findsNothing);
      // 펼침.
      await tester.tap(toggle);
      await tester.pump();
      expect(find.text('끝난 일'), findsOneWidget);
      // 다시 접힘.
      await tester.tap(toggle);
      await tester.pump();
      expect(find.text('끝난 일'), findsNothing);
      // 진행중 root 는 항상 노출.
      expect(find.text('진행중'), findsOneWidget);
    });

    testWidgets('체크 circle — 미완료 ring 카테고리색(0.55), 완료 채움 (TodoTile 일관)', (
      tester,
    ) async {
      final undone = make(id: 'u', title: '미완료', category: Category.work);
      final done = make(
        id: 'd',
        title: '완료',
        category: Category.work,
        doneAt: DateTime(2026, 5, 27, 10),
      );
      await mount(
        tester,
        rootsByCategory: {
          Category.work: [undone, done],
        },
        allTodos: [undone, done],
      );

      // 완료 root 는 기본 접힘 — 체크 circle 비교 위해 완료 섹션을 펼친다.
      await tester.tap(find.byKey(const ValueKey('outline-done-toggle-work')));
      await tester.pump();

      BoxDecoration circleDeco(String id) {
        final container = tester.widget<AnimatedContainer>(
          find.descendant(
            of: find.byKey(ValueKey('outline-check-$id')),
            matching: find.byType(AnimatedContainer),
          ),
        );
        return container.decoration! as BoxDecoration;
      }

      // 미완료 — 투명 채움 + 카테고리색 0.55 ring.
      final u = circleDeco('u');
      expect(u.color, Colors.transparent);
      expect(
        (u.border! as Border).top.color,
        Category.work.color.withValues(alpha: 0.55),
      );
      // 완료 — 카테고리색 채움 + 동일 색 ring.
      final d = circleDeco('d');
      expect(d.color, Category.work.color);
      expect((d.border! as Border).top.color, Category.work.color);
    });

    testWidgets('펼침 → 접힘 토글 — 카테고리 row tap 시 자식 root 들 사라짐', (tester) async {
      final root = make(id: 'r', title: '회사 root');
      await mount(
        tester,
        rootsByCategory: {
          Category.work: [root],
        },
        allTodos: [root],
      );

      expect(find.text('회사 root'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('outline-category-work')));
      await tester.pump();
      expect(find.text('회사 root'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('outline-category-work')));
      await tester.pump();
      expect(find.text('회사 root'), findsOneWidget);
    });

    testWidgets('folder 노드 — 자식 인라인 비노출 / [done/total] 누적 / 탭 시 상세로 드릴다운', (
      tester,
    ) async {
      final nexus = make(id: 'nexus', title: '넥서스');
      final child1 = make(id: 'c1', title: '캔버스 첨부 오류', parentId: 'nexus');
      final child2Done = make(
        id: 'c2',
        title: 'narrative 에러',
        parentId: 'nexus',
        doneAt: DateTime(2026, 5, 27, 10),
      );

      await mount(
        tester,
        rootsByCategory: {
          Category.work: [nexus],
        },
        childrenByParent: {
          'nexus': [child1, child2Done],
        },
        allTodos: [nexus, child1, child2Done],
      );

      expect(find.text('넥서스'), findsOneWidget);
      // 자식은 인라인으로 펼쳐지지 않는다 (상세 화면에서만 노출).
      expect(find.text('캔버스 첨부 오류'), findsNothing);
      expect(find.text('narrative 에러'), findsNothing);

      // 진척률은 subtree 누적으로 그대로 계산 (인라인 노출과 무관).
      expect(find.text('1/3'), findsAtLeastNWidgets(1), reason: '카테고리 누적 진척률');
      expect(find.text('1/2'), findsAtLeastNWidgets(1));

      // 노드 탭 → 상세 화면 진입. 자식 체크리스트는 거기서 드릴다운으로 노출.
      await tester.tap(find.byKey(const ValueKey('outline-node-nexus')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('detail-toggle')),
        findsOneWidget,
        reason: '상세 화면 진입',
      );
      expect(find.text('캔버스 첨부 오류'), findsOneWidget);
      expect(find.text('narrative 에러'), findsOneWidget);
    });

    testWidgets('note root 는 체크리스트 탭에서 제외 — task 만 진척률 1/1', (tester) async {
      final task = make(
        id: 't',
        title: '체크할 일',
        doneAt: DateTime(2026, 5, 27, 10),
      );
      final note1 = make(id: 'n1', title: '메모1', type: TodoType.note);
      final note2 = make(id: 'n2', title: '메모2', type: TodoType.note);

      await mount(
        tester,
        rootsByCategory: {
          Category.work: [task, note1, note2],
        },
        allTodos: [task, note1, note2],
      );

      // 체크리스트 탭(default) 에는 note 가 보이지 않는다. task 는 완료라 기본 접힘.
      expect(find.text('메모1'), findsNothing);
      expect(find.text('메모2'), findsNothing);
      // 진척 배지 1/1 은 헤더라 접힘과 무관하게 노출.
      expect(find.text('1/1'), findsOneWidget);
      expect(find.text('완료 1개'), findsOneWidget);
      // 완료 섹션 펼치면 task 노출 (note 는 여전히 제외).
      await tester.tap(find.byKey(const ValueKey('outline-done-toggle-work')));
      await tester.pump();
      expect(find.text('체크할 일'), findsOneWidget);
      expect(find.text('메모1'), findsNothing);
      expect(find.text('메모2'), findsNothing);
    });

    testWidgets('note 자식은 진척률 카운트에서 제외 (task 자식만) — 자식은 인라인 비노출', (
      tester,
    ) async {
      final parent = make(id: 'p', title: '부모 할 일');
      final childTask = make(id: 'c1', title: '자식 할 일', parentId: 'p');
      final childNote = make(
        id: 'c2',
        title: '자식 메모',
        parentId: 'p',
        type: TodoType.note,
      );
      await mount(
        tester,
        rootsByCategory: {
          Category.work: [parent],
        },
        childrenByParent: {
          'p': [childTask, childNote],
        },
        allTodos: [parent, childTask, childNote],
      );

      expect(find.text('부모 할 일'), findsOneWidget);
      // 자식(task/note)은 인라인으로 펼쳐지지 않는다 (상세 화면에서만).
      expect(find.text('자식 할 일'), findsNothing);
      expect(find.text('자식 메모'), findsNothing);
      // 진척률은 task 자식만 카운트 (note 제외) → 부모 + task 자식 = 0/2.
      expect(find.text('0/2'), findsAtLeastNWidgets(1));
      // 부모 task 체크 토글은 그대로 존재 & 동작.
      expect(find.byKey(const ValueKey('outline-check-p')), findsOneWidget);
      final parentCheck = tester.widget<InkWell>(
        find.byKey(const ValueKey('outline-check-p')),
      );
      expect(parentCheck.onTap, isNotNull);
    });

    testWidgets('자식 없는 leaf 노드 — chevron 없음 + 탭 시 편집 바텀시트', (tester) async {
      final leaf = make(id: 'leaf', title: '단독 task');
      await mount(
        tester,
        rootsByCategory: {
          Category.work: [leaf],
        },
        allTodos: [leaf],
      );

      final node = tester.widget<InkWell>(
        find.byKey(const ValueKey('outline-node-leaf')),
      );
      expect(node.onTap, isNotNull, reason: 'leaf 도 탭하면 편집 시트가 열림');
      // 상세 드릴다운 chevron 은 leaf 에 노출되지 않는다 (자식 없음).
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('outline-node-leaf')),
          matching: find.byIcon(Icons.chevron_right_rounded),
        ),
        findsNothing,
      );

      // 탭 → 편집 바텀시트(AddTodoSheet) 노출.
      await tester.tap(find.byKey(const ValueKey('outline-node-leaf')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-todo-title')), findsOneWidget);
    });
  });

  group('메모 탭 (note 평탄 목록)', () {
    testWidgets('메모 탭에는 note 만, task 는 안 보임', (tester) async {
      final task = make(id: 't', title: '체크할 일');
      final note1 = make(
        id: 'n1',
        title: '메모1',
        type: TodoType.note,
        description: '메모 본문',
      );
      final note2 = make(id: 'n2', title: '메모2', type: TodoType.note);

      await mount(
        tester,
        rootsByCategory: {
          Category.work: [task, note1, note2],
        },
        allTodos: [task, note1, note2],
      );

      await openNotesTab(tester);

      // note 카드 노출.
      expect(find.byKey(const ValueKey('outline-note-n1')), findsOneWidget);
      expect(find.byKey(const ValueKey('outline-note-n2')), findsOneWidget);
      expect(find.text('메모1'), findsOneWidget);
      expect(find.text('메모2'), findsOneWidget);
      expect(find.text('메모 본문'), findsOneWidget);
      // task 는 메모 탭에 없음.
      expect(find.text('체크할 일'), findsNothing);
      // 메모는 체크 토글 없음.
      expect(find.byKey(const ValueKey('outline-check-t')), findsNothing);
    });

    testWidgets('메모 카드 탭 → 편집/상세 시트(AddTodoSheet) 노출', (tester) async {
      final note = make(
        id: 'n1',
        title: '메모1',
        type: TodoType.note,
        description: '메모 본문',
      );
      await mount(
        tester,
        rootsByCategory: {
          Category.work: [note],
        },
        allTodos: [note],
      );

      await openNotesTab(tester);

      // 탭 → 편집/상세 바텀시트(AddTodoSheet) 노출 (체크리스트 leaf 와 동일 패턴).
      await tester.tap(find.byKey(const ValueKey('outline-note-n1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-todo-title')), findsOneWidget);
    });

    testWidgets('_NoteCard 가 NoteVisual 토큰으로 통일 (틴트+accent, non-italic)', (
      tester,
    ) async {
      final note = make(
        id: 'n1',
        title: '메모1',
        category: Category.idea,
        type: TodoType.note,
      );
      await mount(
        tester,
        rootsByCategory: {
          Category.idea: [note],
        },
        allTodos: [note],
      );
      await openNotesTab(tester);

      final box = tester.widget<Container>(
        find.byKey(const ValueKey('outline-note-n1')),
      );
      final deco = box.decoration! as BoxDecoration;
      // 틴트 배경 = NoteVisual (라이트).
      expect(deco.color, NoteVisual.tint(Category.idea, Brightness.light));
      // 좌측 accent 보더 = NoteVisual 두께/색.
      final left = (deco.border! as Border).left;
      expect(left.width, NoteVisual.accentWidth);
      expect(left.color, NoteVisual.accent(Category.idea));
      // 제목 italic 제거 (TodoTile note 와 일관).
      final title = tester.widget<Text>(find.text('메모1'));
      expect(title.style?.fontStyle, isNot(FontStyle.italic));
    });

    testWidgets('note 가 트리 깊이와 무관하게 평탄 나열 (자식 note 포함)', (tester) async {
      // task root > note 자식 — 메모 탭은 트리 무관하게 카테고리의 모든 note 를 나열.
      final root = make(id: 'r', title: '루트 task');
      final childNote = make(
        id: 'cn',
        title: '깊은 메모',
        parentId: 'r',
        type: TodoType.note,
      );

      await mount(
        tester,
        rootsByCategory: {
          Category.work: [root],
        },
        childrenByParent: {
          'r': [childNote],
        },
        allTodos: [root, childNote],
      );

      await openNotesTab(tester);

      expect(find.byKey(const ValueKey('outline-note-cn')), findsOneWidget);
      expect(find.text('깊은 메모'), findsOneWidget);
    });

    testWidgets('note 없는 카테고리 섹션은 hide — note 있는 카테고리만 노출', (tester) async {
      final note = make(
        id: 'n',
        title: '개인 메모',
        category: Category.personalDev,
        type: TodoType.note,
      );

      await mount(
        tester,
        rootsByCategory: {
          Category.personalDev: [note],
        },
        allTodos: [note],
      );

      await openNotesTab(tester);

      // note 있는 카테고리(개인개발) 섹션만, 나머지 카테고리 섹션은 hide.
      // (체크리스트 탭은 keepAlive 로 offstage 잔존하므로 라벨 텍스트가 아니라
      //  메모 탭 전용 섹션 키로 확인.)
      expect(
        find.byKey(ValueKey('outline-note-section-${Category.personalDev.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('outline-note-section-${Category.work.id}')),
        findsNothing,
      );
      expect(find.text('개인 메모'), findsOneWidget);
    });
  });

  group('작업 3 (L) — 그룹 계층', () {
    const groupA = Group(
      id: 'ga',
      label: '업무 큰분류',
      colorValue: 0xFF2A66FF,
      sortOrder: 0,
    );
    const catInGroup = Category(
      id: 'work',
      label: '회사 할일',
      iconCodePoint: 0xef0a,
      colorValue: 0xFF2A66FF,
      sortOrder: 0,
      isBuiltin: true,
      groupId: 'ga',
    );
    const catUngrouped = Category(
      id: 'daily',
      label: '일상',
      iconCodePoint: 0xf107,
      colorValue: 0xFF10B981,
      sortOrder: 2,
      isBuiltin: true,
    );

    testWidgets('그룹 헤더 + 미분류 섹션 노출 + 그룹 안 카테고리', (tester) async {
      final root = make(id: 'r', title: '그룹 안 할 일', category: catInGroup);
      final ungroupedRoot = make(
        id: 'ur',
        title: '일상 할 일',
        category: catUngrouped,
      );
      await mount(
        tester,
        categories: const [catInGroup, catUngrouped],
        groups: const [groupA],
        rootsByCategory: {
          catInGroup: [root],
          catUngrouped: [ungroupedRoot],
        },
        allTodos: [root, ungroupedRoot],
      );

      // 그룹 헤더 + 미분류 라벨 동시 노출.
      expect(find.byKey(const ValueKey('outline-group-ga')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('outline-ungrouped-label')),
        findsOneWidget,
      );
      expect(find.text('업무 큰분류'), findsOneWidget);
      // 그룹 안 카테고리 + 그 root.
      expect(find.text('회사 할일'), findsOneWidget);
      expect(find.text('그룹 안 할 일'), findsOneWidget);
      // 미분류 카테고리 (체크리스트 보유 → 노출).
      expect(find.text('일상'), findsOneWidget);
      expect(find.text('일상 할 일'), findsOneWidget);
    });

    testWidgets('그룹 헤더 접으면 그 그룹의 카테고리/할 일이 사라짐', (tester) async {
      final root = make(id: 'r', title: '그룹 안 할 일', category: catInGroup);
      final ungroupedRoot = make(
        id: 'ur',
        title: '일상 할 일',
        category: catUngrouped,
      );
      await mount(
        tester,
        categories: const [catInGroup, catUngrouped],
        groups: const [groupA],
        rootsByCategory: {
          catInGroup: [root],
          catUngrouped: [ungroupedRoot],
        },
        allTodos: [root, ungroupedRoot],
      );

      expect(find.text('회사 할일'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('outline-group-ga')));
      await tester.pump();

      // 그룹 헤더는 남고 그 안 카테고리는 사라짐. 미분류는 유지.
      expect(find.byKey(const ValueKey('outline-group-ga')), findsOneWidget);
      expect(find.text('회사 할일'), findsNothing);
      expect(find.text('그룹 안 할 일'), findsNothing);
      expect(find.text('일상'), findsOneWidget);
    });

    testWidgets('그룹이 없으면 그룹 헤더/미분류 라벨 없이 평면 (기존 모양)', (tester) async {
      // 각 builtin 카테고리에 task root 1건씩 — 체크리스트 보유 카테고리만 노출되므로
      // 평면 모양을 검증하려면 모두 task 를 가져야 한다.
      final roots = <Category, List<Todo>>{
        for (final c in Category.values)
          c: [make(id: 'root-${c.id}', title: '${c.label} 할 일', category: c)],
      };
      await mount(
        tester,
        rootsByCategory: roots,
        allTodos: [for (final list in roots.values) ...list],
      );

      expect(
        find.byKey(const ValueKey('outline-ungrouped-label')),
        findsNothing,
      );
      for (final c in Category.values) {
        expect(find.text(c.label), findsOneWidget);
      }
    });
  });

  group('§14 — note 헤딩(task 자손 보유) 체크리스트 통합', () {
    testWidgets('note 헤딩이 체크리스트 탭에 섹션으로 노출 (글리프 + task 자식)', (tester) async {
      final heading = make(id: 'h', title: '코기토 인프라', type: TodoType.note);
      final taskChild = make(id: 'tc', title: '서버 세팅', parentId: 'h');
      await mount(
        tester,
        rootsByCategory: {
          Category.work: [heading],
        },
        childrenByParent: {
          'h': [taskChild],
        },
        allTodos: [heading, taskChild],
      );

      // 체크리스트 탭(default) — note 헤딩 노드 + 메모 글리프(체크박스 아님).
      expect(find.byKey(const ValueKey('outline-node-h')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('outline-note-glyph-h')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('outline-check-h')), findsNothing);
      expect(find.text('코기토 인프라'), findsOneWidget);
      // task 자식은 인라인 비노출 — 헤딩 탭 시 상세 화면에서 드릴다운으로 노출.
      expect(find.text('서버 세팅'), findsNothing);
      expect(find.byKey(const ValueKey('outline-check-tc')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('outline-node-h')));
      await tester.pumpAndSettle();
      expect(find.text('서버 세팅'), findsOneWidget, reason: '상세 화면 드릴다운');
    });

    testWidgets('note 헤딩은 메모 탭에서 제외 (task 자손 보유 → 체크리스트로)', (tester) async {
      final heading = make(id: 'h', title: '코기토 인프라', type: TodoType.note);
      final taskChild = make(id: 'tc', title: '서버 세팅', parentId: 'h');
      final pureMemo = make(id: 'm', title: '순수 메모', type: TodoType.note);
      await mount(
        tester,
        rootsByCategory: {
          Category.work: [heading, pureMemo],
        },
        childrenByParent: {
          'h': [taskChild],
        },
        allTodos: [heading, taskChild, pureMemo],
      );

      await openNotesTab(tester);

      // 순수 메모만 메모 탭에. 헤딩(task 자손 보유)은 제외.
      expect(find.byKey(const ValueKey('outline-note-m')), findsOneWidget);
      expect(find.byKey(const ValueKey('outline-note-h')), findsNothing);
    });
  });
}
