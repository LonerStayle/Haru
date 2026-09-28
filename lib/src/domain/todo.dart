import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:uuid/uuid.dart';

import 'category.dart';
import 'recurrence.dart';

part 'todo.freezed.dart';
part 'todo.g.dart';

/// Todo 의 종류.
///
/// - [task] — 체크 가능한 할 일. 진척률(부모의 [N/M]) 카운트에 포함.
/// - [note] — 단순 메모. 체크박스 없음, doneAt 무관, 진척률 분모 제외.
///   메모장 sub-bullet 중 "→ KV 캐싱 ..." 같은 설명용 항목을 표현.
enum TodoType {
  @JsonValue('task')
  task,
  @JsonValue('note')
  note,
}

/// 할 일 한 건.
///
/// - [doneAt] 가 null 이면 미체크, 값이 있으면 체크된 시각. ([type] = note 면 항상 null.)
/// - [startedAt] 가 값이 있고 [doneAt] 가 null 이면 "진행중". 완료 시 [startedAt] 는
///   제거된다 (완료 = 진행중 아님). **불변식: [startedAt] 와 [doneAt] 는 동시에
///   세팅되지 않는다** — 미완료(둘 다 null) / 진행중(startedAt만) / 완료(doneAt) 3-상태.
/// - [dueAt] 는 사용자가 지정한 일정 (Google Calendar 등록 대상).
/// - [calendarEventId] 가 있으면 캘린더에 이벤트가 등록된 상태.
/// - [calendarId] / [calendarOrigin] — Google Calendar 양방향 동기화용 (아래 참조).
/// - [createdAt] / [updatedAt] 은 Supabase last-write-wins 충돌 해소에 사용.
/// - [parentId] 가 null 이면 카테고리 직속 root, set 이면 그 todo 의 자식 (트리 노드).
/// - [type] — task / note (기본 task).
/// - [sortOrder] — 같은 parent 내 사용자 정의 순서 (작은 값 먼저). 기본 0, drag-reorder
///   는 v1.2 후속. v1.1 첫 cut 에서는 createdAt fallback 정렬로 충분.
/// - [endAt] / [isAllDay] / [timeAnchor] — fast-tasks 날짜·기간 모델 (아래 참조).
enum TodoDateMode {
  /// dueAt 없음.
  none,

  /// 단일·하루종일 — dueAt(date@00:00), isAllDay=true, endAt=null.
  allDay,

  /// 단일·시작시간만 — dueAt(date+time), isAllDay=false, endAt=null, timeAnchor='start'.
  startTime,

  /// 단일·마감시간만 — dueAt(date+time), isAllDay=false, endAt=null, timeAnchor='end'.
  endTime,

  /// 기간 — dueAt(시작) + endAt(종료). isAllDay 로 양끝 시간 표시 여부 단순화.
  range,
}

/// 할 일의 3-상태 — 미완료 / 진행중 / 완료.
///
/// [Todo.startedAt] 와 [Todo.doneAt] 조합에 이름을 붙인 것이다. 두 필드는 동시에
/// 세팅되지 않는다는 불변식 덕분에 조합은 정확히 이 셋뿐이다.
/// ([TodoType.note] 는 체크·진행 개념이 없어 항상 [TodoStatus.undone].)
///
/// 뷰 필터인 `TodoStatusFilter` 와 라벨은 같지만 층이 다르다 — 이쪽은 도메인 상태,
/// 저쪽은 목록을 좁히는 렌더 조건.
enum TodoStatus {
  /// 둘 다 null — 아직 손대지 않음. (□)
  undone,

  /// startedAt 만 있음 — 시작했으나 미완. (△)
  inProgress,

  /// doneAt 있음 — 완료. (◯)
  done,
}

@freezed
abstract class Todo with _$Todo {
  const Todo._();

