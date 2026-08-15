import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/todo_repository.dart';
import '../../domain/recurrence_materializer.dart';
import '../../domain/todo.dart';
import '../calendar/calendar_service.dart';
import 'add_todo_sheet.dart';

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
  if (pending.isEmpty) return;
  final controller = ref.read(addTodoControllerProvider);
  if (pending.length == 1) {
    await controller.add(pending.first);
  } else {
    await controller.addAll(pending);
  }
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
  if (pending.isEmpty) return;
  final controller = ref.read(addTodoControllerProvider);
  if (pending.length == 1) {
    await controller.add(pending.first);
  } else {
    await controller.addAll(pending);
  }
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

  /// Task B — bulk paste 용. 입력 순서를 보존하며 전체를 맨 위로 올린다.
  ///
  /// 같은 형제 집합(첫 항목의 parentId+category 기준) min sortOrder 를 한 번만 조회한 뒤
  /// 입력 순서를 그대로 보존하며 전체를 기존 형제들 위로 올린다 — 첫 줄이 맨 위(가장 작은
  /// sortOrder), 마지막 줄이 `min-1`. 즉 i 번째 = `min - (N - i)` (N = 줄 수).
  /// 작은 sortOrder = 위 불변식과 맞물려 화면에서 입력 순서대로 위→아래로 보인다.
  /// Calendar 등록은 건당 [add] 와 동일하게 처리.
  ///
  /// 모든 submission 이 같은 category/parentId 라고 가정 (AddTodoSheet bulk 흐름이 보장).
  Future<void> addAll(List<AddTodoSubmission> subs) async {
    if (subs.isEmpty) return;
    final first = subs.first;
    final minSibling = await repo.minSiblingSortOrder(
      categoryId: first.category.id,
      parentId: first.parentId,
    );
    final min = minSibling ?? 0;
    final n = subs.length;
    for (var i = 0; i < subs.length; i++) {
      final s = subs[i];
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
        // 첫 줄 = min - N (맨 위), 마지막 줄 = min - 1.
        sortOrder: min - (n - i),
      );
      // 캘린더 등록은 저장소 데코레이터가 처리한다 — 여기서 또 만들면 이벤트가 둘이 된다.
      await repo.upsert(todo);
    }
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
