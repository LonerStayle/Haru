import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../domain/recurrence.dart';
import '../../domain/recurrence_materializer.dart';
import '../../domain/todo.dart' show Todo, TodoDateMode, TodoStatus, TodoType;
import '../../ui/widgets/in_progress_triangle.dart';
import '../../ui/widgets/undone_square.dart';
import '../calendar/calendar_providers.dart';
import '../calendar/calendar_settings.dart';
import '../category/categories_controller.dart';
import '../category/groups_controller.dart';
import '../outline/tree_providers.dart';
import '../recurrence/recurrence_actions.dart';

/// "빠른 추가" 입력 패널.
///
/// 책임은 입력 + 검증 + onSubmit 콜백까지. 실제 저장 (repo.upsert) 호출은 호출자
/// (phase 5 의 "추가 흐름" task) 가 담당한다.
///
/// UX 강조 (CLAUDE.md 비전): Calendar 등록은 토글 1 번이면 자동. Esc 로 취소, Enter 로 저장.
class AddTodoSheet extends ConsumerStatefulWidget {
  const AddTodoSheet({
    super.key,
    this.initialCategory = Category.daily,
    required this.onSubmit,
    this.onUpdate,
    this.onStatusChanged,
    this.initialTodo,
    this.prefillFrom,
    this.now,
    this.initialDueAt,
    this.initialAllDay = true,
    this.parentId,
    this.onRequestMove,
  });

  final Category initialCategory;

  /// Task C — non-null 이면 "하위 추가" 모드. 생성되는 todo 의 parentId 가 이 값으로
  /// 고정되고, category 는 [initialCategory] (= 부모 category) 로 프리셋된다.
  /// 카테고리 선택 UI 는 숨김 (부모와 같은 카테고리로 강제). edit 모드와는 무관.
  final String? parentId;

  /// 테스트 결정성을 위해 주입 가능. 기본 [DateTime.now].
  final DateTime Function()? now;

  /// 초기 dueAt 값. null 이면 일정 없음.
  ///
  /// v1.6 — 캘린더에서 "이 날짜로 추가" 를 하려면 날짜가 미리 채워진 채로 시트가
  /// 열려야 한다. 그래서 [show] 도 이 값을 받아 전달한다 (그 전에는 위젯 테스트가
  /// picker dialog 를 우회하는 용도로만 쓰였다).
  final DateTime? initialDueAt;

  /// [initialDueAt] 가 종일 의미인지. 기본 true.
  final bool initialAllDay;

  /// 신규 추가 모드 — submission 콜백. edit 모드 (initialTodo != null) 면 호출 안 됨.
  final void Function(AddTodoSubmission submission) onSubmit;

  /// v1.2 — edit 모드 콜백. [initialTodo] 가 non-null 일 때 _submit 이 update 분기로
  /// 호출. 호출자는 todoActionsProvider.update 또는 동등 mutation 수행.
  final FutureOr<void> Function(Todo updated)? onUpdate;

  /// 3-상태(□/△/◯) 칩 탭 전용 저장 콜백 — **[onUpdate] 와 반드시 구분**한다.
  ///
  /// 상태 변경은 의미상 목록 타일의 체크·세모 토글과 같은 행위라 **자리(sortOrder)가
  /// 튀면 안 된다**. 반면 [onUpdate] 가 태우는 `TodoActionsController.update` 는
  /// "시트에서 편집하면 맨 위로" 규칙이라 sortOrder 를 bump 한다. 그래서 호출자는 이
  /// 콜백을 `TodoActionsController.updatePreservingOrder` 로 연결해야 한다.
  ///
  /// ⚠️ RISK(side-effect): null 이면 [onUpdate] 로 폴백하므로 **조용히 bump 되는**
  /// 회귀가 된다 (그 화면에서만 상태를 바꾸면 항목이 맨 위로 튀어오른다). 시트를 여는
  /// 곳은 전부 이 콜백을 연결해 둘 것 — 폴백은 안전망일 뿐 기본 경로가 아니다.
  final void Function(Todo updated)? onStatusChanged;

  /// v1.2 — null 이면 add 모드 (기존), non-null 이면 edit 모드. _titleCtrl /
  /// _descriptionCtrl / _category / _dueAt / _type 가 모두 prefill 된다.
  final Todo? initialTodo;

  /// edit 모드의 "위치" 섹션 — 이동 버튼 콜백. 이 시트를 닫은 뒤 호출자의 context 로
  /// 이동 시트를 열게 한다 (시트 안에서 시트를 여는 대신 호출자에게 위임).
  /// null 이면 위치 섹션에 이동 버튼을 노출하지 않는다.
  final void Function(Todo item)? onRequestMove;

  /// 복사(duplicate) 용 prefill 출처. [initialTodo] 와 달리 edit 모드로 전환하지
  /// 않고 add 모드 (onSubmit) 그대로 동작하되, 제목·상세·카테고리·날짜/시간·종류 등
  /// 모든 입력값만 이 todo 로 미리 채운다. 저장 시 새 id 의 별개 todo 가 생성된다.
  /// (체크 상태 doneAt·캘린더 이벤트 calendarEventId 는 복사 대상이 아니다.)
  final Todo? prefillFrom;

  /// 멀티라인 paste 시 줄바꿈으로 split + 빈 줄 제거 → 의미 있는 줄.
  /// 단위 테스트가 직접 호출하기 위해 public static 으로 노출.
  @visibleForTesting
  static List<String> splitBulkLines(String raw) =>
      raw.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  /// modal bottom sheet 로 띄우는 헬퍼.
  ///
  /// add 모드: [initialTodo] null + [onSubmit] 만. edit 모드: [initialTodo] non-null
  /// + [onUpdate] 콜백 — 호출자가 todoActionsProvider.update 호출.
  ///
  /// v1.6 — [initialDueAt] / [initialAllDay] 를 받는다. 캘린더에서 날짜 칸을 길게
  /// 눌러 "이 날짜로 추가" 할 때 날짜 입력 단계를 통째로 생략하기 위한 것.
  /// 기본값은 종전 위젯 기본값과 같아 기존 호출처의 동작은 변하지 않는다.
  static Future<void> show(
    BuildContext context, {
    Category initialCategory = Category.daily,
    required void Function(AddTodoSubmission) onSubmit,
    FutureOr<void> Function(Todo updated)? onUpdate,
    void Function(Todo updated)? onStatusChanged,
    Todo? initialTodo,
    Todo? prefillFrom,
    String? parentId,
    void Function(Todo item)? onRequestMove,
    DateTime? initialDueAt,
    bool initialAllDay = true,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // 데스크탑은 넓은 창 전폭으로 펼쳐지면 입력칸·칩이 한 줄에 흩어진다 → 가운데 640.
      constraints: AppPlatform.isDesktop
          ? const BoxConstraints(maxWidth: 640)
          : null,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: AddTodoSheet(
          initialCategory: initialCategory,
          onSubmit: onSubmit,
          onUpdate: onUpdate,
          onStatusChanged: onStatusChanged,
          initialTodo: initialTodo,
          prefillFrom: prefillFrom,
          parentId: parentId,
          onRequestMove: onRequestMove,
          initialDueAt: initialDueAt,
          initialAllDay: initialAllDay,
        ),
      ),
    );
  }

  @override
  ConsumerState<AddTodoSheet> createState() => _AddTodoSheetState();
}

class _AddTodoSheetState extends ConsumerState<AddTodoSheet> {
  late final TextEditingController _titleCtrl;

  /// 여러 줄 붙여넣기를 취소했을 때 되돌릴 "붙여넣기 직전" 제목.
  String _titleBeforePaste = '';
  late final TextEditingController _descriptionCtrl;
  late Category _category;

  /// 작업 1 가드 — [_category] 가 "신뢰 가능한 선택"인지.
  ///
  /// true 인 경우: edit 모드의 initialTodo.category (이미 영속된 값), 또는 사용자가
  /// 칩으로 명시 선택한 값. 이 경우 categoriesProvider 가 동기화 race 로 그 카테고리를
  /// 아직 모르더라도 자동 보정(categories.first 로 리셋)을 하지 않는다 — 안 그러면
  /// "카테고리 변경이 저장 후 원래대로 돌아오는" 증상이 된다.
  ///
  /// false 인 경우: add 모드의 initialCategory 기본값처럼 임시 선택 — 진짜 고아면
  /// 첫 항목으로 보정해도 무해.
  bool _categoryTrusted = false;

  DateTime? _dueAt;

  /// dueAt 의 시간 지정 여부. true = 하루 종일 (시간 부분 의미 없음, 00:00 보관).
  /// false = 시간이 의미 있는 todo (`_dueAt` 의 시각 그대로).
  bool _allDay = true;
  bool _addToCalendar = false;

  /// fast-tasks — 날짜 입력 모드. 단일 3 모드(하루종일/시작/마감) + 기간.
  _DateInputMode _dateMode = _DateInputMode.allDay;

  /// 기간 모드의 종료 시각. _dateMode == range 일 때만 의미.
  DateTime? _endAt;

  /// 기간 모드에서 양끝 시간 표시 여부 (true = 하루종일 기간).
  bool _rangeAllDay = true;

  /// v1.1 — 추가할 항목의 종류. note 면 일정/캘린더 영역은 비활성 (의미 없음).
  TodoType _type = TodoType.task;

  /// 편집 중인 항목의 3-상태 원본값 — 시트가 들고 있는 doneAt / startedAt.
  ///
  /// ⚠️ RISK(race): 이 둘을 굳이 state 로 들고 있는 이유가 있다. 상태 칩(□/△/◯) 탭은
  /// **즉시 저장**인데, [_applyEdit] 가 `widget.initialTodo`(시트를 열던 순간의 옛
  /// 스냅샷)를 그대로 베이스로 쓰면 시트를 닫는 순간의 자동 저장이 방금 바꾼 상태를
  /// 옛 값으로 되돌린다. 두 저장 경로가 같은 값을 보도록 베이스를 여기로 모은다.
  /// (타임스탬프까지 그대로 재사용해야 무변경 판정이 서고 헛저장이 안 생긴다.)
  DateTime? _doneAt;
  DateTime? _startedAt;

  /// date-repeat — 반복 주기. null = 반복 안 함(단발). non-null 이면 마스터로 저장.
  /// 추가 모드 전용 (편집 모드에서 규칙 수정은 별도 동작 — PRD FR-6).
  RecurrenceFreq? _recurrenceFreq;

  /// 반복 N간격 (1 이상). 예: weekly + 2 = 격주.
  int _recurrenceInterval = 1;

  /// weekly 전용 — 반복 요일 집합(1=월..7=일). 비면 anchor 요일.
  final Set<int> _recurrenceWeekdays = {};

  /// 반복 종료일(선택). null = 무한.
  DateTime? _recurrenceEndAt;

  /// UX Phase 1 — 2단 시트의 "더보기"(설명·기간·반복·캘린더·상태·위치) 펼침.
  /// 기본 접힘. 그 칸을 이미 쓰고 있는 항목(설명 있음 / 기간 / 반복)은 펼친 채 연다.
  bool _showMore = false;

  /// edit 모드 (initialTodo != null) 여부 — 시그니처 / 버튼 라벨 / submit 분기 사용.
  bool get _isEditMode => widget.initialTodo != null;

  /// 시트가 현재 들고 있는 3-상태. 상태 섹션의 채움 표시와 전이 계산의 기준.
  TodoStatus get _status {
    if (_doneAt != null) return TodoStatus.done;
    if (_startedAt != null) return TodoStatus.inProgress;
    return TodoStatus.undone;
  }