  const factory Todo({
    required String id,
    required String title,
    @JsonKey(fromJson: _categoryFromJson, toJson: _categoryToJson)
    required Category category,
    DateTime? dueAt,
    DateTime? doneAt,
    // 진행중(in-progress) 시작 시각. 값이 있고 doneAt 이 null 이면 "진행중" 상태.
    // 완료(doneAt set) 시엔 null 로 비워진다. (note 는 항상 null.)
    DateTime? startedAt,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? calendarEventId,
    // [calendarId] — calendarEventId 가 속한 Google Calendar id. null = 미등록
    // 또는 레거시(과거엔 'primary' 하드코딩이었으므로 null 이면 primary 로 간주).
    String? calendarId,
    // [calendarOrigin] — 'app'(앱에서 만든 할 일) | 'gcal'(Google Calendar 유입)
    // | 'msgraph'(Microsoft 365 유입). **삭제 규칙의 유일한 근거**: 캘린더 쪽 이벤트가
    // 삭제됐을 때 origin='app' 이면 할 일은 남기고 연결만 해제, 그 외(캘린더 유입)면
    // 할 일도 함께 삭제한다 ([isFromCalendar]). 반드시 Supabase 로 전파되어
    // macOS/Android 양쪽이 같은 판단을 한다.
    // ⚠️ RISK(breaking): 이 세 필드는 Supabase 의 `calendar_id` / `calendar_origin` /
    // `calendar_provider` 컬럼과 1:1 대응한다. `supabase/schema.sql` 재실행 없이
    // 배포하면 PGRST204 로 todos 동기화 전체가 멈춘다 (컬럼 추가 후 `notify pgrst` 필요).
    @Default('app') String calendarOrigin,
    // [calendarProvider] — 이 할 일이 연결된 캘린더 서비스 ('google' | 'microsoft').
    // **null 은 구글**이다 — 이 필드가 생기기 전 데이터(전부 구글 연동)와의 하위호환이
    // 여기서 성립하므로 기본값을 넣지 않고 nullable 로 둔다. 큐가 어느 게이트웨이로
    // 작업을 보낼지, 수신한 이벤트를 어느 할 일과 짝지을지가 이 값으로 갈린다.
    String? calendarProvider,
    String? parentId,
    @Default(TodoType.task) TodoType type,
    @Default(0) int sortOrder,
    // v1.2 — 상세 메모 (long text). nullable + 누락 시 null 로 안전 fallback.
    String? description,
    // ── 날짜·기간 모델 (fast-tasks 4/5/1) — dueAt 은 앵커로 그대로 유지 ──────────
    // [endAt] — 기간 모드의 종료 시각. 단일 모드면 null.
    DateTime? endAt,
    // [isAllDay] — true 면 시간 미표시 (화면 어디에도 00:00 을 찍지 않음).
    @Default(false) bool isAllDay,
    // [timeAnchor] — 단일·시간 모드에서 dueAt 이 '시작'('start')인지 '마감'('end')인지.
    // 하루종일·기간 모드에서는 의미 없음 (기본 'start' 유지).
    @Default('start') String timeAnchor,
    // ── 날짜 반복 (date-repeat) ─────────────────────────────────────────────
    // [seriesId] — 소속 반복 시리즈 id. 마스터는 자기 id, 인스턴스는 마스터 id.
    //   null = 일반(비반복) Todo.
    String? seriesId,
    // [recurrenceRule] — 반복 규칙 직렬화(RecurrenceRule.encode). **마스터에만** 채움.
    String? recurrenceRule,
    // [recurrenceEndAt] — 반복 종료일. **마스터에만**. null = 무한.
    DateTime? recurrenceEndAt,
    // [isSeriesMaster] — true = 규칙 보유 숨김 템플릿(모든 목록에서 제외, 캘린더 RRULE 소유).
    @Default(false) bool isSeriesMaster,
  }) = _Todo;

  factory Todo.fromJson(Map<String, dynamic> json) => _$TodoFromJson(json);

