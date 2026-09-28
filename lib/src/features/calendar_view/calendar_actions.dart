import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../domain/recurrence_materializer.dart';
import '../../domain/todo.dart';
import '../add_todo/add_todo_controller.dart';
import '../add_todo/add_todo_default_category.dart';
import '../category/categories_controller.dart';
import '../category/groups_controller.dart';
import '../settings/app_preferences.dart';
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

/// "이 날짜로 추가" — [date] 가 이미 채워진 추가 시트를 연다.
///
/// 캘린더의 핵심 가치가 "날짜 입력 단계를 통째로 생략" 이라 종일로 프리셋한다
/// (시각이 필요하면 시트 안에서 한 번 더 누르면 된다).
Future<void> openAddTodoOnDate(
  BuildContext context,
  WidgetRef ref,
  DateTime date,
) async {
  await showNewTodoSheet(
    context,
    ref,
    initialCategory: defaultCalendarCategory(ref),
    initialDueAt: dateOnly(date),
  );
}

/// 캘린더에는 "지금 보고 있는 카테고리" 라는 맥락이 없다 — ⌘N 과 같은 규칙(설정의 기본
/// 카테고리 → 마지막에 쓴 카테고리 → 사이드바 첫 카테고리). 로딩 중이면 builtin 기본값.
/// (사용자가 시트에서 언제든 바꿀 수 있으므로 틀려도 손해가 작다.)
Category defaultCalendarCategory(WidgetRef ref) {
  return ref
      .read(activeCategoriesProvider)
      .maybeWhen(
        data: (list) {
          if (list.isEmpty) return Category.daily;
          return resolveAddTodoDefaultCategory(
            categories: list,
            groups:
                ref.read(activeGroupsProvider).asData?.value ?? const <Group>[],
            destinations: const [],
            index: 0,
            selectedGroupId: null,
            preferredCategoryId: ref.read(defaultCategoryIdProvider),
            lastUsedId: ref.read(lastUsedCategoryProvider),
          );
        },
        orElse: () => Category.daily,
      );
}
