// ignore_for_file: invalid_use_of_visible_for_testing_member
// UX 리뷰용 화면 캡처 스크립트 — test/_ux_snapshot_test.dart 로 복사해 실행 후 삭제 (커밋 금지).
// 사용법: docs/ux-review/tools/README.md
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/search/search_screen.dart';
import 'package:solo_todo/src/features/settings/settings_sheet.dart';
import 'package:solo_todo/src/features/todo_detail/todo_detail_screen.dart';
import 'package:solo_todo/src/ui/app_shell.dart';

/// 캡처 결과 폴더. 환경변수 UX_SHOTS_OUT 으로 바꿀 수 있다.
final _out = Platform.environment['UX_SHOTS_OUT'] ?? '/tmp/haru_ux_shots';

Future<void> _loadFonts() async {
  final gothic = File(
    '/System/Library/Fonts/Supplemental/AppleGothic.ttf',
  ).readAsBytesSync();
  for (final fam in [
    'Roboto',
    '.AppleSystemUIFont',
    '.SF Pro Text',
    'FlutterTest',
  ]) {
    final l = FontLoader(fam)
      ..addFont(Future.value(ByteData.view(gothic.buffer)));
    await l.load();
  }
  final icons = File(
    '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytesSync();
  final il = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.view(icons.buffer)));
  await il.load();
}

final _now = DateTime(2026, 9, 24, 10, 30);
DateTime _d(int dayOffset, [int h = 0, int m = 0]) =>
    DateTime(2026, 9, 24 + dayOffset, h, m);

List<Todo> _seed() {
  final c = DateTime(2026, 9, 20, 9);
  Todo t(
    String id,
    String title,
    Category cat, {
    DateTime? due,
    DateTime? end,
    bool allDay = true,
    DateTime? done,
    DateTime? started,
    String? parent,
    TodoType type = TodoType.task,
    String? desc,
    int sort = 0,
    String? rule,
  }) => Todo(
    id: id,
    title: title,
    category: cat,
    dueAt: due,
    endAt: end,
    isAllDay: allDay,
    doneAt: done,
    startedAt: started,
    parentId: parent,
    type: type,
    description: desc,
    sortOrder: sort,
    createdAt: c,
    updatedAt: c,
    recurrenceRule: rule,
    seriesId: rule == null ? null : 'series-$id',
    isSeriesMaster: rule != null,
  );
  return [
    t(
      'w1',
      '결제 API 리팩토링 PR 리뷰',
      Category.work,
      due: _d(0, 14, 0),
      allDay: false,
      started: c,
      sort: 1,
      desc: '팀원 PR 2건. 결제 모듈 에러 핸들링 부분 집중해서 볼 것.',
    ),
    t('w1a', '에러 코드 매핑 테이블 확인', Category.work, parent: 'w1', sort: 1),
    t('w1b', '재시도 로직 단위 테스트 추가 요청', Category.work, parent: 'w1', sort: 2),
    t(
      'w2',
      '주간 스프린트 회의',
      Category.work,
      due: _d(0, 15, 0),
      end: _d(0, 16, 0),
      allDay: false,
      sort: 2,
    ),
    t('w3', '배포 체크리스트 작성', Category.work, due: _d(0), sort: 3, done: _now),
    t('w4', '어제 못 끝낸 QA 이슈 정리', Category.work, due: _d(-1), sort: 4),
    t('w7', '워크숍 준비', Category.work, due: _d(1), end: _d(3), sort: 7),
    t(
      'p1',
      '하루 앱 캘린더 드래그 버그 수정',
      Category.personalDev,
      due: _d(0),
      sort: 1,
      started: c,
    ),
    t('p2', 'Supabase RLS 정책 문서화', Category.personalDev, due: _d(0), sort: 2),
    t(
      'p3',
      '앱 아이콘 다크모드 대응 아이디어 — 흰 배경 대신 틴트',
      Category.personalDev,
      due: _d(0),
      type: TodoType.note,
      sort: 3,
    ),
    t(
      'd1',
      '헬스 (하체)',
      Category.daily,
      due: _d(0, 19, 0),
      allDay: false,
      sort: 1,
      rule: 'FREQ=WEEKLY;BYDAY=MO,WE,FR',
    ),
    t('d2', '세탁소 옷 찾기', Category.daily, due: _d(0), sort: 2, done: _now),
    t('d3', '엄마 생신 선물 주문 — 늦어도 이번 주 안에 꼭', Category.daily, due: _d(0), sort: 3),
    t('w5', '온보딩 문서 갱신', Category.work, due: _d(2), sort: 5),
    t('w6', '분기 OKR 정리', Category.work, due: _d(6), sort: 6),
    t('l1', '사이드 프로젝트 수익화 실험', Category.longterm, sort: 1),
    t('l2', '영어 회화 주 2회 유지', Category.longterm, sort: 2),
    t(
      'i1',
      '단축키 치트시트를 앱 안에서 보여주기',
      Category.idea,
      type: TodoType.note,
      sort: 1,
    ),
    t('i2', '위젯으로 오늘 진행률 보여주기', Category.idea, type: TodoType.note, sort: 2),
    t('p4', '드리프트 마이그레이션 v12 설계', Category.personalDev, sort: 4),
    t('p4a', '스키마 diff 정리', Category.personalDev, parent: 'p4', sort: 1),
    t('p4b', '롤백 시나리오', Category.personalDev, parent: 'p4', sort: 2),
    t('d4', '치과 예약', Category.daily, due: _d(3, 11, 0), allDay: false, sort: 4),
  ];
}

