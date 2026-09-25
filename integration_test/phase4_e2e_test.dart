import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:solo_todo/src/app/app.dart';
import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/search/search_screen.dart';
import 'package:solo_todo/src/features/settings/settings_sheet.dart';
import 'package:solo_todo/src/features/settings/sort_mode_controller.dart';
import 'package:solo_todo/src/ui/widgets/todo_tile.dart';

/// UX 개선 Phase 4 — 실제 기기(안드로이드 에뮬레이터 / macOS)에서 앱 전체를 띄워
/// 핵심 동선을 끝까지 누른다. 데이터는 메모리 DB(실제 계정·서버와 무관).
///
/// 실행:
///   E2E_SHOTS_OUT=<폴더> flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/phase4_e2e_test.dart -d <기기>
class _MemorySort implements SortModePreference {
  TodoSortMode saved = TodoSortMode.manual;
  @override
  Future<TodoSortMode> load() async => saved;
  @override
  Future<void> save(TodoSortMode mode) async => saved = mode;
}

Future<void> _seed(AppDatabase db) async {
  final now = DateTime.now();
  DateTime d(int offset, [int h = 0, int m = 0]) =>
      DateTime(now.year, now.month, now.day + offset, h, m);
  final c = d(-5, 9);
  Todo t(
    String id,
    String title,
    Category cat, {
    DateTime? due,
    DateTime? end,
    bool allDay = true,
    DateTime? done,
    int sort = 0,
    TodoType type = TodoType.task,
    String? desc,
  }) => Todo(
    id: id,
    title: title,
    category: cat,
    dueAt: due,
    endAt: end,
    isAllDay: allDay,
    doneAt: done,
    sortOrder: sort,
    type: type,
    description: desc,
    createdAt: c,
    updatedAt: c,
  );
  await db.groupsDao.upsert(
    const Group(id: 'g-work', label: '업무', colorValue: 0xFF2A66FF),
  );
  await db.categoriesDao.upsert(Category.work.copyWith(groupId: 'g-work'));
  await db.categoriesDao.upsert(
    Category.personalDev.copyWith(groupId: 'g-work'),
  );
  await db.categoriesDao.upsert(Category.idea.copyWith(archived: true));
  for (final todo in [
    t(
      'w1',
      '결제 API 리팩토링 PR 리뷰',
      Category.work,
      due: d(0, 14),
      allDay: false,
      sort: 1,
    ),
    t(
      'w2',
      '주간 스프린트 회의',
      Category.work,
      due: d(0, 15),
      end: d(0, 16),
      allDay: false,
      sort: 2,
    ),
    t('w3', '분기 보고서 초안', Category.work, due: d(0), sort: 3),
    t('w4', '워크숍 준비', Category.work, due: d(1), end: d(3), sort: 4),
    t('p1', '캘린더 드래그 버그 수정', Category.personalDev, due: d(0), sort: 1),
    t('p2', '보고용 스크린샷 정리', Category.personalDev, due: d(2), sort: 2),
    t('d1', '세탁소 옷 찾기', Category.daily, due: d(0), done: d(0, 9), sort: 1),
    t('d2', '치과 예약', Category.daily, due: d(5, 11), allDay: false, sort: 2),
    t('d3', '먼 미래 여행 계획', Category.daily, due: d(40), sort: 3),
    t('u1', '언젠가 읽을 책 목록', Category.daily, sort: 4),
    t(
      'i1',
      '위젯 아이디어',
      Category.idea,
      type: TodoType.note,
      desc: '보관된 카테고리 속 메모',
    ),
  ]) {
    await db.todosDao.upsert(todo);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final shots = <String, String>{};
  tearDownAll(() => binding.reportData = {'shots': shots});

  testWidgets('Phase 4 E2E — 추가·완료·캘린더·검색·설정·보관함', (tester) async {
    final mobile = AppPlatform.isMobile;
    final prefix = mobile ? 'android' : 'macos';
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _seed(db);

    final boundary = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          uiPrefsStoreProvider.overrideWithValue(MemoryUiPrefsStore()),
          sortModePreferenceProvider.overrideWithValue(_MemorySort()),
        ],
        child: RepaintBoundary(key: boundary, child: const SoloTodoApp()),
      ),
    );

    Future<void> settle([int frames = 12]) async {
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> shot(String name) async {
      await settle(6);
      final ro =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final ratio = tester.view.devicePixelRatio.clamp(1.0, 2.0);
      final img = await ro.toImage(pixelRatio: ratio);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      shots['${prefix}_$name'] = base64Encode(bytes!.buffer.asUint8List());
    }

    Future<void> closeTop() async {
      if (mobile) {
        await tester.pageBack();
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      }
      await settle();
    }

    await settle(20);
    expect(find.text('결제 API 리팩토링 PR 리뷰'), findsWidgets);
    await shot('01_today');

    // ── 새 할 일 추가 ─────────────────────────────────────────────
    await tester.tap(
      find.byKey(ValueKey(mobile ? 'add-todo-fab' : 'sidebar-new-todo')),
    );
    await settle();
    expect(find.byType(AddTodoSheet), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      'E2E 새 할 일',
    );
    await settle(3);
    await shot('02_add_sheet');
    await tester.tap(find.text('추가').last);
    await settle(20);
    expect(find.byType(AddTodoSheet), findsNothing);
    expect(find.text('E2E 새 할 일'), findsOneWidget);

    // ── 완료 → 되돌리기 ──────────────────────────────────────────
    final newTile = find.ancestor(
      of: find.text('E2E 새 할 일'),
      matching: find.byType(TodoTile),
    );
    await tester.tap(
      find.descendant(
        of: newTile,
        matching: find.byKey(const ValueKey('todo-tile-check')),
      ),
    );
    await settle(8);
    expect(find.text('되돌리기'), findsOneWidget);
    await shot('03_done_undo');
    await tester.tap(find.text('되돌리기'));
    await settle(12);
    final row = await db.todosDao.watchAll().first;
    expect(row.firstWhere((t) => t.title == 'E2E 새 할 일').isDone, isFalse);

    // ── 캘린더 ───────────────────────────────────────────────────
    await tester.tap(find.text('캘린더').last);
    await settle(20);
    expect(find.byKey(const ValueKey('calendar-grid-pager')), findsOneWidget);
    await shot('04_calendar');

    if (mobile) {
      // 손잡이를 위로 끌면 목록이 화면 전체.
      await tester.drag(
        find.byKey(const ValueKey('calendar-panel-handle')),
        const Offset(0, -200),
      );
      await settle();
      expect(find.byKey(const ValueKey('calendar-grid-pager')), findsNothing);
      await shot('04b_calendar_list_full');
      await tester.drag(
        find.byKey(const ValueKey('calendar-panel-handle')),
        const Offset(0, 200),
      );
      await settle();
    } else {
      // 칩 드래그: 오늘의 "분기 보고서 초안" 을 모레로.
      final chip = find.byKey(const ValueKey('calendar-chip-todo:w3'));
      final now = DateTime.now();
      final target = DateTime(now.year, now.month, now.day + 2);
      final key =
          'calendar-cell-${target.year.toString().padLeft(4, '0')}'
          '${target.month.toString().padLeft(2, '0')}'
          '${target.day.toString().padLeft(2, '0')}';
      if (chip.evaluate().isNotEmpty &&
          find.byKey(ValueKey(key)).evaluate().isNotEmpty) {
        final g = await tester.startGesture(
          tester.getCenter(chip),
          kind: PointerDeviceKind.mouse,
        );
        await g.moveBy(const Offset(0, 20));
        await tester.pump();
        await g.moveTo(tester.getCenter(find.byKey(ValueKey(key))));
        await tester.pump();
        await g.up();
        await settle(10);
        await shot('04b_calendar_chip_drop_undo');
        final moved = (await db.todosDao.getById('w3'))!;
        expect(moved.dueAt, target);
      }
    }

    await tester.tap(find.byKey(const ValueKey('calendar-segment-list')));
    await settle(12);
    await shot('05_timeline');
    await tester.tap(find.byKey(const ValueKey('calendar-segment-grid')));
    await settle();

    // ── 검색 ─────────────────────────────────────────────────────
    if (mobile) {
      await tester.tap(find.byKey(const ValueKey('calendar-overflow-menu')));
      await settle();
      await tester.tap(find.text('검색'));
    } else {
      await tester.tap(find.byKey(const ValueKey('search-button')));
    }
    await settle();
    expect(find.byType(SearchScreen), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('search-field')), '보고');
    await settle();
    expect(find.byKey(const ValueKey('search-result-count')), findsOneWidget);
    await shot('06_search');
    await closeTop();
    expect(find.byType(SearchScreen), findsNothing);

    // ── 설정 · 테마 · 보관함 ───────────────────────────────────────
    await tester.tap(find.text('오늘').last);
    await settle();
    await tester.tap(find.byKey(const ValueKey('settings-button')));
    await settle(10);
    expect(find.byType(SettingsSheet), findsOneWidget);
    await shot('07_settings');
    await tester.tap(find.text('다크'));
    await settle(10);
    await shot('08_settings_dark');
    await tester.tap(find.text('라이트'));
    await settle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('archive-entry')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-list')),
        matching: find.byType(Scrollable),
      ),
    );
    // 스크롤이 막 끝난 항목은 목록 끝에 반쯤 가려져 있을 수 있다 — 가운데를 누르면
    // 대화상자 바깥(배경)을 눌러 닫혀 버린다. 완전히 보이게 맞춘 뒤 누른다.
    await tester.ensureVisible(find.byKey(const ValueKey('archive-entry')));
    await settle(4);
    await tester.tap(find.byKey(const ValueKey('archive-entry')));
    await settle(12);
    expect(find.text('보관함'), findsWidgets);
    await shot('09_archive');
    await tester.pageBack();
    await settle();
    await closeTop();
    expect(find.byType(SettingsSheet), findsNothing);
  });
}
