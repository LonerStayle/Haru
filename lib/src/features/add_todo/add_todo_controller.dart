import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/todo_repository.dart';
import '../../domain/category.dart';
import '../../domain/recurrence.dart';
import '../../domain/recurrence_materializer.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/undo_snackbar.dart';
import '../calendar/calendar_service.dart';
import '../todo_actions/todo_actions_controller.dart';
import 'add_todo_default_category.dart';
import 'add_todo_sheet.dart';

/// 새 할 일 시트 공통 flow — FAB / Cmd+N / 트레이 / 빈 화면 버튼 / 캘린더 "이 날짜로 추가".
///
/// 예전엔 진입점마다 `onSubmit: (s) => submitted = s` 로 **마지막 한 건만** 받아 저장해서,
/// 여러 줄 붙여넣기(일괄 추가)를 하면 마지막 줄만 남았다. 캘린더 경로는 캘린더 등록 경고도
/// 버렸다. 이 함수 하나로 모아 두 문제를 같이 없앤다 (UX 개선 Phase 0).
Future<void> showNewTodoSheet(
  BuildContext context,
  WidgetRef ref, {
  required Category initialCategory,
  DateTime? initialDueAt,
  bool initialAllDay = true,
  String? initialTitle,
  RecurrenceFreq? initialRecurrence,
}) async {
  final pending = <AddTodoSubmission>[];
  await AddTodoSheet.show(
    context,
    initialCategory: initialCategory,
    initialDueAt: initialDueAt,
    initialAllDay: initialAllDay,
    initialTitle: initialTitle,
    initialRecurrence: initialRecurrence,
    onSubmit: pending.add,
  );
  if (!context.mounted) return;
  await savePendingSubmissions(context, ref, pending);
}

/// 시트가 모아 준 제출분 저장 — 1건이면 [AddTodoController.add] (캘린더 경고 안내),
/// 여러 건이면 입력 순서를 보존하는 [AddTodoController.addAll].
Future<void> savePendingSubmissions(
  BuildContext context,
  WidgetRef ref,
  List<AddTodoSubmission> pending,
) async {
  if (pending.isEmpty) return;
  // 최상위 새 항목이면 그 카테고리를 다음 ⌘N 의 기본값으로 기억한다(하위 추가는 제외).
  final last = pending.last;
  if (last.parentId == null) {
    unawaited(
      ref.read(lastUsedCategoryProvider.notifier).record(last.category.id),
    );
  }
  final controller = ref.read(addTodoControllerProvider);
  // AI 붙여넣기 정리 — 부모·하위를 한 번에 만들고, 한 번에 되돌린다.
  if (pending.any((s) => s.fromAi)) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final created = await controller.addAll(pending);
    if (messenger == null || !messenger.mounted || created.isEmpty) return;
    final actions = ref.read(todoActionsProvider);
    showUndoSnackbarOn(
      messenger,
      message: '${created.length}건 추가했어요.',
      onUndo: () async {
        // 하위 먼저 지운다 (만든 순서가 부모 → 그 하위).
        for (final t in created.reversed) {
          await actions.delete(t);
        }
      },
    );
    return;
  }
  if (pending.length > 1) {
    await controller.addAll(pending);
    return;
  }
  final result = await controller.add(pending.first);
  final warning = result.calendarWarning;
  if (warning == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(warning), behavior: SnackBarBehavior.floating),
  );
}

/// Task C — "＋ 하위 추가" 공통 flow. 부모 [parent] 를 받아 AddTodoSheet 를 child
/// 모드로 열고, 제출 시 parentId + 부모 category 를 상속한 자식 todo 를 생성한다.
/// 오늘/카테고리 화면이 공유.
Future<void> showAddChildSheet(
  BuildContext context,
  WidgetRef ref, {
  required Todo parent,
}) async {
  // bulk paste 까지 대응 — sheet 가 N건을 동기적으로 onSubmit 으로 흘려보내므로 버퍼에
  // 모았다가 닫힌 뒤 addAll 로 입력 순서를 보존하며 일괄 저장 (Task B).
  final pending = <AddTodoSubmission>[];
  await AddTodoSheet.show(
    context,
    initialCategory: parent.category,
    parentId: parent.id,
    onSubmit: pending.add,
  );
  if (!context.mounted) return;
  await savePendingSubmissions(context, ref, pending);
}