class _Cap {
  _Cap(this.tester, this.key);
  final WidgetTester tester;
  final GlobalKey key;
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> shot(String name) async {
    await settle();
    final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: 2);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    Directory(_out).createSync(recursive: true);
    File('$_out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('SHOT $name');
  }
}

Future<_Cap> _mount(
  WidgetTester tester, {
  required FormFactor form,
  required Size size,
  bool dark = false,
  bool empty = false,
}) async {
  AppPlatform.debugFormFactorOverride = form;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    AppPlatform.debugFormFactorOverride = null;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final db = AppDatabase.memory();
  addTearDown(db.close);
  if (!empty) {
    for (final t in _seed()) {
      await db.todosDao.upsert(t);
    }
  }
  await db.groupsDao.upsert(
    const Group(id: 'g-work', label: '업무', colorValue: 0xFF2A66FF),
  );
  final key = GlobalKey();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowProvider.overrideWithValue(() => _now),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.mobileLight(),
          darkTheme: AppTheme.mobileDark(),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: const AppShell(),
        ),
      ),
    ),
  );
  final cap = _Cap(tester, key);
  await cap.settle();
  await cap.settle();
  return cap;
}

BuildContext _shellCtx(WidgetTester tester) =>
    tester.element(find.byType(AppShell));

Future<void> _tour(WidgetTester tester, _Cap cap, String prefix) async {
  await cap.shot('${prefix}_01_today');
  await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
  await cap.shot('${prefix}_02_outline');
  await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
  await cap.shot('${prefix}_03_calendar');
  await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
  await cap.shot('${prefix}_04_category_work');
  await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
  await cap.settle();

  final ctx = _shellCtx(tester);
  // ignore: unawaited_futures
  AddTodoSheet.show(ctx, initialCategory: Category.work, onSubmit: (_) {});
  await cap.shot('${prefix}_05_add_sheet');
  Navigator.of(ctx, rootNavigator: true).pop();
  await cap.settle();

  final w1 = _seed().firstWhere((t) => t.id == 'w1');
  // ignore: unawaited_futures
  AddTodoSheet.show(
    ctx,
    initialTodo: w1,
    onSubmit: (_) {},
    onRequestMove: (_) {},
  );
  await cap.shot('${prefix}_06_edit_sheet');
  Navigator.of(ctx, rootNavigator: true).pop();
  await cap.settle();

  // ignore: unawaited_futures
  Navigator.of(
    ctx,
  ).push(MaterialPageRoute<void>(builder: (_) => TodoDetailScreen(parent: w1)));
  await cap.shot('${prefix}_07_detail');
  Navigator.of(ctx).pop();
  await cap.settle();

  SearchScreen.show(ctx);
  await cap.settle();
  await tester.enterText(find.byType(TextField).first, '리팩토링');
  await cap.shot('${prefix}_08_search');
  Navigator.of(ctx).pop();
  await cap.settle();

  // ignore: unawaited_futures
  SettingsSheet.show(ctx);
  await cap.shot('${prefix}_09_settings');
  Navigator.of(ctx, rootNavigator: true).pop();
  await cap.settle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await _loadFonts();
  });

  testWidgets('desktop light', (tester) async {
    await tester.runAsync(() async {
      final cap = await _mount(
        tester,
        form: FormFactor.desktop,
        size: const Size(1280, 820),
      );
      await _tour(tester, cap, 'desktop');
    });
  });

  testWidgets('mobile light', (tester) async {
    await tester.runAsync(() async {
      final cap = await _mount(
        tester,
        form: FormFactor.mobile,
        size: const Size(390, 844),
      );
      await _tour(tester, cap, 'mobile');
      final menu = find.byIcon(Icons.menu);
      if (menu.evaluate().isNotEmpty) {
        await tester.tap(menu.first);
        await cap.shot('mobile_10_drawer');
      }
    });
  });

  testWidgets('empty states', (tester) async {
    await tester.runAsync(() async {
      final cap = await _mount(
        tester,
        form: FormFactor.desktop,
        size: const Size(1280, 820),
        empty: true,
      );
      await cap.shot('desktop_11_today_empty');
    });
  });
}
