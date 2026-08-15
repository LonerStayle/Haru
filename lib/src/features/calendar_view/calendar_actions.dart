import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../domain/category.dart';
import '../../domain/recurrence_materializer.dart';
import '../../domain/todo.dart';
import '../add_todo/add_todo_controller.dart';
import '../add_todo/add_todo_sheet.dart';
import '../category/categories_controller.dart';
import '../move_todo/move_todo_sheet.dart';
import '../todo_actions/todo_actions_controller.dart';
import 'calendar_entry.dart';

/// 엔트리를 **조작 가능한 실제 Todo** 로 바꾼다.
///
/// 미래 반복 회차는 DB 에 실체가 없는 고스트라 체크·드래그·편집할 row 가 없다.
/// 사용자가 건드리는 순간 그 회차만 실체화한다 (대표님 확정 규칙 R-9).
/// 실체화 id 는 결정적이라 나중에 정규 실체화가 도달해도 중복이 생기지 않는다.
///
/// 구글 이벤트는 읽기 전용이므로 항상 null.
Future<Todo?> resolveEntryTodo(WidgetRef ref, CalendarEntry entry) async {
  if (entry is TodoEntry) return entry.todo;
  if (entry is! RecurringGhostEntry) return null;

  final instance = RecurrenceMaterializer.materializeOne(
    entry.master,
    entry.startDate,
    ref.read(nowProvider)(),
  );
  if (instance == null) return null;
  await ref.read(todoRepositoryProvider).upsert(instance);
  return instance;
}

/// 캘린더에서 여는 편집 시트 — 전 앱 공통 관용구 그대로.
/// 닫으면 저장이 규칙이므로 취소 개념을 넣지 않는다.
void openCalendarEditSheet(BuildContext context, WidgetRef ref, Todo todo) {
  AddTodoSheet.show(
    context,
    initialCategory: todo.category,
    initialTodo: todo,
    onSubmit: (_) {},
    onUpdate: (updated) => ref.read(todoActionsProvider).update(updated),
    onRequestMove: (item) => showMoveTodoSheet(context, ref, item: item),
  );
}

/// "이 날짜로 추가" — [date] 가 이미 채워진 추가 시트를 연다.
///
/// 캘린더의 핵심 가치가 "날짜 입력 단계를 통째로 생략" 이라 종일로 프리셋한다
/// (시각이 필요하면 시트 안에서 한 번 더 누르면 된다).
Future<void> openAddTodoOnDate(
  BuildContext context,
  WidgetRef ref,
  DateTime date,
) async {
  AddTodoSubmission? submitted;
  await AddTodoSheet.show(
    context,
    initialCategory: defaultCalendarCategory(ref),
    initialDueAt: dateOnly(date),
    onSubmit: (s) => submitted = s,
  );
  if (submitted != null) {
    await ref.read(addTodoControllerProvider).add(submitted!);
  }
}

/// 캘린더에는 "지금 보고 있는 카테고리" 라는 맥락이 없다. 활성 카테고리의 첫 번째를
/// 기본값으로 쓰고, 아직 로딩 중이면 builtin 기본값으로 떨어진다.
/// (사용자가 시트에서 언제든 바꿀 수 있으므로 틀려도 손해가 작다.)
Category defaultCalendarCategory(WidgetRef ref) {
  return ref
      .read(activeCategoriesProvider)
      .maybeWhen(
        data: (list) => list.isEmpty ? Category.daily : list.first,
        orElse: () => Category.daily,
      );
}
