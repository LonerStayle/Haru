import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/ui/widgets/todo_tile.dart';

/// §13-2 — TodoTile note 틴트 배경 + 3px accent 보더 (task 미적용) 검증.
void main() {
  Todo make({
    Category category = Category.work,
    TodoType type = TodoType.task,
    String? description,
  }) => Todo(
    id: 'a',
    title: 't',
    category: category,
    dueAt: null,
    doneAt: null,
    createdAt: DateTime.utc(2026, 5, 27, 9),
    updatedAt: DateTime.utc(2026, 5, 27, 9),
    calendarEventId: null,
    type: type,
    description: description,
  );

  Future<void> mount(
    WidgetTester tester,
    Todo todo, {
    Brightness brightness = Brightness.light,
    int childCount = 0,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.mobileDark()
            : AppTheme.mobileLight(),
        home: Scaffold(
          body: TodoTile(todo: todo, childCount: childCount),
        ),
      ),
    );
  }

  Card card(WidgetTester tester) =>
      tester.widget<Card>(find.byType(Card).first);
  Container colorbar(WidgetTester tester) => tester.widget<Container>(
    find.byKey(const ValueKey('todo-tile-colorbar')),
  );

  testWidgets('note(light) — Card 배경이 카테고리 틴트', (tester) async {
    await mount(tester, make(type: TodoType.note));
    expect(
      card(tester).color,
      NoteVisual.tint(Category.work, Brightness.light),
    );
  });

  testWidgets('note(dark) — Card 배경이 다크 틴트(더 진함)', (tester) async {
    await mount(tester, make(type: TodoType.note), brightness: Brightness.dark);
    expect(card(tester).color, NoteVisual.tint(Category.work, Brightness.dark));
  });

  testWidgets('note — 좌측 컬러바가 3px accent 보더로 대체', (tester) async {
    await mount(tester, make(type: TodoType.note, category: Category.idea));
    final bar = colorbar(tester);
    expect(bar.constraints?.maxWidth, NoteVisual.accentWidth);
    expect(
      (bar.decoration as BoxDecoration).color,
      NoteVisual.accent(Category.idea),
    );
  });

  testWidgets('task — Card 기본 surface(null) + 3px 카테고리 컬러바 (Phase 1)', (
    tester,
  ) async {
    await mount(tester, make(type: TodoType.task, category: Category.daily));
    expect(card(tester).color, isNull);
    final bar = colorbar(tester);
    expect(bar.constraints?.maxWidth, 3);
    expect((bar.decoration as BoxDecoration).color, Category.daily.color);
  });

  testWidgets('note + description — 본문 2줄 프리뷰 노출(힌트 아이콘 대신)', (tester) async {
    await mount(
      tester,
      make(type: TodoType.note, description: 'KV 캐싱 설계 메모 본문'),
    );
    final preview = tester.widget<Text>(
      find.byKey(const ValueKey('todo-tile-note-preview')),
    );
    expect(preview.data, 'KV 캐싱 설계 메모 본문');
    expect(preview.maxLines, 2);
    expect(preview.overflow, TextOverflow.ellipsis);
    // note 는 힌트 아이콘 대신 프리뷰 → 힌트 아이콘 미표시.
    expect(
      find.byKey(const ValueKey('todo-tile-description-hint')),
      findsNothing,
    );
  });

  testWidgets('note + 빈/공백 description — 프리뷰 생략', (tester) async {
    await mount(tester, make(type: TodoType.note, description: '   '));
    expect(find.byKey(const ValueKey('todo-tile-note-preview')), findsNothing);
  });

  testWidgets('task + description — 힌트 아이콘 유지, 프리뷰 미노출', (tester) async {
    await mount(tester, make(type: TodoType.task, description: '태스크 상세 메모'));
    expect(
      find.byKey(const ValueKey('todo-tile-description-hint')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('todo-tile-note-preview')), findsNothing);
  });

  testWidgets('note — leading 메모 글리프(카테고리색) + trailing 체크 부재', (tester) async {
    await mount(tester, make(type: TodoType.note, category: Category.longterm));
    final glyph = tester.widget<Icon>(
      find.byKey(const ValueKey('todo-tile-note-leading')),
    );
    expect(glyph.icon, Icons.sticky_note_2_outlined);
    expect(glyph.color, Category.longterm.color);
    // 체크 affordance 가 어디에도 없어야 한다.
    expect(find.byKey(const ValueKey('todo-tile-check')), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
  });

  testWidgets('task — leading 메모 글리프 없음 + trailing 체크 존재', (tester) async {
    await mount(tester, make(type: TodoType.task));
    expect(find.byKey(const ValueKey('todo-tile-note-leading')), findsNothing);
    expect(find.byKey(const ValueKey('todo-tile-check')), findsOneWidget);
  });

  testWidgets('task 미완료 체크 — 카테고리색 ring(0.55) 대비 강화', (tester) async {
    await mount(tester, make(type: TodoType.task, category: Category.work));
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('todo-tile-check')),
        matching: find.byType(Icon),
      ),
    );
    expect(icon.icon, Icons.radio_button_unchecked);
    expect(icon.color, Category.work.color.withValues(alpha: 0.55));
  });

  testWidgets('note 헤딩(자식≥1) — 진한 headingTint 배경 + 굵은 제목', (tester) async {
    await mount(
      tester,
      make(type: TodoType.note, category: Category.work),
      childCount: 2,
    );
    expect(
      card(tester).color,
      NoteVisual.headingTint(Category.work, Brightness.light),
    );
    final title = tester.widget<Text>(find.text('t'));
    expect(title.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('note leaf(자식 0) — 연한 tint 배경 + 굵지 않은 제목', (tester) async {
    await mount(
      tester,
      make(type: TodoType.note, category: Category.work),
      childCount: 0,
    );
    expect(
      card(tester).color,
      NoteVisual.tint(Category.work, Brightness.light),
    );
    final title = tester.widget<Text>(find.text('t'));
    expect(title.style?.fontWeight, isNot(FontWeight.w700));
  });

  testWidgets('task 완료 체크 — 카테고리색 원색', (tester) async {
    await mount(
      tester,
      Todo(
        id: 'a',
        title: 't',
        category: Category.work,
        dueAt: null,
        doneAt: DateTime.utc(2026, 5, 27, 10),
        createdAt: DateTime.utc(2026, 5, 27, 9),
        updatedAt: DateTime.utc(2026, 5, 27, 9),
        calendarEventId: null,
      ),
    );
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('todo-tile-check')),
        matching: find.byType(Icon),
      ),
    );
    expect(icon.icon, Icons.check_circle_rounded);
    expect(icon.color, Category.work.color);
  });
}