/// 항목 복사 — [original] 의 제목·내용·카테고리·날짜/시간·종류를 그대로 채운 "새 항목"
/// 시트를 연다. 저장 시 새 id 의 별개 todo 생성 (체크 상태·캘린더 이벤트는 미복사).
/// parentId 도 원본과 동일하게 유지 → 원본과 같은 위치(형제)로 복사된다.
Future<void> showCopyTodoSheet(
  BuildContext context,
  WidgetRef ref, {
  required Todo original,
}) async {
  final pending = <AddTodoSubmission>[];
  await AddTodoSheet.show(
    context,
    initialCategory: original.category,
    prefillFrom: original,
    parentId: original.parentId,
    onSubmit: pending.add,
  );
  if (!context.mounted) return;
  await savePendingSubmissions(context, ref, pending);
}

/// AddTodoSheet 가 만든 [AddTodoSubmission] 을 도메인 [Todo] 로 변환 + 저장 + (선택) Calendar 등록.
class AddTodoController {
  AddTodoController({
    required this.repo,
    required this.now,
    required this.calendar,
  });

  final TodoRepository repo;
  final DateTime Function() now;

  /// null 이면 Google OAuth 미설정 → addToCalendar 가 true 여도 자동 skip.
  final CalendarService? calendar;

  /// 1) Todo.create 으로 새 todo 생성 + repo.upsert
  /// 2) addToCalendar && dueAt != null && calendar != null 이면 Calendar 이벤트 생성 후
  ///    eventId 를 todo 에 붙여서 다시 upsert
  /// Calendar 호출 실패는 fatal X — todo 자체는 보존. UI 에 안내할 warning 메시지를
  /// 결과에 포함해 반환.
  Future<AddTodoResult> add(AddTodoSubmission s) async {
    // Task B — 신규 생성은 맨 위로. 같은 형제(parentId+category) min sortOrder - 1.
    final minSibling = await repo.minSiblingSortOrder(
      categoryId: s.category.id,
      parentId: s.parentId,
    );
    final sortOrder = (minSibling ?? 0) - 1;
    // date-repeat — 반복 규칙이 있으면 이 todo 는 "마스터"(숨김 템플릿)로 저장하고,
    // 발생일마다 인스턴스를 즉시 실체화한다. recurrence 는 dueAt(앵커)이 있어야 의미.
    final isRecurring = s.recurrence != null && s.dueAt != null;
    var todo = Todo.create(
      title: s.title,
      category: s.category,
      dueAt: s.dueAt,
      now: now,
      type: s.type,
      description: s.description,
      endAt: s.endAt,
      isAllDay: s.isAllDay,
      timeAnchor: s.timeAnchor,
      parentId: s.parentId,
      sortOrder: sortOrder,
    );
    if (isRecurring) {
      // 마스터: seriesId=자기 id, 규칙/종료일 보유, isSeriesMaster=true.
      todo = todo.copyWith(
        seriesId: todo.id,
        recurrenceRule: s.recurrence!.encode(),
        recurrenceEndAt: s.recurrenceEndAt,
        isSeriesMaster: true,
      );
    }
    await repo.upsert(todo);

    // 마스터면 anchor~오늘 발생분을 즉시 생성(첫 인스턴스가 바로 오늘 화면에 뜨도록).
    // 이후 발생분은 recurrenceMaterializerProvider 가 자정마다 채운다.
    if (isRecurring) {
      final fresh = RecurrenceMaterializer.materializeDue(
        [todo],
        const {},
        now(),
      );
      for (final inst in fresh) {
        await repo.upsert(inst);
      }
    }

    // 캘린더 등록은 저장소 데코레이터가 큐에 넣어 처리한다 (위 upsert 시점에 이미
    // 판정됐다). 여기서 직접 이벤트를 만들면 데코레이터와 **둘 다** 만들어 이벤트가
    // 두 개 생긴다. 연동이 아예 설정되지 않은 경우만 사용자에게 알린다.
    final warning = (s.addToCalendar && s.dueAt != null && calendar == null)
        ? 'Google Calendar 연동이 설정되지 않아 등록을 건너뛰었어요.'
        : null;
    return AddTodoResult(todo: todo, calendarWarning: warning);
  }

