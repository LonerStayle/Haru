import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../domain/category.dart';
import '../domain/todo.dart';
import '../features/calendar/calendar_op_decider.dart';
import '../features/calendar/calendar_settings.dart';
import 'local/app_database.dart';
import 'local/calendar_ops_dao.dart';
import 'todo_repository.dart';

const _uuid = Uuid();

/// 모든 할 일 저장을 지나가며 **캘린더에 영향이 있는 것만** 큐에 적재하는 데코레이터.
///
/// **왜 데코레이터인가** — 편집 시트 진입점만 7곳이고 이동·정렬·완료·일괄 붙여넣기까지
/// 세면 더 많다. 각 호출부에 캘린더 호출을 흩뿌리면 반드시 누락이 생긴다 (실제로 이
/// 앱의 기존 결함이 그것이었다 — 수정·삭제가 캘린더에 반영되지 않았다). 반면
/// `SyncingTodoRepository` 안에 넣으면 Supabase 미인증 시 `LocalTodoRepository` 로
/// 빠져 캘린더 동기화가 통째로 사라진다. 구글 연동은 Supabase 로그인과 독립이어야 한다.
///
/// 그래서 **바깥에 한 겹 씌운다.** 연동이 꺼져 있으면 조립 단계에서 아예 끼우지 않으므로
/// 앱은 이전과 완전히 동일하게 동작한다.
class CalendarAwareTodoRepository implements TodoRepository {
  CalendarAwareTodoRepository({
    required this.inner,
    required this.ops,
    required this.settings,
    DateTime Function()? now,
    String Function()? idGen,
  }) : _now = now ?? DateTime.now,
       _idGen = idGen ?? _uuid.v4;

  final TodoRepository inner;
  final CalendarOpsDao ops;

  /// 호출 시점의 설정을 읽는다 — 사용자가 설정을 바꿔도 다음 저장부터 곧바로 반영된다.
  final CalendarSettings Function() settings;

  final DateTime Function() _now;
  final String Function() _idGen;

  /// **다음 upsert 1회에만** 적용되는 명시적 등록 의사.
  ///
  /// 편집 시트의 "Google Calendar 에 등록" 토글이 저장 직전에 세팅한다. 기본값
  /// ([CalendarSettings.defaultAddToCalendar])만으로는 "이번 항목만 올리지 않기" 를
  /// 표현할 수 없기 때문이다. 1인 사용자 앱이라 저장이 순차적이므로 one-shot 으로
  /// 충분하고, 소비 후 즉시 비워 다음 저장에 새어나가지 않게 한다.
  bool? _pendingIntent;

  void intendCalendar(bool addToCalendar) => _pendingIntent = addToCalendar;

  bool _consumeIntent() {
    final v = _pendingIntent;
    _pendingIntent = null;
    return v ?? settings().defaultAddToCalendar;
  }

  // --- 읽기 — 전부 위임 ------------------------------------------------

  @override
  Future<Todo?> getById(String id) => inner.getById(id);

  @override
  Stream<List<Todo>> watchAll() => inner.watchAll();

  @override
  Stream<List<Todo>> watchByCategory(Category category) =>
      inner.watchByCategory(category);

  @override
  Stream<List<Todo>> watchToday(DateTime Function() now) =>
      inner.watchToday(now);

  @override
  Future<int?> minSiblingSortOrder({
    required String categoryId,
    String? parentId,
  }) => inner.minSiblingSortOrder(categoryId: categoryId, parentId: parentId);

  // --- 쓰기 — 위임 후 판정 ---------------------------------------------

  @override
  Future<void> upsert(Todo todo) async {
    final addToCalendar = _consumeIntent();
    final current = settings();
    // 변경 전 상태를 먼저 확보한다 — 무엇이 바뀌었는지 알아야 판정할 수 있다.
    final prev = await inner.getById(todo.id);

    // **저장이 먼저다.** 캘린더 쪽에서 무슨 일이 나든 로컬 저장을 막아선 안 된다.
    await inner.upsert(todo);

    if (!current.connected) return;
    final decision = decideCalendarOp(
      prev: prev,
      next: todo,
      addToCalendar: addToCalendar,
      writeCalendarId: current.writeCalendarId,
    );
    if (decision.kind == CalendarOpKind.none) return;
    await _enqueue(decision, todo: todo);
  }

  @override
  Future<void> deleteById(String id) async {
    final prev = await inner.getById(id);
    await inner.deleteById(id);

    final current = settings();
    if (!current.connected) return;
    final eventId = prev?.calendarEventId;
    if (eventId == null) return;
    await _enqueue(
      CalendarOpDecision(
        CalendarOpKind.delete,
        eventId: eventId,
        calendarId: prev!.calendarId ?? current.writeCalendarId,
      ),
      todo: prev,
    );
  }

  Future<void> _enqueue(CalendarOpDecision decision, {required Todo todo}) {
    final isDelete = decision.kind == CalendarOpKind.delete;
    return ops.enqueue(
      CalendarOpRow(
        id: _idGen(),
        kind: decision.kind.name,
        todoId: todo.id,
        eventId: decision.eventId,
        calendarId: decision.calendarId ?? settings().writeCalendarId,
        // 삭제는 이벤트 id 만 있으면 되고, 나머지는 스냅샷으로 보낸다. 큐에 쌓인 뒤
        // 할 일이 또 바뀌어도 flush 시점에 최신 상태를 다시 읽으므로 스냅샷은
        // 참고용이다 (오프라인 진단·복구에 쓰인다).
        payload: isDelete ? null : jsonEncode(todo.toJson()),
        attempts: 0,
        lastError: null,
        nextAttemptAt: null,
        createdAt: _now().toUtc(),
      ),
    );
  }
}
