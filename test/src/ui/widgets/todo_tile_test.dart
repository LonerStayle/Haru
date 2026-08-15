import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/ui/widgets/todo_tile.dart';

void main() {
  Todo make({
    String id = 'a',
    String title = '회사 보고',
    Category category = Category.work,
    DateTime? dueAt,
    DateTime? doneAt,
    DateTime? startedAt,
    DateTime? endAt,
    bool isAllDay = false,
    String timeAnchor = 'start',
    TodoType type = TodoType.task,
  }) => Todo(
    id: id,
    title: title,
    category: category,
    dueAt: dueAt,
    doneAt: doneAt,
    startedAt: startedAt,
    createdAt: DateTime.utc(2026, 5, 27, 9),
    updatedAt: DateTime.utc(2026, 5, 27, 9),
    calendarEventId: null,
    type: type,
    endAt: endAt,
    isAllDay: isAllDay,
    timeAnchor: timeAnchor,
  );

  Future<void> mount(
    WidgetTester tester,
    Todo todo, {
    VoidCallback? onToggle,
    VoidCallback? onToggleInProgress,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.mobileLight(),
        home: Scaffold(
          body: TodoTile(
            todo: todo,
            onToggle: onToggle,
            onToggleInProgress: onToggleInProgress,
          ),
        ),
      ),
    );
  }

  testWidgets('task 타입 — 체크 아이콘 표시 (radio_button_unchecked)', (tester) async {
    await mount(tester, make());
    expect(find.byKey(const ValueKey('todo-tile-check')), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    expect(find.byKey(const ValueKey('todo-tile-note-leading')), findsNothing);
  });

  testWidgets('task 체크됨 → check_circle_rounded', (tester) async {
    await mount(tester, make(doneAt: DateTime.utc(2026, 5, 27, 10)));
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });

  testWidgets('task — onToggle 콜백 연결', (tester) async {
    var toggled = 0;
    await mount(tester, make(), onToggle: () => toggled++);
    await tester.tap(find.byKey(const ValueKey('todo-tile-check')));
    await tester.pump();
    expect(toggled, 1);
  });

  group('진행중(세모) 버튼', () {
    testWidgets('onToggleInProgress 배선 시 세모 버튼 노출', (tester) async {
      await mount(tester, make(), onToggleInProgress: () {});
      expect(find.byKey(const ValueKey('todo-tile-progress')), findsOneWidget);
    });

    testWidgets('onToggleInProgress 미배선 시 세모 버튼 미표시', (tester) async {
      await mount(tester, make());
      expect(find.byKey(const ValueKey('todo-tile-progress')), findsNothing);
    });

    testWidgets('세모 버튼 탭 → onToggleInProgress 호출', (tester) async {
      var count = 0;
      await mount(tester, make(), onToggleInProgress: () => count++);
      await tester.tap(find.byKey(const ValueKey('todo-tile-progress')));
      await tester.pump();
      expect(count, 1);
    });

    testWidgets('진행중(startedAt) 이면 "진행중" 라벨 노출', (tester) async {
      await mount(
        tester,
        make(startedAt: DateTime.utc(2026, 5, 27, 10)),
        onToggleInProgress: () {},
      );
      expect(
        find.byKey(const ValueKey('todo-tile-inprogress-label')),
        findsOneWidget,
      );
      expect(find.text('진행중'), findsOneWidget);
    });

    testWidgets('미진행이면 "진행중" 라벨 미표시', (tester) async {
      await mount(tester, make(), onToggleInProgress: () {});
      expect(
        find.byKey(const ValueKey('todo-tile-inprogress-label')),
        findsNothing,
      );
    });

    testWidgets('note 는 콜백 있어도 세모 버튼 미표시', (tester) async {
      await mount(
        tester,
        make(type: TodoType.note, title: '메모'),
        onToggleInProgress: () {},
      );
      expect(find.byKey(const ValueKey('todo-tile-progress')), findsNothing);
    });
  });

  testWidgets('note 타입 — 체크 아이콘 대신 sticky_note 아이콘', (tester) async {
    await mount(tester, make(type: TodoType.note, title: '→ KV 캐싱'));
    expect(
      find.byKey(const ValueKey('todo-tile-note-leading')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.sticky_note_2_outlined), findsOneWidget);
    // 체크 IconButton 자체가 없어야 함.
    expect(find.byKey(const ValueKey('todo-tile-check')), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
  });

  testWidgets('note 타입 — 제목 italic 제거 + "메모" 라벨로 구분 (§13)', (tester) async {
    await mount(tester, make(type: TodoType.note, title: 'memo'));
    // §13 — 한글 italic 무효 → 제목은 normal, 구분은 "메모" 라벨 칩이 담당.
    final text = tester.widget<Text>(find.text('memo'));
    expect(text.style?.fontStyle, isNot(FontStyle.italic));
    expect(find.byKey(const ValueKey('todo-tile-note-label')), findsOneWidget);
    expect(find.text('메모'), findsOneWidget);
  });

  testWidgets('task 타입 — "메모" 라벨 미표시', (tester) async {
    await mount(tester, make(type: TodoType.task));
    expect(find.byKey(const ValueKey('todo-tile-note-label')), findsNothing);
  });

  testWidgets('note 타입 + dueAt 있어도 시간 노출 X (note 는 일정 무관)', (tester) async {
    await mount(
      tester,
      make(type: TodoType.note, dueAt: DateTime(2026, 5, 27, 14, 30)),
    );
    expect(find.text('14:30'), findsNothing);
  });

  testWidgets('하루종일 task — 시간(00:00) 미출력, 날짜만 표시', (tester) async {
    await mount(tester, make(dueAt: DateTime(2026, 5, 27), isAllDay: true));
    expect(find.text('5/27'), findsOneWidget);
    expect(find.text('00:00'), findsNothing);
    expect(find.textContaining('오전'), findsNothing);
  });

  testWidgets('시작시간 task — "시작 M/D HH:mm"', (tester) async {
    await mount(tester, make(dueAt: DateTime(2026, 5, 27, 14, 30)));
    expect(find.text('시작 5/27 14:30'), findsOneWidget);
  });

  testWidgets('기간 task — "M/D ~ M/D"', (tester) async {
    await mount(
      tester,
      make(
        dueAt: DateTime(2026, 5, 27),
        endAt: DateTime(2026, 5, 30),
        isAllDay: true,
      ),
    );
    expect(find.text('5/27 ~ 5/30'), findsOneWidget);
  });

  testWidgets('task — onToggle null 이면 IconButton.onPressed null (disabled)', (
    tester,
  ) async {
    // 일반 task tile 의 onToggle 가 미지정인 경우 IconButton 이 비활성.
    await mount(tester, make());
    final btn = tester.widget<IconButton>(
      find.byKey(const ValueKey('todo-tile-check')),
    );
    expect(btn.onPressed, isNull);
  });

  // 모바일 폭(360dp)에서 세모+체크+⋮ 3버튼이 제목 폭을 다 먹어 제목이 세로로
  // 무한 wrap 되던 문제(대표님 리포트)의 회귀 가드. 데스크탑은 현행 유지.
  group('모바일 압축 레이아웃', () {
    const longTitle = '회사 분기 보고서 초안 작성하고 팀에 공유한 뒤 피드백 반영해서 최종본 만들기';

    tearDown(() => AppPlatform.debugFormFactorOverride = null);

    Future<void> mountNarrow(
      WidgetTester tester,
      Todo todo, {
      int? drillChildCount,
      double width = 360,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.mobileLight(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: TodoTile(
                todo: todo,
                onToggle: () {},
                onToggleInProgress: () {},
                onCopy: () {},
                onEditItem: () {},
                onDelete: () {},
                drillChildCount: drillChildCount,
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('제목은 최대 2줄 + 말줄임', (tester) async {
      AppPlatform.debugFormFactorOverride = FormFactor.mobile;
      await mountNarrow(tester, make(title: longTitle));

      final title = tester.widget<Text>(find.text(longTitle));
      expect(title.maxLines, 2);
      expect(title.overflow, TextOverflow.ellipsis);
    });

    testWidgets('3버튼이 붙어도 제목 폭 180dp 이상 확보', (tester) async {
      AppPlatform.debugFormFactorOverride = FormFactor.mobile;
      await mountNarrow(
        tester,
        make(title: longTitle, dueAt: DateTime(2026, 5, 27, 14, 30)),
      );

      expect(
        tester.getSize(find.text(longTitle)).width,
        greaterThanOrEqualTo(180),
      );
    });

    testWidgets('trailing 버튼 터치 타겟은 36dp', (tester) async {
      AppPlatform.debugFormFactorOverride = FormFactor.mobile;
      await mountNarrow(tester, make());

      expect(
        tester.getSize(find.byKey(const ValueKey('todo-tile-check'))),
        const Size(36, 36),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('todo-tile-progress'))),
        const Size(36, 36),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('todo-tile-menu-a'))),
        const Size(36, 36),
      );
    });

    testWidgets('드릴 배지는 trailing 이 아니라 제목 아래 메타 줄', (tester) async {
      AppPlatform.debugFormFactorOverride = FormFactor.mobile;
      await mountNarrow(tester, make(title: longTitle), drillChildCount: 3);

      final drill = find.byKey(const ValueKey('todo-tile-drill-a'));
      expect(drill, findsOneWidget);
      // 제목 아래로 내려갔는지 — 배지 top 이 제목 top 보다 아래.
      expect(
        tester.getTopLeft(drill).dy,
        greaterThan(tester.getTopLeft(find.text(longTitle)).dy),
      );
    });

    testWidgets('데스크탑도 폭이 넉넉하면 제목 줄 제한 없이 현행 유지', (tester) async {
      AppPlatform.debugFormFactorOverride = FormFactor.desktop;
      await mountNarrow(tester, make(title: longTitle), width: 600);

      final title = tester.widget<Text>(find.text(longTitle));
      expect(title.maxLines, isNull);
      expect(title.overflow, isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('todo-tile-check'))),
        const Size(48, 48),
      );
    });

    testWidgets('데스크탑이라도 폭이 좁으면 압축된다', (tester) async {
      // 실사용 신고: 창을 좁히면 오늘 화면 타일이 글자당 한 줄로 접히고 가로로
      // 넘쳤다. 압축 판단은 플랫폼이 아니라 실제 폭 기준이어야 한다.
      AppPlatform.debugFormFactorOverride = FormFactor.desktop;
      await mountNarrow(tester, make(title: longTitle), width: 360);

      final title = tester.widget<Text>(find.text(longTitle));
      expect(title.maxLines, 2);
      expect(title.overflow, TextOverflow.ellipsis);
    });

    testWidgets('좁은 데스크탑 폭 + 모든 버튼이 붙어도 가로로 넘치지 않는다', (tester) async {
      AppPlatform.debugFormFactorOverride = FormFactor.desktop;
      await mountNarrow(
        tester,
        make(title: longTitle, startedAt: DateTime.utc(2026, 5, 27, 10)),
        drillChildCount: 10,
        width: 320,
      );

      expect(tester.takeException(), isNull);
    });
  });
}
