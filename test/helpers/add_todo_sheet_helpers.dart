import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// UX Phase 1 — 추가/편집 시트는 2단이다. 설명·기간·캘린더·반복·상태·위치는
/// "더보기" 안에 있으므로 그 칸을 만지는 테스트는 먼저 펼친다. 이미 펼쳐져 있으면
/// (설명·기간·반복이 있는 항목은 펼친 채 열린다) 그대로 둔다.
Future<void> openSheetMore(WidgetTester tester) async {
  if (find
      .byKey(const ValueKey('add-todo-more-section'))
      .evaluate()
      .isNotEmpty) {
    return;
  }
  final toggle = find.byKey(const ValueKey('add-todo-more'));
  // 더보기에 담을 게 없는 시트(예: 이동 없는 메모 편집)에는 토글이 없다.
  if (toggle.evaluate().isEmpty) return;
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}