  /// 새 Todo 생성 헬퍼. test 환경에서 결정성을 위해 [now] / [idGen] 주입 가능.
  factory Todo.create({
    required String title,
    required Category category,
    DateTime? dueAt,
    DateTime Function()? now,
    String Function()? idGen,
    String? parentId,
    TodoType type = TodoType.task,
    int sortOrder = 0,
    String? description,
    DateTime? endAt,
    bool isAllDay = false,
    String timeAnchor = 'start',
    String? seriesId,
    String? recurrenceRule,
    DateTime? recurrenceEndAt,
    bool isSeriesMaster = false,
    String? calendarId,
    String calendarOrigin = 'app',
    String? calendarProvider,
  }) {
    final n = (now ?? DateTime.now)();
    return Todo(
      id: (idGen ?? const Uuid().v4)(),
      title: title,
      category: category,
      dueAt: dueAt,
      doneAt: null,
      startedAt: null,
      createdAt: n,
      updatedAt: n,
      calendarEventId: null,
      calendarId: calendarId,
      calendarOrigin: calendarOrigin,
      calendarProvider: calendarProvider,
      parentId: parentId,
      type: type,
      sortOrder: sortOrder,
      description: description,
      endAt: endAt,
      isAllDay: isAllDay,
      timeAnchor: timeAnchor,
      seriesId: seriesId,
      recurrenceRule: recurrenceRule,
      recurrenceEndAt: recurrenceEndAt,
      isSeriesMaster: isSeriesMaster,
    );
  }

  /// 직렬화된 필드 조합으로부터 현재 날짜 모드를 도출. UI / 캘린더 매핑의 단일 출처.
  TodoDateMode get dateMode {
    if (dueAt == null) return TodoDateMode.none;
    if (endAt != null) return TodoDateMode.range;
    if (isAllDay) return TodoDateMode.allDay;
    return timeAnchor == 'end' ? TodoDateMode.endTime : TodoDateMode.startTime;
  }

  /// 체크(완료)된 상태인지. note 는 항상 false (체크 개념 X).
  bool get isDone => type == TodoType.task && doneAt != null;

  /// 진행중 상태인지 — 시작했으나(startedAt) 아직 완료 안 됨(doneAt null). note 는 false.
  bool get isInProgress =>
      type == TodoType.task && doneAt == null && startedAt != null;

  /// 완료 토글 — done 이면 미체크로, 미체크면 [now] (기본 now) 체크.
  /// **완료 시 진행중 표식([startedAt])은 제거**한다 (완료 = 진행중 아님). 완료 해제는
  /// 미완료(둘 다 null)로 되돌린다. note 타입은 toggle 무시 (체크 개념 없음).
  Todo toggleDone({DateTime Function()? now}) {
    if (type == TodoType.note) return this;
    final n = (now ?? DateTime.now)();
    return isDone
        ? copyWith(doneAt: null, updatedAt: n)
        : copyWith(doneAt: n, startedAt: null, updatedAt: n);
  }

  /// 진행중 토글 — 진행중이면 미완료로, 아니면 진행중으로. 완료였던 항목을 진행중으로
  /// 바꾸면 [doneAt] 는 해제된다 (불변식: startedAt/doneAt 동시 세팅 금지).
  /// note 타입은 무시 (체크·진행 개념 없음).
  Todo toggleInProgress({DateTime Function()? now}) {
    if (type == TodoType.note) return this;
    final n = (now ?? DateTime.now)();
    return isInProgress
        ? copyWith(startedAt: null, updatedAt: n)
        : copyWith(startedAt: n, doneAt: null, updatedAt: n);
  }

  /// 캘린더에서 유입된 할 일인가 (앱에서 만든 것이 아닌가).
  ///
  /// 삭제 규칙의 단일 판정 — 캘린더 쪽 일정이 지워졌을 때 이 값이 true 면 할 일도
  /// 함께 지우고, false 면 할 일은 남기고 연결만 끊는다. 값 비교를 `== 'gcal'` 로
  /// 흩뿌리면 서비스가 늘 때마다 빠뜨리는 곳이 생긴다.
  bool get isFromCalendar => calendarOrigin != 'app';

  /// 현재 3-상태. note 는 상태 개념이 없어 항상 [TodoStatus.undone].
  TodoStatus get status {
    if (isDone) return TodoStatus.done;
    if (isInProgress) return TodoStatus.inProgress;
    return TodoStatus.undone;
  }