  /// 일괄 추가 — 입력 순서를 보존하며 전체를 맨 위로 올린다. 만든 할 일을 부모 → 그
  /// 하위 순서로 돌려준다.
  ///
  /// 형제 집합(category + parentId)마다 min sortOrder 를 한 번 조회한 뒤 그 집합 안의 입력
  /// 순서를 그대로 보존한다 — 첫 줄이 맨 위(가장 작은 sortOrder), 마지막 줄이 `min-1`.
  /// 즉 집합 안 i 번째 = `min - (N - i)`. AI 붙여넣기 정리처럼 카테고리가 섞여도 집합마다
  /// 따로 맨 위로 간다(예전엔 첫 항목의 집합만 보고 계산했다).
  /// [AddTodoSubmission.children] 은 만든 부모 아래에 같은 규칙으로 저장한다(1단계).
  /// Calendar 등록은 건당 [add] 와 동일하게 저장소 데코레이터가 처리한다.
  Future<List<Todo>> addAll(List<AddTodoSubmission> subs) async {
    if (subs.isEmpty) return const [];
    // 반복 규칙이 있으면 건마다 마스터 + 인스턴스 생성이 필요하다 → [add] 에 맡긴다.
    // add 는 매번 맨 위(min-1)에 넣으므로 **역순**으로 넣어야 입력 순서가 위→아래로 보존된다.
    if (subs.any((s) => s.recurrence != null && s.dueAt != null)) {
      final made = <Todo>[];
      for (final s in subs.reversed) {
        made.add((await add(s)).todo);
      }
      return made.reversed.toList();
    }
    final created = <Todo>[];
    // 입력 위치로 묶는다 — 같은 const 제출이 두 번 와도 각각 만든다.
    final groups = <(String, String?), List<int>>{};
    for (var i = 0; i < subs.length; i++) {
      final s = subs[i];
      groups.putIfAbsent((s.category.id, s.parentId), () => []).add(i);
    }
    final made = List<Todo?>.filled(subs.length, null);
    for (final MapEntry(key: (categoryId, parentId), value: group)
        in groups.entries) {
      final minSibling = await repo.minSiblingSortOrder(
        categoryId: categoryId,
        parentId: parentId,
      );
      final min = minSibling ?? 0;
      final n = group.length;
      for (var j = 0; j < n; j++) {
        // 첫 줄 = min - N (맨 위), 마지막 줄 = min - 1.
        made[group[j]] = await _insert(
          subs[group[j]],
          sortOrder: min - (n - j),
        );
      }
    }
    for (var i = 0; i < subs.length; i++) {
      final s = subs[i];
      final parent = made[i]!;
      created.add(parent);
      final kids = s.children;
      for (var i = 0; i < kids.length; i++) {
        final k = kids[i];
        created.add(
          await _insert(
            AddTodoSubmission(
              title: k.title,
              category: parent.category,
              parentId: parent.id,
              dueAt: k.dueAt,
              isAllDay: k.isAllDay,
              timeAnchor: k.timeAnchor,
              addToCalendar: k.addToCalendar,
              type: k.type,
              description: k.description,
            ),
            // 새 부모라 기존 형제가 없다 — 입력 순서대로.
            sortOrder: i - kids.length,
          ),
        );
      }
    }
    return created;
  }

  Future<Todo> _insert(AddTodoSubmission s, {required int sortOrder}) async {
    final todo = Todo.create(
      title: s.title,
      category: s.category,
      dueAt: s.dueAt,
      now: now,
      type: s.type,
      description: s.description,
      endAt: s.endAt,
      isAllDay: s.isAllDay,
      timeAnchor: s.timeAnchor,
      parentId: s.parentId,
      sortOrder: sortOrder,
    );
    // 캘린더 등록은 저장소 데코레이터가 처리한다 — 여기서 또 만들면 이벤트가 둘이 된다.
    await repo.upsert(todo);
    return todo;
  }
}

/// [AddTodoController.add] 의 결과. UI 가 [calendarWarning] 이 있으면 SnackBar 등으로 안내.
class AddTodoResult {
  const AddTodoResult({required this.todo, this.calendarWarning});

  final Todo todo;
  final String? calendarWarning;
}

final addTodoControllerProvider = Provider<AddTodoController>(
  (ref) => AddTodoController(
    repo: ref.watch(todoRepositoryProvider),
    now: ref.watch(nowProvider),
    calendar: ref.watch(calendarServiceProvider),
  ),
);