  /// Task C — "하위 추가" 모드 (parentId 지정 + edit 아님). 카테고리 선택 UI 를 숨기고
  /// 부모 category 로 프리셋한다.
  bool get _isChildMode => !_isEditMode && widget.parentId != null;

  /// 헤더의 카테고리 드롭다운. 열려 있으면 Esc·뒤로가기는 메뉴만 닫는다(시트 유지).
  final MenuController _categoryMenu = MenuController();
  bool _categoryMenuOpen = false;

  /// 더블 submit race 가드. _submit 이 한 번이라도 호출되면 true 로 set 되어 후속
  /// tap / Enter 가 추가 onSubmit 콜백 호출을 못 하게 막는다.
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    // prefill 출처 — edit 모드의 initialTodo, 또는 복사 모드의 prefillFrom.
    // 어느 쪽이든 입력값을 그대로 채운다. (단 _isEditMode 는 initialTodo 만으로 결정.)
    final source = widget.initialTodo ?? widget.prefillFrom;
    _titleCtrl = TextEditingController(text: source?.title ?? '');
    _titleBeforePaste = _titleCtrl.text;
    _descriptionCtrl = TextEditingController(text: source?.description ?? '');
    _category = source?.category ?? widget.initialCategory;
    // prefill 카테고리(edit/복사 공통)는 이미 영속된 실제 값 → 신뢰. add 기본값은 미신뢰.
    _categoryTrusted = source != null;
    // 동기화로 들어온 값은 UTC 다 — 시트는 로컬 달력 기준으로 다룬다. (UTC 그대로
    // 연·월·일을 읽으면 한국 종일 항목이 전날이 되고, 열었다 닫기만 해도 하루 당겨져
    // 저장됐다.) 저장 때 같은 시각이면 원본 인스턴스를 돌려 써 헛저장을 막는다.
    _dueAt = (source?.dueAt ?? widget.initialDueAt)?.toLocal();
    _allDay = widget.initialAllDay;
    _type = source?.type ?? TodoType.task;
    // 3-상태는 편집 대상에서만 가져온다 — 복사(prefillFrom)는 체크·진행 표식을
    // 물려받지 않는다 (복사본은 항상 새 미완료 항목).
    _doneAt = widget.initialTodo?.doneAt;
    _startedAt = widget.initialTodo?.startedAt;
    _restoreDateMode(source);
    // 더보기 칸을 이미 쓰는 항목은 펼친 채로 — 숨은 값을 모르고 지나치지 않게.
    // (메모는 본문이 1단에 있으므로 설명만으로는 펼치지 않는다.)
    _showMore =
        (_type == TodoType.task && (source?.description ?? '').isNotEmpty) ||
        _dateMode == _DateInputMode.range ||
        (widget.initialTodo?.isInRecurringSeries ?? false);
    // 캘린더 토글의 초기값 — 편집 모드는 이미 등록돼 있으면 켠 채로 열고,
    // 새 항목은 마지막 선택([CalendarSettings.defaultAddToCalendar])을 이어간다.
    // 시트를 열 때마다 매번 꺼져 있으면 등록하려던 걸 자주 놓친다.
    _addToCalendar =
        widget.initialTodo?.calendarEventId != null ||
        ref.read(calendarSettingsProvider).defaultAddToCalendar;
  }

  /// edit 모드 — initialTodo 의 날짜·기간 필드로 모드/상태 복원.
  /// add 모드 (initial == null) 면 initialDueAt/initialAllDay 만 반영.
  void _restoreDateMode(Todo? initial) {
    if (initial == null) {
      // add 모드 — 기존 단일 흐름. dueAt 이 있고 시간이 있으면 시작시간 모드.
      _dateMode = (_dueAt != null && !_allDay)
          ? _DateInputMode.startTime
          : _DateInputMode.allDay;
      return;
    }
    switch (initial.dateMode) {
      case TodoDateMode.none:
        _dateMode = _DateInputMode.allDay;
        _allDay = true;
      case TodoDateMode.allDay:
        _dateMode = _DateInputMode.allDay;
        _allDay = true;
      case TodoDateMode.startTime:
        _dateMode = _DateInputMode.startTime;
        _allDay = false;
      case TodoDateMode.endTime:
        _dateMode = _DateInputMode.endTime;
        _allDay = false;
      case TodoDateMode.range:
        _dateMode = _DateInputMode.range;
        _endAt = initial.endAt?.toLocal();
        _rangeAllDay = initial.isAllDay;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descriptionCtrl.dispose();
    super.dispose();
  }

  // ── date-repeat — 반복 규칙 핸들러 ─────────────────────────────────────────
  void _setRecurrenceFreq(RecurrenceFreq? freq) {
    setState(() {
      _recurrenceFreq = freq;
      if (freq == null) {
        // 반복 해제 — 부속 상태 초기화.
        _recurrenceInterval = 1;
        _recurrenceWeekdays.clear();
        _recurrenceEndAt = null;
      } else if (freq == RecurrenceFreq.weekly && _recurrenceWeekdays.isEmpty) {
        // 매주 선택 시 기본으로 dueAt 요일을 켜둔다(빈 집합도 허용되지만 시각 신호).
        final d = _dueAt;
        if (d != null) _recurrenceWeekdays.add(d.weekday);
      }
    });
  }

  void _setRecurrenceInterval(int value) {
    setState(() => _recurrenceInterval = value < 1 ? 1 : value);
  }

  void _toggleRecurrenceWeekday(int weekday) {
    setState(() {
      if (_recurrenceWeekdays.contains(weekday)) {
        _recurrenceWeekdays.remove(weekday);
      } else {
        _recurrenceWeekdays.add(weekday);
      }
    });
  }

  Future<void> _pickRecurrenceEnd() async {
    final base = _recurrenceEndAt ?? _dueAt ?? (widget.now ?? DateTime.now)();
    final picked = await _pickDate(base);
    if (picked != null) {
      setState(
        () =>
            _recurrenceEndAt = DateTime(picked.year, picked.month, picked.day),
      );
    }
  }

  /// 현재 모드/state → 직렬화 4-tuple. note 면 모두 무효 (dueAt=null).
  /// 기간 모드에서 종료 < 시작 이면 [_DateSerialized.invalid] 가 true.
  _DateSerialized _serializeDate() {
    if (_type == TodoType.note || _dueAt == null) {
      return const _DateSerialized(dueAt: null);
    }
    switch (_dateMode) {
      case _DateInputMode.allDay:
        final d = _dueAt!;
        return _DateSerialized(
          dueAt: DateTime(d.year, d.month, d.day),
          isAllDay: true,
        );
      case _DateInputMode.startTime:
        return _DateSerialized(dueAt: _dueAt, timeAnchor: 'start');
      case _DateInputMode.endTime:
        return _DateSerialized(dueAt: _dueAt, timeAnchor: 'end');
      case _DateInputMode.range:
        final end = _endAt;
        if (end == null) {
          // 종료 미지정 — 단일 하루종일로 안전 처리.
          final d = _dueAt!;
          return _DateSerialized(
            dueAt: DateTime(d.year, d.month, d.day),
            isAllDay: true,
          );
        }
        final start = _rangeAllDay
            ? DateTime(_dueAt!.year, _dueAt!.month, _dueAt!.day)
            : _dueAt!;
        final finish = _rangeAllDay
            ? DateTime(end.year, end.month, end.day)
            : end;
        return _DateSerialized(
          dueAt: start,
          endAt: finish,
          isAllDay: _rangeAllDay,
          invalid: finish.isBefore(start),
        );
    }
  }

  bool get _rangeInvalid =>
      _type == TodoType.task &&
      _dateMode == _DateInputMode.range &&
      _serializeDate().invalid;

  bool get _canSubmit =>
      !_submitted && _titleCtrl.text.trim().isNotEmpty && !_rangeInvalid;

  /// edit 모드 — 현재 입력값으로 updated Todo 를 만들어 [AddTodoSheet.onUpdate] 에
  /// 전달한다. pop 은 하지 않는다 — 저장 버튼 경로는 [_submit] 이, 배경 탭/드래그/Esc
  /// 등 닫힘 경로는 build 의 PopScope 훅이 각각 책임진다.
  void _applyEdit() {
    final updated = _editedSnapshot();
    if (updated == null) return;
    // 이번 저장의 등록 의사를 데코레이터에 알린다 — 토글을 켜면 등록, 끄면 등록 안 함.
    ref.read(calendarIntentProvider)(_addToCalendar);
    widget.onUpdate?.call(updated);
  }

  /// 시트 입력값을 반영한 편집본. edit 모드가 아니면 null.
  Todo? _editedSnapshot() {
    final initial = widget.initialTodo;
    if (initial == null) return null;
    final isNote = _type == TodoType.note;
    final trimmedDesc = _descriptionCtrl.text.trim();
    final descOrNull = trimmedDesc.isEmpty ? null : trimmedDesc;
    final date = _serializeDate();
    // 카테고리를 바꿨고 이 항목이 하위(자식)였다면 → 부모에서 분리해 새 카테고리의
    // 최상위로 올린다. (자식은 parentId 로 부모 밑에 고정되므로, 분리하지 않으면
    // 카테고리만 바뀌고 화면상 부모 아래 그대로 남아 "이동이 안 되는" 것처럼 보인다.)
    final movedCategory = _category.id != initial.category.id;
    final detach = movedCategory && initial.parentId != null;
    // 같은 시각이면 원본 인스턴스 그대로 — 로컬/UTC 표현 차이만으로 "바뀜" 판정이
    // 나 헛저장·자리 튐이 생기지 않게.
    DateTime? same(DateTime? next, DateTime? orig) =>
        (next != null && orig != null && next.isAtSameMomentAs(orig))
        ? orig
        : next;
    final dueAt = same(date.dueAt, initial.dueAt);
    // 그 모양에서 의미 없는 필드는 원본 값을 유지한다 — 일정 없음이면 종일 여부,
    // 종일이면 시작/마감 기준. (캘린더에서 들어온 '종일 + 마감' 같은 조합이 열었다
    // 닫기만 해도 바뀌어 저장되던 문제.)
    final isAllDay = dueAt == null ? initial.isAllDay : date.isAllDay;
    final timeAnchor = (dueAt == null || date.isAllDay)
        ? initial.timeAnchor
        : date.timeAnchor;
    final updated = initial.copyWith(
      title: _titleCtrl.text.trim(),
      category: _category,
      dueAt: dueAt,
      endAt: same(date.endAt, initial.endAt),
      isAllDay: isAllDay,
      timeAnchor: timeAnchor,
      type: _type,
      description: descOrNull,
      parentId: detach ? null : initial.parentId,
      // §14-C — task→note 전환 시 doneAt 제거. note 는 체크 개념이 없어 옛 doneAt 이
      // 남으면 note→task 복귀 때 갑자기 완료로 표시되는 사고가 난다.
      // (dueAt/isAllDay 는 _serializeDate 가 note 일 때 이미 null/false 로 비운다.)
      // 3-상태는 initial(옛 스냅샷)이 아니라 시트가 들고 있는 값을 쓴다 — 상태 칩의
      // 즉시 저장이 닫힘 저장에 덮여 되돌아가지 않게 하는 지점이다.
      doneAt: isNote ? null : _doneAt,
      // 진행중 표식도 note 전환 시 제거 (note 는 진행 개념 없음).
      startedAt: isNote ? null : _startedAt,
      // ⚠️ RISK(side-effect): note 전환 시에도 calendarEventId 를 **남긴다**.
      // 여기서 미리 지우면 저장소 데코레이터가 링크를 못 봐서 삭제 작업을 만들지
      // 못하고, 구글 캘린더에 고아 이벤트가 남는다 (기존 결함이 정확히 그것이었다).
      // 링크 해제는 이벤트를 실제로 지운 뒤 동기화 서비스가 한다.
      calendarEventId: initial.calendarEventId,
    );
    return updated;
  }

  void _submit() {
    if (_submitted || _titleCtrl.text.trim().isEmpty || _rangeInvalid) return;
    _submitted = true;

    // edit 모드 — onUpdate 콜백 호출 (updatedAt 갱신은 호출자/Controller 책임).
    if (_isEditMode) {
      _applyEdit();
      Navigator.of(context).maybePop();
      return;
    }

    final isNote = _type == TodoType.note;
    final trimmedDesc = _descriptionCtrl.text.trim();
    final descOrNull = trimmedDesc.isEmpty ? null : trimmedDesc;
    final date = _serializeDate();

    final recurrence = _buildRecurrence(isNote: isNote, dueAt: date.dueAt);

    // add 모드 — note 는 일정/캘린더 모두 강제 null/false.
    widget.onSubmit(
      AddTodoSubmission(
        title: _titleCtrl.text.trim(),
        category: _category,
        dueAt: date.dueAt,
        endAt: date.endAt,
        isAllDay: date.isAllDay,
        timeAnchor: date.timeAnchor,
        addToCalendar: !isNote && date.dueAt != null && _addToCalendar,
        type: _type,
        description: descOrNull,
        parentId: widget.parentId,
        recurrence: recurrence,
        recurrenceEndAt: recurrence == null ? null : _recurrenceEndAt,
      ),
    );
    Navigator.of(context).maybePop();
  }

  /// date-repeat — 반복 규칙(추가 모드 + task + 주기 선택 시). dueAt 없으면 무의미.
  /// 단건 추가와 일괄 추가가 같은 규칙을 쓰도록 한 곳에 둔다.
  RecurrenceRule? _buildRecurrence({
    required bool isNote,
    required DateTime? dueAt,
  }) {
    if (isNote || _recurrenceFreq == null || dueAt == null) return null;
    return RecurrenceRule(
      freq: _recurrenceFreq!,
      interval: _recurrenceInterval < 1 ? 1 : _recurrenceInterval,
      byWeekday: _recurrenceFreq == RecurrenceFreq.weekly
          ? {..._recurrenceWeekdays}
          : const {},
    );
  }

  /// 같은 카테고리 / parent / dueAt / type 으로 N건 일괄 추가. _submitted race 가드.
  /// v1.1 첫 cut — 평탄 (들여쓰기 인식 X). 들여쓰기 자동 트리화는 v1.2.
  void _submitBulk(List<String> titles) {
    if (_submitted || titles.isEmpty || _rangeInvalid) return;
    _submitted = true;
    final isNote = _type == TodoType.note;
    final trimmedDesc = _descriptionCtrl.text.trim();
    final descOrNull = trimmedDesc.isEmpty ? null : trimmedDesc;
    final date = _serializeDate();
    // 일괄 추가도 반복 설정을 유지한다 (예전엔 조용히 빠졌다 — UX 감사 B10).
    final recurrence = _buildRecurrence(isNote: isNote, dueAt: date.dueAt);
    for (final t in titles) {
      widget.onSubmit(
        AddTodoSubmission(
          title: t,
          category: _category,
          dueAt: date.dueAt,
          endAt: date.endAt,
          isAllDay: date.isAllDay,
          timeAnchor: date.timeAnchor,
          addToCalendar: !isNote && date.dueAt != null && _addToCalendar,
          type: _type,
          description: descOrNull,
          parentId: widget.parentId,
          recurrence: recurrence,
          recurrenceEndAt: recurrence == null ? null : _recurrenceEndAt,
        ),
      );
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  /// TextField onChanged 콜백. 멀티라인 paste 면 confirm dialog → bulk submit.
  /// 단일 라인 입력은 일반 setState 만 (추가 버튼 활성화 토글).
  Future<void> _onTitleChanged(String value) async {
    if (!value.contains('\n')) {
      _titleBeforePaste = value;
      setState(() {});
      return;
    }
    final lines = AddTodoSheet.splitBulkLines(value);
    if (lines.length < 2) {
      // 빈 줄 + 단일 줄 케이스 — \n 제거 후 단일 todo 흐름 유지.
      _titleCtrl.text = lines.isEmpty ? '' : lines.first;
      _titleCtrl.selection = TextSelection.collapsed(
        offset: _titleCtrl.text.length,
      );
      setState(() {});
      return;
    }
    // 멀티라인 — 사용자 확인 후 일괄 추가.
    final ok = await _confirmBulkAdd(lines.length);
    if (!mounted) return;
    if (ok != true) {
      // 취소 = 붙여넣기 취소 — 붙여넣기 직전 입력으로 되돌린다. (예전엔 줄들을 공백으로
      // 이어 붙인 긴 제목 하나가 남아 사용자가 다시 지워야 했다 — UX 감사 B10.)
      _titleCtrl.text = _titleBeforePaste;
      _titleCtrl.selection = TextSelection.collapsed(
        offset: _titleCtrl.text.length,
      );
      setState(() {});
      return;
    }
    _submitBulk(lines);
  }

  Future<bool?> _confirmBulkAdd(int n) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('bulk-paste-dialog'),
        title: const Text('일괄 추가'),
        content: Text('$n개의 항목을 같은 카테고리·일정·반복으로 한 번에 추가할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('bulk-paste-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('$n건 추가'),
          ),
        ],
      ),
    );
  }

  /// 상태 칩(□ 미완료 / △ 진행중 / ◯ 완료) 탭 — **즉시 저장**.
  ///
  /// 시트를 닫지 않아도 목록에 바로 반영된다. 전이 규칙(불변식: startedAt/doneAt
  /// 동시 세팅 금지)은 도메인 헬퍼 [Todo.withStatus] 하나에만 두고, 계산 결과를 시트
  /// state 로 받아 둔다 — 그래야 나중의 닫힘 저장이 같은 값을 그대로 써서 헛저장 없이
  /// no-op 으로 걸러지고, 보존된 sortOrder 가 그 no-op 덕에 다시 bump 되지 않는다.
  ///
  /// 넘기는 값은 **저장된 스냅샷에서 상태만 바꾼 것**이다 — 시트에 입력 중인 제목·
  /// 카테고리 등은 싣지 않는다. 그건 내용 편집이라 "맨 위로" 규칙이 적용되는 [_applyEdit]
  /// (닫힘 저장 / 저장 버튼) 의 몫이고, 여기 섞으면 상태 탭이 그 규칙까지 끌고 온다.
  void _setStatus(TodoStatus next) {
    final initial = widget.initialTodo;
    if (initial == null || _type == TodoType.note || _status == next) return;
    final applied = initial
        .copyWith(doneAt: _doneAt, startedAt: _startedAt)
        .withStatus(next, now: widget.now);
    setState(() {
      _doneAt = applied.doneAt;
      _startedAt = applied.startedAt;
    });
    // 순서 보존 경로로 저장한다. onStatusChanged 미연결 시의 onUpdate 폴백은 안전망일
    // 뿐 — 그 경로로 가면 sortOrder 가 bump 되어 항목이 맨 위로 튄다.
    (widget.onStatusChanged ?? widget.onUpdate)?.call(applied);
  }

  /// task ↔ note 토글. note 로 바꿀 때는 일정 관련 state 를 안전하게 reset.
  void _setType(TodoType t) {
    if (t == _type) return;
    setState(() {
      _type = t;
      if (t == TodoType.note) {
        _dueAt = null;
        _endAt = null;
        _allDay = true;
        _dateMode = _DateInputMode.allDay;
        _addToCalendar = false;
      }
    });
  }

  /// fast-tasks — 4 모드 (하루종일/시작시간/마감시간/기간) 선택.
  void _setDateMode(_DateInputMode mode) {
    if (mode == _dateMode) return;
    setState(() {
      _dateMode = mode;
      switch (mode) {
        case _DateInputMode.allDay:
          _allDay = true;
          _endAt = null;
          if (_dueAt != null) {
            _dueAt = DateTime(_dueAt!.year, _dueAt!.month, _dueAt!.day);
          }
        case _DateInputMode.startTime:
        case _DateInputMode.endTime:
          // 단일·시간 모드 — 기존 시간 유지, 없으면 09:00 디폴트로 채움.
          _endAt = null;
          _allDay = false;
          final base = _dueAt ?? (widget.now ?? DateTime.now)();
          if (_dueAt == null || _isMidnight(_dueAt!)) {
            _dueAt = DateTime(base.year, base.month, base.day, 9, 0);
          }
        case _DateInputMode.range:
          final base = _dueAt ?? (widget.now ?? DateTime.now)();
          if (_dueAt != null && !_allDay) {
            // 시간까지 정해 둔 일정 → 그 시각부터 1시간짜리 기간 (시간 유지).
            _endAt = base.add(const Duration(hours: 1));
            _rangeAllDay = false;
          } else {
            // 날짜만 → 시작일부터 다음날까지 종일 기간.
            final startDay = DateTime(base.year, base.month, base.day);
            _dueAt = startDay;
            _endAt = startDay.add(const Duration(days: 1));
            _rangeAllDay = true;
            _allDay = true;
          }
      }
    });
  }

  static bool _isMidnight(DateTime d) => d.hour == 0 && d.minute == 0;

  /// 날짜만 받는다 — 시간 picker 는 강제하지 않고, 기본은 "하루 종일".
  /// 사용자가 시간이 필요하면 [_pickTime] 액션 또는 [_DueRow] 의 시간 칩으로 추가.
  Future<void> _pickDueDate() async {
    final nowFn = widget.now ?? DateTime.now;
    final base = _dueAt ?? nowFn();
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(nowFn().year - 1),
      lastDate: DateTime(nowFn().year + 3),
    );
    if (date == null || !mounted) return;
    setState(() {
      // 시간을 이미 지정해 둔 채로 날짜만 다시 고르는 경우 → 시간 보존.
      if (_dueAt != null && !_allDay) {
        _dueAt = DateTime(
          date.year,
          date.month,
          date.day,
          _dueAt!.hour,
          _dueAt!.minute,
        );
      } else {
        _dueAt = DateTime(date.year, date.month, date.day);
        _allDay = true;
      }
    });
  }

  Future<void> _pickTime() async {
    final base = _dueAt ?? (widget.now ?? DateTime.now)();
    final initial = _allDay
        ? const TimeOfDay(hour: 9, minute: 0)
        : TimeOfDay.fromDateTime(base);
    final time = await _showTime(initial);
    if (time == null || !mounted) return;
    setState(() {
      final d = _dueAt ?? base;
      _dueAt = DateTime(d.year, d.month, d.day, time.hour, time.minute);
      _allDay = false;
      // 단일 모드에서 시간을 지정하면 시작/마감 anchor 모드로. 이미 마감 모드면 유지.
      if (_dateMode == _DateInputMode.allDay) {
        _dateMode = _DateInputMode.startTime;
      }
    });
  }

  /// 시간 입력 — 데스크탑은 키보드로 "14:30" 을 바로 치는 입력 모드로 연다
  /// (다이얼을 마우스로 돌리는 건 느리다). 폰은 다이얼.
  Future<TimeOfDay?> _showTime(TimeOfDay initial) => showTimePicker(
    context: context,
    initialTime: initial,
    initialEntryMode: AppPlatform.isDesktop
        ? TimePickerEntryMode.input
        : TimePickerEntryMode.dial,
  );

  /// 시간이 있는 단일 일정의 기준 — 그 시각에 "시작" 인지 그 시각 "까지(마감)" 인지.
  void _setTimeAnchor({required bool end}) {
    if (_allDay || _dueAt == null) return;
    setState(
      () => _dateMode = end ? _DateInputMode.endTime : _DateInputMode.startTime,
    );
  }

  /// 기간 끄기 — 시작 날짜만 남긴 단일 일정으로.
  void _clearRange() {
    setState(() {
      _endAt = null;
      _allDay = _rangeAllDay || _dueAt == null;
      _dateMode = _allDay ? _DateInputMode.allDay : _DateInputMode.startTime;
    });
  }

  void _makeAllDay() {
    final d = _dueAt;
    if (d == null) return;
    setState(() {
      _dueAt = DateTime(d.year, d.month, d.day);
      _allDay = true;
      _dateMode = _DateInputMode.allDay;
    });
  }

  void _clearDueAt() {
    setState(() {
      _dueAt = null;
      _endAt = null;
      _allDay = true;
      _dateMode = _DateInputMode.allDay;
      _addToCalendar = false;
    });
  }

  /// 빠른 날짜 칩 — 날짜만 바꾼다. 이미 시간을 정해 뒀으면 그 시간은 유지한다
  /// (날짜 → 시간 순서든 시간 → 날짜 순서든 결과가 같게).
  /// 같은 칩을 다시 누르면 토글 해제 (= 일정 비우기).
  void _setQuickDate(DateTime date) {
    final d0 = DateTime(date.year, date.month, date.day);
    final cur = _dueAt;
    if (cur != null && _isSameDate(cur, d0)) {
      // 같은 칩 다시 누르기 = 해제 — 단, 날짜만 있는 단일 일정일 때만. 시간·기간이
      // 있으면 확인하려고 누른 것일 수 있어 아무것도 지우지 않는다.
      if (_dateMode != _DateInputMode.range && _allDay) _clearDueAt();
      return;
    }
    setState(() {
      if (_dateMode == _DateInputMode.range) {
        // 기간이면 시작을 옮기고 길이는 유지한다.
        final span = (_endAt != null && cur != null)
            ? _endAt!.difference(cur)
            : const Duration(days: 1);
        _dueAt = (cur != null && !_rangeAllDay)
            ? DateTime(d0.year, d0.month, d0.day, cur.hour, cur.minute)
            : d0;
        _endAt = _dueAt!.add(span);
        return;
      }
      _dueAt = (cur != null && !_allDay)
          ? DateTime(d0.year, d0.month, d0.day, cur.hour, cur.minute)
          : d0;
    });
  }

  static bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  // ── 기간 모드 picker 들 ───────────────────────────────────────────────
  Future<DateTime?> _pickDate(DateTime base) async {
    final nowFn = widget.now ?? DateTime.now;
    return showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(nowFn().year - 1),
      lastDate: DateTime(nowFn().year + 3),
    );
  }

  Future<void> _pickRangeStartDate() async {
    final d = await _pickDate(_dueAt ?? (widget.now ?? DateTime.now)());
    if (d == null || !mounted) return;
    setState(() {
      final cur = _dueAt;
      _dueAt = (cur != null && !_rangeAllDay)
          ? DateTime(d.year, d.month, d.day, cur.hour, cur.minute)
          : DateTime(d.year, d.month, d.day);
    });
  }

  /// 기간 모드의 📅 칩 — 고른 날로 기간을 통째로 옮긴다(길이 유지). 시작만 옮기면
  /// 종료보다 뒤가 되어 저장이 막힐 수 있다.
  Future<void> _pickRangeShift() async {
    final d = await _pickDate(_dueAt ?? (widget.now ?? DateTime.now)());
    if (d == null || !mounted) return;
    // 같은 날을 골랐어도 해제되지 않게 _setQuickDate 대신 직접 옮긴다.
    final cur = _dueAt;
    if (cur != null && _isSameDate(cur, d)) return;
    _setQuickDate(d);
  }

  Future<void> _pickRangeEndDate() async {
    final d = await _pickDate(
      _endAt ?? _dueAt ?? (widget.now ?? DateTime.now)(),
    );
    if (d == null || !mounted) return;
    setState(() {
      final cur = _endAt;
      _endAt = (cur != null && !_rangeAllDay)
          ? DateTime(d.year, d.month, d.day, cur.hour, cur.minute)
          : DateTime(d.year, d.month, d.day);
    });
  }

  Future<void> _pickRangeStartTime() async {
    final base = _dueAt ?? (widget.now ?? DateTime.now)();
    final time = await _showTime(TimeOfDay.fromDateTime(base));
    if (time == null || !mounted) return;
    setState(() {
      final wasAllDay = _rangeAllDay;
      _rangeAllDay = false;
      _dueAt = DateTime(
        base.year,
        base.month,
        base.day,
        time.hour,
        time.minute,
      );
      // 종일 기간에 시간을 처음 넣으면 종료도 시각을 받는다 — 그대로 두면 종료가
      // "마지막 날 00:00" 이 되어 마지막 날이 통째로 빠진다.
      final end = _endAt;
      if (wasAllDay && end != null) {
        _endAt = DateTime(
          end.year,
          end.month,
          end.day,
          time.hour,
          time.minute,
        ).add(const Duration(hours: 1));
      }
    });
  }

  Future<void> _pickRangeEndTime() async {
    final base = _endAt ?? _dueAt ?? (widget.now ?? DateTime.now)();
    final time = await _showTime(TimeOfDay.fromDateTime(base));
    if (time == null || !mounted) return;
    setState(() {
      _rangeAllDay = false;
      _endAt = DateTime(
        base.year,
        base.month,
        base.day,
        time.hour,
        time.minute,
      );
    });
  }

  void _toggleRangeAllDay() {
    setState(() {
      _rangeAllDay = !_rangeAllDay;
      if (_rangeAllDay) {
        if (_dueAt != null) {
          _dueAt = DateTime(_dueAt!.year, _dueAt!.month, _dueAt!.day);
        }
        if (_endAt != null) {
          _endAt = DateTime(_endAt!.year, _endAt!.month, _endAt!.day);
        }
      }
    });
  }

  DateTime _today() {
    final now = (widget.now ?? DateTime.now)();
    return DateTime(now.year, now.month, now.day);
  }

  /// "위치" 섹션의 이동 버튼 — 편집 내용을 **먼저 저장 완료**한 뒤 시트를 닫고
  /// 호출자가 이동 시트를 열게 한다.
  ///
  /// 예전엔 편집 내용을 버렸다 (UX 감사: "이동 누르면 방금 고친 제목이 사라진다").
  /// 버린 이유는 한 row 를 두 writer(닫힘 저장 / 이동)가 동시에 쓰는 경쟁이었다 —
  /// 이동 전 위치를 든 저장이 이동보다 늦게 도착하면 이동을 되돌렸다.
  /// 이제는 두 쓰기를 **순차**로 만든다: 편집 저장을 await 로 끝낸 뒤에야 이동 시트를
  /// 연다. 이동 시트는 사용자가 목적지를 고른 시점의 최신 row(편집 반영본)로 옮기므로
  /// (`showMoveTodoSheet` 의 live 조회) 같은 row 에 겹치는 쓰기가 없다.
  Future<void> _requestMove() async {
    final initial = widget.initialTodo;
    final callback = widget.onRequestMove;
    if (initial == null || callback == null || _submitted) return;
    // 닫힘 자동 저장은 끈다 — 아래에서 직접 한 번만 저장한다 (중복 writer 방지).
    _submitted = true;
    final edited = _editedSnapshot();
    final canSave =
        edited != null && _titleCtrl.text.trim().isNotEmpty && !_rangeInvalid;
    if (canSave) {
      ref.read(calendarIntentProvider)(_addToCalendar);
      // 무변경이면 update 의 _isUnchanged 가드가 no-op 으로 거른다 (자리 튐 없음).
      await widget.onUpdate?.call(edited);
    }
    if (!mounted) return;
    Navigator.of(context).maybePop();
    callback(canSave ? edited : initial);
  }

  Widget _descriptionField({required String hint}) => TextField(
    key: const ValueKey('add-todo-description'),
    controller: _descriptionCtrl,
    minLines: 3,
    maxLines: 8,
    maxLength: 5000,
    keyboardType: TextInputType.multiline,
    onChanged: (_) => setState(() {}),
    decoration: InputDecoration(
      hintText: hint,
      border: const OutlineInputBorder(),
      counterText: '',
    ),
  );

  /// 접힌 "더보기" 옆에 보일 요약 — 켜 둔 숨은 설정을 모르고 지나치지 않게.
  String? _moreSummary() {
    final parts = <String>[
      if (_type == TodoType.task && _descriptionCtrl.text.trim().isNotEmpty)
        '설명',
      if (_type == TodoType.task && _dueAt != null && _addToCalendar) '캘린더',
      if (_type == TodoType.task && _dueAt != null && _recurrenceFreq != null)
        '반복',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// 2단 "더보기" 내용 — 설명 · 기간 · 캘린더 등록 · 반복 · 상태 · 위치.
  List<Widget> _moreChildren() {
    final isTask = _type == TodoType.task;
    final initial = widget.initialTodo;
    return [
      if (isTask) ...[
        const SizedBox(height: AppTokens.space12),
        _SectionLabel(text: '설명'),
        const SizedBox(height: AppTokens.space8),
        _descriptionField(hint: '자세한 내용 (선택)'),
      ],
      // 기간 — 시작 날짜가 정해진 뒤에 "종료" 를 붙이는 방식.
      if (isTask && _dueAt != null && _dateMode != _DateInputMode.range) ...[
        const SizedBox(height: AppTokens.space12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('add-todo-add-end'),
            onPressed: () => _setDateMode(_DateInputMode.range),
            icon: const Icon(Icons.date_range_outlined, size: 16),
            label: const Text('종료 날짜 추가 (기간)'),
          ),
        ),
      ],
      if (isTask && _dueAt != null) ...[
        const SizedBox(height: AppTokens.space12),
        _CalendarToggle(
          value: _addToCalendar,
          onChanged: (v) {
            setState(() => _addToCalendar = v);
            // 다음에 시트를 열 때 이 선택을 이어간다.
            ref
                .read(calendarSettingsProvider.notifier)
                .update((s) => s.copyWith(defaultAddToCalendar: v));
          },
        ),
      ],
      // date-repeat — 반복 규칙 (추가 모드 + 날짜 지정 시에만).
      // 편집 모드에서 규칙 수정은 별도 동작이라 노출하지 않는다 (PRD FR-6).
      if (isTask && !_isEditMode && _dueAt != null) ...[
        const SizedBox(height: AppTokens.space16),
        _SectionLabel(text: '반복'),
        const SizedBox(height: AppTokens.space8),
        _RecurrenceSection(
          freq: _recurrenceFreq,
          interval: _recurrenceInterval,
          weekdays: _recurrenceWeekdays,
          endAt: _recurrenceEndAt,
          onSelectFreq: _setRecurrenceFreq,
          onChangeInterval: _setRecurrenceInterval,
          onToggleWeekday: _toggleRecurrenceWeekday,
          onPickEnd: _pickRecurrenceEnd,
          onClearEnd: () => setState(() => _recurrenceEndAt = null),
        ),
      ],
      // 편집 모드 + 반복 시리즈 항목 → 규칙 요약 + "반복 중지" (FR-6).
      if (isTask && _isEditMode && (initial?.isInRecurringSeries ?? false)) ...[
        const SizedBox(height: AppTokens.space16),
        _SectionLabel(text: '반복'),
        const SizedBox(height: AppTokens.space8),
        _RecurrenceEditInfo(item: initial!),
      ],
      // 3-상태(□ 미완료 / △ 진행중 / ◯ 완료). 편집 모드 전용 — 신규 추가는 아직
      // 저장 대상 Todo 가 없다. note 는 상태 개념이 없다.
      if (_isEditMode && isTask) ...[
        const SizedBox(height: AppTokens.space16),
        _SectionLabel(text: '상태'),
        const SizedBox(height: AppTokens.space8),
        _StatusSelector(
          selected: _status,
          color: _category.color,
          onSelect: _setStatus,
        ),
      ],
      // 편집 모드 — 지금 이 항목이 트리 어디에 있는지 + 다른 곳으로 이동.
      if (_isEditMode && widget.onRequestMove != null) ...[
        const SizedBox(height: AppTokens.space16),
        _SectionLabel(text: '위치'),
        const SizedBox(height: AppTokens.space8),
        _LocationRow(item: initial!, onMove: _requestMove),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // v1.2 — 동적 카테고리 (보관 제외). activeCategoriesProvider 로 sidebar 와 동일 출처.
    // loading / error 시 builtin 5종 fallback.
    final categoriesAsync = ref.watch(activeCategoriesProvider);
    final categories = categoriesAsync.asData?.value ?? Category.builtinSeeds;
    // J — 카테고리 칩을 소속 그룹별로 묶어 보여 주기 위해 그룹 목록도 watch (보관 제외).
    final groups =
        ref.watch(activeGroupsProvider).asData?.value ?? const <Group>[];
    // 선택된 카테고리가 목록에 없으면 (삭제됨 / 초기값 불일치) 첫 항목으로 자동 보정.
    // build 중 setState 금지 → post-frame 으로 안전하게 갱신.
    //
    // 작업 1 가드 — 두 조건이 모두 맞을 때만 보정한다:
    //  (1) provider 가 data 로 확정(hasValue) — loading/error 의 builtinSeeds
    //      fallback 상태에서는 목록을 신뢰하지 않는다.
    //  (2) 현재 선택이 "미신뢰"(_categoryTrusted == false) — edit 모드 initialTodo
    //      나 사용자가 칩으로 명시 선택한 값은 동기화 race 로 목록에 아직 없더라도
    //      덮어쓰지 않는다. 안 그러면 사용자가 고른 카테고리(예: 코기토)가 저장 후
    //      categories.first(예: 일상)로 되돌아가는 증상이 된다.
    if (categoriesAsync.hasValue &&
        !_categoryTrusted &&
        categories.isNotEmpty &&
        !categories.any((c) => c.id == _category.id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final list = ref.read(activeCategoriesProvider).asData?.value;
        if (list == null || list.isEmpty) return;
        if (list.any((c) => c.id == _category.id)) return;
        setState(() => _category = list.first);
      });
    }

    final moreChildren = _moreChildren();

    return PopScope(
      // 카테고리 메뉴가 열려 있으면 뒤로가기는 메뉴만 닫는다.
      canPop: !_categoryMenuOpen,
      // edit 모드 자동 저장 — 배경 탭 / 아래로 드래그 / Esc / 뒤로가기 등 어떤 경로로
      // 닫혀도 입력값을 저장한다 (저장 버튼은 확인용일 뿐). 신규 추가 모드는 기존대로
      // 닫힘 = 취소. 빈 제목·잘못된 기간이면 저장할 수 없으므로 취소로 처리한다.
      // 무변경 닫힘은 TodoActionsController.update 의 _isUnchanged 가 no-op 으로
      // 걸러주므로 순서 bump / updatedAt 갱신이 일어나지 않는다.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (_categoryMenu.isOpen) _categoryMenu.close();
          return;
        }
        if (!_isEditMode || _submitted) return;
        if (_titleCtrl.text.trim().isEmpty || _rangeInvalid) return;
        _submitted = true;
        _applyEdit();
      },
      child: Material(
        color: scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppTokens.radiusL),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Shortcuts(
            shortcuts: <ShortcutActivator, Intent>{
              const SingleActivator(LogicalKeyboardKey.escape):
                  const _DismissIntent(),
              // ⌘Enter / Ctrl+Enter = 저장 — 설명처럼 여러 줄 칸에 있어도 바로 저장.
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  const _SubmitIntent(),
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  const _SubmitIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                _DismissIntent: CallbackAction<_DismissIntent>(
                  onInvoke: (_) {
                    // 카테고리 메뉴가 열려 있으면 Esc 는 메뉴만 닫는다 — 포커스가 제목
                    // 칸에 남아 있어 메뉴의 Esc 보다 시트의 Esc 가 먼저 받는다.
                    if (_categoryMenu.isOpen) {
                      _categoryMenu.close();
                    } else {
                      Navigator.of(context).maybePop();
                    }
                    return null;
                  },
                ),
                _SubmitIntent: CallbackAction<_SubmitIntent>(
                  onInvoke: (_) {
                    _submit();
                    return null;
                  },
                ),
              },
              // 상세 메모를 펼치면 내용이 길어져 화면을 넘어설 수 있다. SingleChildScrollView
              // 로 감싸 bottom overflow 방지 — 모달 바텀시트는 이미 화면 높이로 max 가
              // 제한되므로 내부 스크롤로 안전. (unbounded 환경에선 content 로 shrink-wrap.)
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.space24,
                  AppTokens.space16,
                  AppTokens.space24,
                  AppTokens.space24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Grabber(color: scheme.outline),
                    const SizedBox(height: AppTokens.space16),
                    // ── 1단: 빠른 입력 ─────────────────────────────────────
                    // 제목 줄 오른쪽에 카테고리 — 가장 자주 바꾸는 값이라 한 번에 닿게.
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _isEditMode
                                ? '할 일 편집'
                                : (_isChildMode ? '하위 항목 추가' : '새 할 일'),
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppTokens.space8),
                        // "하위 추가" 는 부모 카테고리로 고정 — 보여 주기만 한다.
                        _CategoryPicker(
                          controller: _categoryMenu,
                          onOpenChanged: (open) {
                            if (!mounted) return;
                            setState(() => _categoryMenuOpen = open);
                          },
                          categories: categories,
                          groups: groups,
                          selected: _category,
                          enabled: !_isChildMode,
                          // 사용자가 명시 선택 → 신뢰 표시 (자동 보정 대상에서 제외).
                          onSelect: (c) => setState(() {
                            _category = c;
                            _categoryTrusted = true;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppTokens.space12),
                    TextField(
                      key: const ValueKey('add-todo-title'),
                      controller: _titleCtrl,
                      autofocus: true,
                      textInputAction: TextInputAction.done,
                      // multi-line 허용 — 메모장 → 앱 멀티라인 paste 가 \n 그대로 들어와
                      // [_onTitleChanged] 가 bulk paste 로 감지. 평소 1줄 입력 시각은 minLines.
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 1000,
                      keyboardType: TextInputType.multiline,
                      // edit 모드에서는 bulk paste 가 의미 없으므로 단순 setState 만.
                      onChanged: _isEditMode
                          ? (_) => setState(() {})
                          : _onTitleChanged,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        hintText: _isEditMode
                            ? '제목을 입력하세요'
                            : '무엇을 할까요?  (여러 줄 paste = 일괄 추가)',
                        counterText: '',
                      ),
                    ),
                    // 메모는 본문이 곧 내용이라 1단에 바로 둔다.
                    if (_type == TodoType.note) ...[
                      const SizedBox(height: AppTokens.space12),
                      _descriptionField(hint: '메모 내용 (선택)'),
                    ],
                    if (_type == TodoType.task) ...[
                      const SizedBox(height: AppTokens.space12),
                      // 날짜 → 시간 → (선택) 종료. 모드를 먼저 고르던 칩 줄은 없앴다.
                      _QuickDueChips(
                        today: _today(),
                        dueAt: _dueAt,
                        allDay: _dateMode == _DateInputMode.range
                            ? _rangeAllDay
                            : _allDay,
                        onSelectDate: _setQuickDate,
                        onPickDate: _dateMode == _DateInputMode.range
                            ? _pickRangeShift
                            : _pickDueDate,
                        onPickTime: _dateMode == _DateInputMode.range
                            ? _pickRangeStartTime
                            : _pickTime,
                      ),
                      if (_dateMode == _DateInputMode.range) ...[
                        const SizedBox(height: AppTokens.space8),
                        _RangeSection(
                          startAt: _dueAt,
                          endAt: _endAt,
                          allDay: _rangeAllDay,
                          invalid: _rangeInvalid,
                          onPickStartDate: _pickRangeStartDate,
                          onPickStartTime: _pickRangeStartTime,
                          onPickEndDate: _pickRangeEndDate,
                          onPickEndTime: _pickRangeEndTime,
                          onToggleAllDay: _toggleRangeAllDay,
                          onClearRange: _clearRange,
                        ),
                      ] else if (_dueAt != null) ...[
                        const SizedBox(height: AppTokens.space8),
                        _DueRow(
                          dueAt: _dueAt!,
                          allDay: _allDay,
                          anchorEnd: _dateMode == _DateInputMode.endTime,
                          onPickDate: _pickDueDate,
                          onMakeAllDay: _makeAllDay,
                          onSetAnchor: (end) => _setTimeAnchor(end: end),
                          onClear: _clearDueAt,
                        ),
                      ],
                    ],
                    const SizedBox(height: AppTokens.space8),
                    Row(
                      children: [
                        _TypeToggle(selected: _type, onSelect: _setType),
                        const Spacer(),
                        // 더보기에 담을 게 없으면(메모 추가) 토글도 없다.
                        if (moreChildren.isNotEmpty)
                          _MoreToggle(
                            expanded: _showMore,
                            summary: _moreSummary(),
                            onToggle: () =>
                                setState(() => _showMore = !_showMore),
                          ),
                      ],
                    ),
                    // ── 2단: 더보기 ────────────────────────────────────────
                    AnimatedSize(
                      duration: AppTokens.motionFast,
                      alignment: Alignment.topCenter,
                      child: !_showMore || moreChildren.isEmpty
                          ? const SizedBox(width: double.infinity)
                          : Column(
                              key: const ValueKey('add-todo-more-section'),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: moreChildren,
                            ),
                    ),
                    const SizedBox(height: AppTokens.space20),
                    _Actions(
                      canSubmit: _canSubmit,
                      onSubmit: _submit,
                      submitLabel: _isEditMode ? '저장' : '추가',
                      // 편집은 "닫힘 = 저장" 모델이라 이 버튼도 저장 후 닫는다. 라벨이
                      // "취소" 면 정반대로 읽혀서 "닫기" 로 둔다 (UX 감사 B2).
                      dismissLabel: _isEditMode ? '닫기' : '취소',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DismissIntent extends Intent {
  const _DismissIntent();
}

class _SubmitIntent extends Intent {
  const _SubmitIntent();
}

/// fast-tasks — AddTodoSheet 의 날짜 입력 모드. 단일 3 + 기간.
enum _DateInputMode { allDay, startTime, endTime, range }

/// 현재 모드/state 로부터 도출한 직렬화 4-tuple. Todo 직렬화 규칙의 단일 출처.
class _DateSerialized {
  const _DateSerialized({
    required this.dueAt,
    this.endAt,
    this.isAllDay = false,
    this.timeAnchor = 'start',
    this.invalid = false,
  });

  final DateTime? dueAt;
  final DateTime? endAt;
  final bool isAllDay;
  final String timeAnchor;

  /// 기간 모드에서 종료 < 시작 이면 true → 저장 차단.
  final bool invalid;
}

class _Grabber extends StatelessWidget {
  const _Grabber({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}

/// 편집 모드의 "위치" 행 — `카테고리 › 부모 › 부모` 경로 + 이동 버튼.
///
/// 카테고리 칩만으로는 계층(하위 ↔ 상위)을 옮길 수 없어, 이동은 전용 시트로 넘긴다.
class _LocationRow extends ConsumerWidget {
  const _LocationRow({required this.item, required this.onMove});

  final Todo item;
  final VoidCallback onMove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final all = ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
    final path = computeTodoPath(item, all).map((p) => p.title);
    final label = [item.category.label, ...path].join(' › ');

    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppTokens.radiusM),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space16,
          AppTokens.space8,
          AppTokens.space8,
          AppTokens.space8,
        ),
        child: Row(
          children: [
            Icon(
              item.parentId == null
                  ? Icons.folder_outlined
                  : Icons.subdirectory_arrow_right_rounded,
              size: 18,
              color: item.category.color,
            ),
            const SizedBox(width: AppTokens.space12),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            TextButton.icon(
              key: const ValueKey('edit-move'),
              onPressed: onMove,
              icon: const Icon(Icons.drive_file_move_outline, size: 16),
              label: const Text('이동'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 그룹 아코디언형 카테고리 선택 — 그룹 헤더('미분류' 포함)는 항상 전부 보이고,
/// 카테고리 칩은 펼쳐진 한 그룹의 것만 노출한다. 항상 정확히 한 그룹만 펼침
/// (디폴트 = 선택된 카테고리가 속한 그룹). 그룹이 없으면 평면 나열 유지.
class _CategoryChips extends StatefulWidget {
  const _CategoryChips({
    required this.categories,
    required this.groups,
    required this.selected,
    required this.onSelect,
  });

  /// v1.2 — 동적 카테고리 목록 (categoriesProvider). builtin + 사용자 추가 모두 포함.
  final List<Category> categories;

  /// J — 카테고리를 소속 그룹별로 묶기 위한 그룹 목록. 비면 평면 나열.
  final List<Group> groups;
  final Category selected;
  final ValueChanged<Category> onSelect;

  @override
  State<_CategoryChips> createState() => _CategoryChipsState();
}

/// '미분류' 섹션의 아코디언 key — 실제 그룹 id 와 충돌하지 않는 sentinel.
const String _kUngroupedSectionKey = 'ungrouped';

class _CategoryChipsState extends State<_CategoryChips> {
  /// 사용자가 마지막으로 펼친 섹션 key (그룹 id 또는 [_kUngroupedSectionKey]).
  /// null 이거나 현재 섹션 목록에 없으면 build 에서 선택 카테고리 기준으로 보정.
  String? _expandedKey;

  Widget _wrap(List<Category> items) {
    return Wrap(
      spacing: AppTokens.space8,
      runSpacing: AppTokens.space8,
      children: [
        for (final c in items)
          _CategoryChip(
            key: ValueKey('category-chip-${c.id}'),
            category: c,
            // 전체 동등 비교는 DB 인스턴스 ↔ const 차이로 어긋날 수 있어 id 로 비교.
            selected: c.id == widget.selected.id,
            onTap: () => widget.onSelect(c),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 그룹이 하나도 없으면 기존처럼 평면 한 줄 Wrap (불필요한 헤더 미노출).
    if (widget.groups.isEmpty) return _wrap(widget.categories);

    final ungrouped = <Category>[];
    final byGroup = <String, List<Category>>{};
    for (final c in widget.categories) {
      final gid = c.groupId;
      if (gid == null) {
        ungrouped.add(c);
      } else {
        byGroup.putIfAbsent(gid, () => <Category>[]).add(c);
      }
    }
    // 존재하지 않는 그룹에 매인 카테고리는 미분류로 흡수.
    final groupIds = widget.groups.map((g) => g.id).toSet();
    for (final entry in byGroup.entries.toList()) {
      if (!groupIds.contains(entry.key)) {
        ungrouped.addAll(entry.value);
        byGroup.remove(entry.key);
      }
    }

    // 노출할 섹션 (빈 그룹 제외).
    final sections =
        <({String key, String label, Color? color, List<Category> items})>[
          if (ungrouped.isNotEmpty)
            (
              key: _kUngroupedSectionKey,
              label: '미분류',
              color: null,
              items: ungrouped,
            ),
          for (final g in widget.groups)
            if ((byGroup[g.id] ?? const <Category>[]).isNotEmpty)
              (
                key: g.id,
                label: g.label,
                color: g.color,
                items: byGroup[g.id]!,
              ),
        ];
    if (sections.isEmpty) return const SizedBox.shrink();

    // 펼칠 섹션 보정 — 반드시 하나는 펼침. 디폴트는 선택 카테고리가 속한 섹션.
    var expanded = _expandedKey;
    if (expanded == null || !sections.any((s) => s.key == expanded)) {
      expanded = sections
          .firstWhere(
            (s) => s.items.any((c) => c.id == widget.selected.id),
            orElse: () => sections.first,
          )
          .key;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, s) in sections.indexed) ...[
          if (i > 0) const SizedBox(height: AppTokens.space4),
          _GroupAccordionHeader(
            key: ValueKey('category-group-header-${s.key}'),
            label: s.label,
            color: s.color,
            expanded: s.key == expanded,
            // 접힌 섹션에 선택 칩이 숨어 있으면 헤더에 이름을 흘려 표시 (가시성).
            selectedHint:
                s.key != expanded &&
                    s.items.any((c) => c.id == widget.selected.id)
                ? widget.selected.label
                : null,
            onTap: () => setState(() => _expandedKey = s.key),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: s.key == expanded
                ? Padding(
                    padding: const EdgeInsets.only(
                      top: AppTokens.space4,
                      bottom: AppTokens.space4,
                    ),
                    child: _wrap(s.items),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ],
    );
  }
}

/// J — 아코디언 그룹 헤더 (그룹명/'미분류' + 색 dot + 펼침 화살표).
class _GroupAccordionHeader extends StatelessWidget {
  const _GroupAccordionHeader({
    super.key,
    required this.label,
    required this.color,
    required this.expanded,
    required this.onTap,
    this.selectedHint,
  });

  final String label;
  final Color? color;
  final bool expanded;
  final VoidCallback onTap;

  /// 접힘 상태에서 이 그룹 안에 숨어 있는 "선택된 카테고리" 이름 (없으면 null).
  final String? selectedHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dot = color ?? scheme.onSurface.withValues(alpha: 0.4);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.radiusS),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTokens.space8),
        child: Row(
          children: [
            Icon(Icons.circle, size: 9, color: dot),
            const SizedBox(width: AppTokens.space8),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurface.withValues(
                    alpha: expanded ? 0.85 : 0.6,
                  ),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            // 화살표는 그룹명 바로 옆 — 오른쪽 끝으로 밀면 넓은 시트에서 어색.
            const SizedBox(width: AppTokens.space2),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: scheme.onSurface.withValues(alpha: 0.55),
            ),
            if (selectedHint != null) ...[
              const SizedBox(width: AppTokens.space8),
              Flexible(
                child: Text(
                  '· $selectedHint',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    super.key,
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final Category category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = selected
        ? category.color.withValues(alpha: 0.22)
        : theme.colorScheme.surfaceContainerHighest;
    final fg = selected
        ? category.color
        : theme.colorScheme.onSurface.withValues(alpha: 0.78);

    // 선택 시 outline 도 함께 적용 — alpha 변화만으로는 시각 대비가 약했다.
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      side: selected
          ? BorderSide(color: category.color, width: 1.6)
          : BorderSide.none,
    );

    return Material(
      color: bg,
      shape: shape,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space12,
            vertical: AppTokens.space8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(category.icon, size: 16, color: fg),
              const SizedBox(width: AppTokens.space8),
              Text(
                category.label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 정해진 일정 한 줄 요약 — "9월 25일 (목) · 하루 종일" / "… · 14:30 시작".
///
/// 탭 = 날짜 다시 고르기. 시간이 있으면 시작/마감 기준 전환과 "하루 종일로" 를 둔다.
/// ✕ = 일정 비우기.
class _DueRow extends StatelessWidget {
  const _DueRow({
    required this.dueAt,
    required this.allDay,
    required this.anchorEnd,
    required this.onPickDate,
    required this.onMakeAllDay,
    required this.onSetAnchor,
    required this.onClear,
  });

  final DateTime dueAt;
  final bool allDay;

  /// 시간 기준이 "마감(그 시각까지)" 인지. false = 시작.
  final bool anchorEnd;
  final VoidCallback onPickDate;
  final VoidCallback onMakeAllDay;
  final ValueChanged<bool> onSetAnchor;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const wd = ['월', '화', '수', '목', '금', '토', '일'];
    // "9월 24일 (목)" — 요일까지 쓰면 폰 폭에서 시작/마감 칩과 부딪혀 잘렸다.
    final day = '${dueAt.month}월 ${dueAt.day}일 (${wd[dueAt.weekday - 1]})';
    // 시각은 바로 위 ⏰ 칩에 보이니 여기선 날짜와 기준(시작/마감)만.
    final label = allDay ? '$day · 하루 종일' : day;

    return Material(
      key: const ValueKey('add-todo-due-row'),
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppTokens.radiusM),
      child: InkWell(
        onTap: onPickDate,
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space12,
            AppTokens.space4,
            AppTokens.space4,
            AppTokens.space4,
          ),
          child: Row(
            children: [
              Icon(Icons.event_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: AppTokens.space8),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!allDay) ...[
                // 그 시각에 "시작" / 그 시각 "까지" — 캘린더 등록 모양이 달라진다.
                _AnchorChip(
                  key: const ValueKey('due-anchor-start'),
                  label: '시작',
                  selected: !anchorEnd,
                  onTap: () => onSetAnchor(false),
                ),
                const SizedBox(width: AppTokens.space4),
                _AnchorChip(
                  key: const ValueKey('due-anchor-end'),
                  label: '마감',
                  selected: anchorEnd,
                  onTap: () => onSetAnchor(true),
                ),
                IconButton(
                  key: const ValueKey('due-make-all-day'),
                  onPressed: onMakeAllDay,
                  icon: const Icon(Icons.wb_sunny_outlined, size: 18),
                  tooltip: '하루 종일로',
                  visualDensity: VisualDensity.compact,
                ),
              ],
              IconButton(
                key: const ValueKey('due-clear'),
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: '일정 비우기',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AnchorChip extends StatelessWidget {
  const _AnchorChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space8,
            vertical: AppTokens.space4,
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: selected
                  ? scheme.onPrimaryContainer
                  : scheme.onSurface.withValues(alpha: 0.6),
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// 2단 시트의 "더보기" 토글. 접혀 있어도 켜 둔 설정([summary])을 옆에 보인다.
class _MoreToggle extends StatelessWidget {
  const _MoreToggle({
    required this.expanded,
    required this.summary,
    required this.onToggle,
  });

  final bool expanded;
  final String? summary;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface.withValues(alpha: 0.78);
    return TextButton(
      key: const ValueKey('add-todo-more'),
      onPressed: onToggle,
      style: TextButton.styleFrom(
        foregroundColor: fg,
        visualDensity: VisualDensity.compact,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!expanded && summary != null) ...[
            Text(
              summary!,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: AppTokens.space8),
          ],
          Text(expanded ? '접기' : '더보기'),
          Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18),
        ],
      ),
    );
  }
}

/// 헤더 오른쪽 카테고리 드롭다운. 누르면 그룹별 칩 목록([_CategoryChips])이 뜬다.
class _CategoryPicker extends StatefulWidget {
  const _CategoryPicker({
    required this.controller,
    required this.onOpenChanged,
    required this.categories,
    required this.groups,
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });

  /// 시트가 들고 있는 메뉴 컨트롤러 — 시트의 Esc·뒤로가기가 메뉴부터 닫게.
  final MenuController controller;
  final ValueChanged<bool> onOpenChanged;
  final List<Category> categories;
  final List<Group> groups;
  final Category selected;

  /// false 면 보여 주기만 (하위 추가 = 부모 카테고리 고정).
  final bool enabled;
  final ValueChanged<Category> onSelect;

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  MenuController get _menu => widget.controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.selected;
    final button = Material(
      color: c.color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      child: InkWell(
        key: const ValueKey('add-todo-category'),
        onTap: widget.enabled
            ? () => _menu.isOpen ? _menu.close() : _menu.open()
            : null,
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space12,
            vertical: AppTokens.space8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(c.icon, size: 16, color: c.color),
              const SizedBox(width: AppTokens.space8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  c.label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: c.color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (widget.enabled)
                Icon(Icons.expand_more_rounded, size: 18, color: c.color),
            ],
          ),
        ),
      ),
    );
    if (!widget.enabled) return button;
    return MenuAnchor(
      controller: _menu,
      onOpen: () => widget.onOpenChanged(true),
      onClose: () => widget.onOpenChanged(false),
      alignmentOffset: const Offset(0, AppTokens.space4),
      menuChildren: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360, maxHeight: 420),
          child: SingleChildScrollView(
            // 메뉴 자체 스크롤과 PrimaryScrollController 를 나눠 쓰지 않게.
            primary: false,
            padding: const EdgeInsets.all(AppTokens.space12),
            child: _CategoryChips(
              categories: widget.categories,
              groups: widget.groups,
              selected: widget.selected,
              onSelect: (picked) {
                widget.onSelect(picked);
                _menu.close();
              },
            ),
          ),
        ),
      ],
      child: button,
    );
  }
}

class _CalendarToggle extends StatelessWidget {
  const _CalendarToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Icon(
          Icons.calendar_month_outlined,
          size: 18,
          color: scheme.onSurface.withValues(alpha: 0.78),
        ),
        const SizedBox(width: AppTokens.space12),
        Expanded(
          child: Text(
            'Google Calendar 에 등록',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// date-repeat — 편집 모드의 반복 시리즈 항목 정보 + "반복 중지" 버튼.
///
/// 규칙 자체 수정은 미지원이라 입력 칩 대신 마스터의 규칙을 한 줄 요약으로 보여 주고,
/// "반복 중지"(마스터 삭제, 비파괴적) 만 제공한다. 마스터를 [allTodosProvider] 에서
/// [RecurrenceMaterializer.findMaster] 로 역추적해 규칙을 읽는다.
class _RecurrenceEditInfo extends ConsumerWidget {
  const _RecurrenceEditInfo({required this.item});

  final Todo item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final all = ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
    final master = RecurrenceMaterializer.findMaster(all, item);
    final rule = master?.recurrence;
    final summary = rule == null
        ? '반복 항목'
        : rule.describe(until: master!.recurrenceEndAt);

    return Container(
      key: const ValueKey('edit-recurrence-info'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space12,
        vertical: AppTokens.space8,
      ),
      decoration: BoxDecoration(
        color: item.category.color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
      ),
      child: Row(
        children: [
          Icon(Icons.repeat_rounded, size: 18, color: item.category.color),
          const SizedBox(width: AppTokens.space8),
          Expanded(
            child: Text(
              summary,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('edit-recurrence-stop'),
            onPressed: () async {
              final ok = await confirmStopRecurrence(context, ref, item);
              if (ok && context.mounted) Navigator.of(context).maybePop();
            },
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('반복 중지'),
          ),
        ],
      ),
    );
  }
}

/// date-repeat — 반복 규칙 입력. 주기 칩(안 함/매일/매주/매월/매년) + N간격 스텝퍼
/// + (매주) 요일 칩 + 종료일(선택). 컴팩트하게 한 섹션에 묶는다.
class _RecurrenceSection extends StatelessWidget {
  const _RecurrenceSection({
    required this.freq,
    required this.interval,
    required this.weekdays,
    required this.endAt,
    required this.onSelectFreq,
    required this.onChangeInterval,
    required this.onToggleWeekday,
    required this.onPickEnd,
    required this.onClearEnd,
  });

  final RecurrenceFreq? freq;
  final int interval;
  final Set<int> weekdays;
  final DateTime? endAt;
  final ValueChanged<RecurrenceFreq?> onSelectFreq;
  final ValueChanged<int> onChangeInterval;
  final ValueChanged<int> onToggleWeekday;
  final VoidCallback onPickEnd;
  final VoidCallback onClearEnd;

  static const _freqLabels = {
    RecurrenceFreq.daily: '매일',
    RecurrenceFreq.weekly: '매주',
    RecurrenceFreq.monthly: '매월',
    RecurrenceFreq.yearly: '매년',
  };

  static const _unit = {
    RecurrenceFreq.daily: '일',
    RecurrenceFreq.weekly: '주',
    RecurrenceFreq.monthly: '개월',
    RecurrenceFreq.yearly: '년',
  };

  static const _weekdayLabels = ['월', '화', '수', '목', '금', '토', '일'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 주기 선택 칩.
        Wrap(
          spacing: AppTokens.space8,
          runSpacing: AppTokens.space8,
          children: [
            _RecurChip(
              key: const ValueKey('recur-freq-none'),
              label: '안 함',
              selected: freq == null,
              onTap: () => onSelectFreq(null),
            ),
            for (final f in RecurrenceFreq.values)
              _RecurChip(
                key: ValueKey('recur-freq-${f.name}'),
                label: _freqLabels[f]!,
                selected: freq == f,
                onTap: () => onSelectFreq(f),
              ),
          ],
        ),
        if (freq != null) ...[
          const SizedBox(height: AppTokens.space12),
          // N간격 스텝퍼 — "N(일/주/개월/년)마다".
          Row(
            children: [
              Text('간격', style: theme.textTheme.bodyMedium),
              const SizedBox(width: AppTokens.space12),
              _StepperButton(
                key: const ValueKey('recur-interval-minus'),
                icon: Icons.remove_rounded,
                onTap: interval > 1
                    ? () => onChangeInterval(interval - 1)
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.space12,
                ),
                child: Text(
                  '$interval${_unit[freq]!}마다',
                  key: const ValueKey('recur-interval-label'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _StepperButton(
                key: const ValueKey('recur-interval-plus'),
                icon: Icons.add_rounded,
                onTap: () => onChangeInterval(interval + 1),
              ),
            ],
          ),
          // 매주 — 요일 선택 칩.
          if (freq == RecurrenceFreq.weekly) ...[
            const SizedBox(height: AppTokens.space12),
            Wrap(
              spacing: AppTokens.space8,
              runSpacing: AppTokens.space8,
              children: [
                for (var wd = 1; wd <= 7; wd++)
                  _RecurChip(
                    key: ValueKey('recur-weekday-$wd'),
                    label: _weekdayLabels[wd - 1],
                    selected: weekdays.contains(wd),
                    onTap: () => onToggleWeekday(wd),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppTokens.space12),
          // 종료일(선택).
          Row(
            children: [
              Icon(
                Icons.event_busy_outlined,
                size: 18,
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
              const SizedBox(width: AppTokens.space8),
              Expanded(
                child: TextButton(
                  key: const ValueKey('recur-end-pick'),
                  onPressed: onPickEnd,
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(
                      vertical: AppTokens.space8,
                    ),
                  ),
                  child: Text(
                    endAt == null
                        ? '종료일 없음 (계속 반복)'
                        : '${KoDate.shortDate(endAt!)} 까지',
                  ),
                ),
              ),
              if (endAt != null)
                IconButton(
                  key: const ValueKey('recur-end-clear'),
                  onPressed: onClearEnd,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: '종료일 지우기',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 반복 섹션 전용 선택 칩 (주기·요일 공용).
class _RecurChip extends StatelessWidget {
  const _RecurChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected ? scheme.primary : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space16,
            vertical: AppTokens.space8,
          ),
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: selected ? scheme.onPrimary : scheme.onSurface,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// N간격 +/- 스텝퍼 버튼. [onTap] null 이면 비활성.
class _StepperButton extends StatelessWidget {
  const _StepperButton({super.key, required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Material(
      color: scheme.surfaceContainerHighest,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.space8),
          child: Icon(
            icon,
            size: 18,
            color: scheme.onSurface.withValues(alpha: enabled ? 0.9 : 0.3),
          ),
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.canSubmit,
    required this.onSubmit,
    this.submitLabel = '추가',
    this.dismissLabel = '취소',
  });

  final bool canSubmit;
  final VoidCallback onSubmit;
  final String submitLabel;

  /// 왼쪽 버튼 라벨 — 추가 모드 "취소"(닫힘 = 폐기), 편집 모드 "닫기"(닫힘 = 저장).
  final String dismissLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => Navigator.of(context).maybePop(),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: AppTokens.space12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTokens.radiusM),
              ),
            ),
            child: Text(dismissLabel),
          ),
        ),
        const SizedBox(width: AppTokens.space12),
        Expanded(
          child: FilledButton(
            onPressed: canSubmit ? onSubmit : null,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: AppTokens.space12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTokens.radiusM),
              ),
            ),
            child: Text(submitLabel),
          ),
        ),
      ],
    );
  }
}

/// 편집 시트의 "상태" 섹션 — □ 미완료 / △ 진행중 / ◯ 완료 세 칸.
///
/// 목록 타일의 세모·체크 원과 같은 시각 언어를 그대로 쓴다 — 현재 상태만 카테고리색으로
/// **채우고**, 나머지는 같은 색 옅은(0.55) **외곽선**. 기호만으로는 뜻이 안 읽히므로
/// 짧은 한국어 라벨을 붙였다.
class _StatusSelector extends StatelessWidget {
  const _StatusSelector({
    required this.selected,
    required this.color,
    required this.onSelect,
  });

  final TodoStatus selected;

  /// 카테고리색 — 시트에서 카테고리를 바꾸면 기호 색도 따라간다.
  final Color color;

  final ValueChanged<TodoStatus> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppTokens.space8,
      runSpacing: AppTokens.space8,
      children: [
        for (final status in TodoStatus.values)
          _StatusChip(
            key: ValueKey('status-${status.name}'),
            status: status,
            color: color,
            selected: selected == status,
            onTap: () => onSelect(status),
          ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    super.key,
    required this.status,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final TodoStatus status;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  /// 상태별 한국어 라벨 — 상태별 보기 칩(`TodoStatusFilter`)과 같은 말을 쓴다.
  String get _label => switch (status) {
    TodoStatus.undone => '미완료',
    TodoStatus.inProgress => '진행중',
    TodoStatus.done => '완료',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 선택된 칸만 카테고리색 테두리 + 옅은 바탕으로 띄운다 (기호의 채움과 이중 신호).
    final bg = selected
        ? color.withValues(alpha: 0.14)
        : scheme.surfaceContainerHighest;
    final fg = selected
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.78);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      side: selected ? BorderSide(color: color, width: 1.4) : BorderSide.none,
    );

    return Material(
      color: bg,
      shape: shape,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space12,
            vertical: AppTokens.space8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StatusGlyph(status: status, active: selected, color: color),
              const SizedBox(width: AppTokens.space8),
              Text(
                _label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 상태 기호 하나 — 네모 / 세모 / 원. 세모와 원은 목록 타일이 쓰는 것과 같은 위젯·아이콘.
class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({
    required this.status,
    required this.active,
    required this.color,
  });

  final TodoStatus status;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case TodoStatus.undone:
        return UndoneSquare(active: active, color: color);
      case TodoStatus.inProgress:
        return InProgressTriangle(active: active, color: color);
      case TodoStatus.done:
        // 타일의 완료 체크와 동일한 아이콘 쌍 — 채움(체크 원) / 옅은 링.
        return Icon(
          active ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
          size: 18,
          color: active ? color : color.withValues(alpha: 0.55),
        );
    }
  }
}

/// v1.1 — task / note segmented 토글. note 면 일정 영역이 사라지고 단순 메모로 저장된다.
class _TypeToggle extends StatelessWidget {
  const _TypeToggle({required this.selected, required this.onSelect});

  final TodoType selected;
  final ValueChanged<TodoType> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppTokens.space8,
      runSpacing: AppTokens.space8,
      children: [
        _TypeChip(
          key: const ValueKey('type-task'),
          label: '할 일',
          icon: Icons.check_box_outline_blank_rounded,
          selected: selected == TodoType.task,
          onTap: () => onSelect(TodoType.task),
        ),
        _TypeChip(
          key: const ValueKey('type-note'),
          label: '메모',
          icon: Icons.sticky_note_2_outlined,
          selected: selected == TodoType.note,
          onTap: () => onSelect(TodoType.note),
        ),
      ],
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = selected
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final fg = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurface.withValues(alpha: 0.78);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      side: selected
          ? BorderSide(color: scheme.primary, width: 1.4)
          : BorderSide.none,
    );

    return Material(
      color: bg,
      shape: shape,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space12,
            vertical: AppTokens.space8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: AppTokens.space8),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 빠른 날짜 칩 — "오늘 / 내일(요일) / 다음주 월 / 📅 / ⏰".
///
/// 날짜 칩은 **날짜만** 바꾼다(시간은 유지). 같은 날짜 칩을 다시 누르면 일정 비우기.
/// 📅 는 달력에서 고르기, ⏰ 는 시간 입력(날짜가 없으면 오늘 기준).
class _QuickDueChips extends StatelessWidget {
  const _QuickDueChips({
    required this.today,
    required this.dueAt,
    required this.allDay,
    required this.onSelectDate,
    required this.onPickDate,
    required this.onPickTime,
  });

  final DateTime today;
  final DateTime? dueAt;
  final bool allDay;
  final void Function(DateTime date) onSelectDate;
  final VoidCallback onPickDate;
  final VoidCallback onPickTime;

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  bool _isDate(DateTime target) {
    final d = dueAt;
    return d != null &&
        d.year == target.year &&
        d.month == target.month &&
        d.day == target.day;
  }

  @override
  Widget build(BuildContext context) {
    final tomorrow = today.add(const Duration(days: 1));
    // 다음주 월요일 — 오늘이 월요일이어도 "다음주" 월요일(7일 뒤).
    final nextMonday = today.add(Duration(days: 8 - today.weekday));
    final d = dueAt;
    final quick = _isDate(today) || _isDate(tomorrow) || _isDate(nextMonday);
    final hasTime = d != null && !allDay;
    // 폰 폭(≈390)에 다섯 칩을 한 줄로 — 아직 안 정한 📅/⏰ 는 아이콘만.
    final compact = AppPlatform.isMobile;

    return Wrap(
      spacing: compact ? AppTokens.space4 + 2 : AppTokens.space8,
      runSpacing: AppTokens.space8,
      children: [
        _QuickDueChip(
          key: const ValueKey('quick-due-today'),
          label: '오늘',
          selected: _isDate(today),
          onTap: () => onSelectDate(today),
        ),
        _QuickDueChip(
          key: const ValueKey('quick-due-tomorrow'),
          label: '내일 (${_weekdays[tomorrow.weekday - 1]})',
          selected: _isDate(tomorrow),
          onTap: () => onSelectDate(tomorrow),
        ),
        _QuickDueChip(
          key: const ValueKey('quick-due-next-week'),
          label: '다음주 월',
          selected: _isDate(nextMonday),
          onTap: () => onSelectDate(nextMonday),
        ),
        _QuickDueChip(
          key: const ValueKey('quick-due-pick'),
          icon: Icons.event_outlined,
          // 칩에 없는 날짜를 골랐으면 그 날짜를 칩에 보여 준다.
          label: (d != null && !quick)
              ? KoDate.shortDate(d)
              : (compact ? '' : '날짜'),
          tooltip: '날짜 고르기',
          selected: d != null && !quick,
          onTap: onPickDate,
        ),
        _QuickDueChip(
          key: const ValueKey('quick-due-time'),
          icon: Icons.schedule_outlined,
          label: hasTime ? KoDate.time(d) : (compact ? '' : '시간'),
          tooltip: '시간',
          selected: hasTime,
          onTap: onPickTime,
        ),
      ],
    );
  }
}

class _QuickDueChip extends StatelessWidget {
  const _QuickDueChip({
    super.key,
    required this.label,
    this.icon,
    this.tooltip,
    required this.selected,
    required this.onTap,
  });

  /// 비어 있으면 아이콘만 (폰의 안 정한 📅/⏰).
  final String label;
  final IconData? icon;
  final String? tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = selected
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final fg = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurface.withValues(alpha: 0.78);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      side: selected
          ? BorderSide(color: scheme.primary, width: 1.4)
          : BorderSide.none,
    );

    final chip = Material(
      color: bg,
      shape: shape,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: AppPlatform.isMobile
                ? AppTokens.space8 + 2
                : AppTokens.space12,
            vertical: AppTokens.space8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) Icon(icon, size: 16, color: fg),
              if (icon != null && label.isNotEmpty)
                const SizedBox(width: AppTokens.space4),
              if (label.isNotEmpty)
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: fg,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }
}

/// fast-tasks — 기간 모드의 시작/종료 날짜·시간 입력 + 하루종일 토글.
class _RangeSection extends StatelessWidget {
  const _RangeSection({
    required this.startAt,
    required this.endAt,
    required this.allDay,
    required this.invalid,
    required this.onPickStartDate,
    required this.onPickStartTime,
    required this.onPickEndDate,
    required this.onPickEndTime,
    required this.onToggleAllDay,
    required this.onClearRange,
  });

  final DateTime? startAt;
  final DateTime? endAt;
  final bool allDay;
  final bool invalid;
  final VoidCallback onPickStartDate;
  final VoidCallback onPickStartTime;
  final VoidCallback onPickEndDate;
  final VoidCallback onPickEndTime;
  final VoidCallback onToggleAllDay;

  /// 기간 끄기 — 시작 날짜만 남긴다.
  final VoidCallback onClearRange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RangeEndpointRow(
          key: const ValueKey('range-start-row'),
          icon: Icons.play_arrow_outlined,
          prefix: '시작',
          at: startAt,
          allDay: allDay,
          onPickDate: onPickStartDate,
          onPickTime: onPickStartTime,
        ),
        const SizedBox(height: AppTokens.space8),
        _RangeEndpointRow(
          key: const ValueKey('range-end-row'),
          icon: Icons.flag_outlined,
          prefix: '종료',
          at: endAt,
          allDay: allDay,
          onPickDate: onPickEndDate,
          onPickTime: onPickEndTime,
        ),
        const SizedBox(height: AppTokens.space8),
        Wrap(
          spacing: AppTokens.space8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('range-all-day-toggle'),
              onPressed: onToggleAllDay,
              icon: Icon(
                allDay ? Icons.schedule_outlined : Icons.wb_sunny_outlined,
                size: 16,
              ),
              label: Text(allDay ? '시간 추가' : '하루 종일로'),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTokens.radiusM),
                ),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('range-clear'),
              onPressed: onClearRange,
              icon: const Icon(Icons.close_rounded, size: 16),
              label: const Text('기간 없애기'),
            ),
          ],
        ),
        if (invalid)
          Padding(
            padding: const EdgeInsets.only(top: AppTokens.space8),
            child: Text(
              '종료가 시작보다 빠를 수 없어요.',
              key: const ValueKey('range-invalid-msg'),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
      ],
    );
  }
}

class _RangeEndpointRow extends StatelessWidget {
  const _RangeEndpointRow({
    super.key,
    required this.icon,
    required this.prefix,
    required this.at,
    required this.allDay,
    required this.onPickDate,
    required this.onPickTime,
  });

  final IconData icon;
  final String prefix;
  final DateTime? at;
  final bool allDay;
  final VoidCallback onPickDate;
  final VoidCallback onPickTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = at == null
        ? '$prefix 날짜 선택'
        : (allDay
              ? '$prefix · ${KoDate.pretty(at!)}'
              : '$prefix · ${KoDate.pretty(at!)} ${KoDate.time(at!)}');
    return Row(
      children: [
        Expanded(
          child: Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppTokens.radiusM),
            child: InkWell(
              onTap: onPickDate,
              borderRadius: BorderRadius.circular(AppTokens.radiusM),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.space16,
                  vertical: AppTokens.space12,
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: scheme.primary),
                    const SizedBox(width: AppTokens.space12),
                    Expanded(
                      child: Text(label, style: theme.textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!allDay && at != null) ...[
          const SizedBox(width: AppTokens.space8),
          OutlinedButton(
            onPressed: onPickTime,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.space12,
                vertical: AppTokens.space12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTokens.radiusM),
              ),
            ),
            child: Text(KoDate.time(at!)),
          ),
        ],
      ],
    );
  }
}

/// AddTodoSheet 가 사용자가 제출한 form 데이터를 한 묶음으로 전달.
class AddTodoSubmission {
  const AddTodoSubmission({
    required this.title,
    required this.category,
    required this.dueAt,
    this.isAllDay = false,
    required this.addToCalendar,
    this.type = TodoType.task,
    this.description,
    this.endAt,
    this.timeAnchor = 'start',
    this.parentId,
    this.recurrence,
    this.recurrenceEndAt,
  });

  final String title;
  final Category category;
  final DateTime? dueAt;

  /// date-repeat — 반복 규칙. null 이면 단발(비반복) 할 일. non-null 이면 이 submission
  /// 은 반복 마스터로 저장되고, 발생일마다 인스턴스가 자동 생성된다.
  final RecurrenceRule? recurrence;

  /// date-repeat — 반복 종료일(선택). recurrence 가 null 이면 무의미.
  final DateTime? recurrenceEndAt;

  /// Task C — "하위 추가" 모드면 부모 todo 의 id. null 이면 root 생성.
  final String? parentId;

  /// dueAt 이 "하루 종일" 의미인지. dueAt 이 null 이면 의미 없음 (false).
  /// AddTodoController 가 CalendarService.createEventForTodo 에 전달.
  final bool isAllDay;

  final bool addToCalendar;

  /// v1.1 — task / note 구분. note 면 dueAt/addToCalendar 는 강제로 무효 처리됨.
  final TodoType type;

  /// v1.2 — 상세 메모 (long text). null / 빈 문자열 모두 "없음" 의미.
  final String? description;

  /// fast-tasks — 기간 모드의 종료 시각. 단일 모드면 null.
  final DateTime? endAt;

  /// fast-tasks — 단일·시간 모드에서 dueAt 이 '시작'('start')/'마감'('end')인지.
  final String timeAnchor;
}