  /// 상태를 [next] 로 **직접 지정**한다. 현재 상태에서 다음으로 넘어가는 toggle 과
  /// 달리, 어디에 있든 목표 상태로 간다 (편집 시트의 □ / △ / ◯ 탭).
  ///
  /// 불변식 유지 — 완료면 [startedAt] 를 비우고, 진행중이면 [doneAt] 를 비우며,
  /// 미완료면 둘 다 비운다. [toggleDone] / [toggleInProgress] 가 만드는 결과와 정확히
  /// 같은 조합이라 의미가 어긋나지 않는다.
  ///
  /// 이미 그 상태면 **원본을 그대로** 돌려준다 — [updatedAt] 도 건드리지 않아 헛저장·
  /// 헛동기화가 생기지 않는다. [sortOrder] 는 어떤 경로로도 바뀌지 않는다 (체크·세모
  /// 토글과 같은 규칙 — 상태를 바꿔도 자리는 그대로).
  /// note 타입은 무시.
  Todo withStatus(TodoStatus next, {DateTime Function()? now}) {
    if (type == TodoType.note || status == next) return this;
    final n = (now ?? DateTime.now)();
    return switch (next) {
      TodoStatus.undone => copyWith(
        doneAt: null,
        startedAt: null,
        updatedAt: n,
      ),
      TodoStatus.inProgress => copyWith(
        doneAt: null,
        startedAt: n,
        updatedAt: n,
      ),
      TodoStatus.done => copyWith(doneAt: n, startedAt: null, updatedAt: n),
    };
  }

  /// 캘린더 이벤트 id 갱신.
  Todo withCalendarEvent(String? eventId, {DateTime Function()? now}) {
    final n = (now ?? DateTime.now)();
    return copyWith(calendarEventId: eventId, updatedAt: n);
  }

  /// 반복 시리즈의 마스터(숨김 템플릿)인가 — 규칙 보유 + 목록 제외 + 캘린더 RRULE 소유.
  bool get isRecurringMaster => isSeriesMaster && recurrenceRule != null;

  /// 반복 시리즈(마스터 또는 인스턴스)에 속하는가?
  bool get isInRecurringSeries => seriesId != null;

  /// 디코드된 반복 규칙. 규칙 문자열이 없으면 null. (마스터에서만 유효)
  RecurrenceRule? get recurrence =>
      recurrenceRule == null ? null : RecurrenceRule.decode(recurrenceRule!);
}

/// Todo JSON 의 `category` 필드를 nested object 가 아닌 string id 로 직렬화 유지.
/// v1.0 / v1.1 의 옛 payload (예: `"category": "work"`) 가 그대로 복원된다.
///
/// ⚠️ v1.2 사용자 추가 카테고리 id ('cat-...') 는 builtin 이 아니라 [Category.tryFromId]
/// 가 null 을 준다. 이때 [Category.daily] 로 붕괴시키면 안 된다 — outbox flush 가
/// toJson→fromJson 으로 복원해 Supabase 에 업로드하므로, 붕괴 시 원격 row 의 category 가
/// 전부 'daily' 로 오염되고 다른 기기(모바일)에서 모든 항목이 '일상'으로 보인다.
/// 미지 id 는 id 만 보존하는 placeholder 로 복원한다 (label/color 는 categories join 으로
/// 복원되므로 메타는 쓰이지 않음 — [SupabaseTodosApi._fromRow] / [TodosDao] 와 동일 규칙).
Category _categoryFromJson(Object? value) {
  if (value is String) {
    return Category.tryFromId(value) ?? _placeholderCategory(value);
  }
  if (value is Map<String, dynamic>) {
    return Category.fromJson(value);
  }
  return Category.daily;
}

/// 미지 카테고리 id 를 id 만 보존한 채 안전 복원. (SupabaseTodosApi._fromRow 와 동일.)
Category _placeholderCategory(String id) => Category(
  id: id,
  label: '기타',
  iconCodePoint: 0xe893,
  colorValue: 0xFF9E9E9E,
);

String _categoryToJson(Category category) => category.id;
