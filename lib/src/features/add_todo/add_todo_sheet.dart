import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/theme.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../domain/recurrence.dart';
import '../../domain/recurrence_materializer.dart';
import '../../domain/todo.dart' show Todo, TodoDateMode, TodoType;
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
    this.initialTodo,
    this.prefillFrom,
    this.now,
    this.initialDueAt,
    this.initialAllDay = true,
    this.parentId,
  });

  final Category initialCategory;

  /// Task C — non-null 이면 "하위 추가" 모드. 생성되는 todo 의 parentId 가 이 값으로
  /// 고정되고, category 는 [initialCategory] (= 부모 category) 로 프리셋된다.
  /// 카테고리 선택 UI 는 숨김 (부모와 같은 카테고리로 강제). edit 모드와는 무관.
  final String? parentId;

  /// 테스트 결정성을 위해 주입 가능. 기본 [DateTime.now].
  final DateTime Function()? now;

  /// 초기 dueAt 값. 위젯 테스트에서 picker dialog 우회용. null 이면 일정 없음.
  @visibleForTesting
  final DateTime? initialDueAt;

  /// [initialDueAt] 가 종일 의미인지. 기본 true.
  @visibleForTesting
  final bool initialAllDay;

  /// 신규 추가 모드 — submission 콜백. edit 모드 (initialTodo != null) 면 호출 안 됨.
  final void Function(AddTodoSubmission submission) onSubmit;

  /// v1.2 — edit 모드 콜백. [initialTodo] 가 non-null 일 때 _submit 이 update 분기로
  /// 호출. 호출자는 todoActionsProvider.update 또는 동등 mutation 수행.
  final void Function(Todo updated)? onUpdate;

  /// v1.2 — null 이면 add 모드 (기존), non-null 이면 edit 모드. _titleCtrl /
  /// _descriptionCtrl / _category / _dueAt / _type 가 모두 prefill 된다.
  final Todo? initialTodo;

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
  static Future<void> show(
    BuildContext context, {
    Category initialCategory = Category.daily,
    required void Function(AddTodoSubmission) onSubmit,
    void Function(Todo updated)? onUpdate,
    Todo? initialTodo,
    Todo? prefillFrom,
    String? parentId,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: AddTodoSheet(
          initialCategory: initialCategory,
          onSubmit: onSubmit,
          onUpdate: onUpdate,
          initialTodo: initialTodo,
          prefillFrom: prefillFrom,
          parentId: parentId,
        ),
      ),
    );
  }

  @override
  ConsumerState<AddTodoSheet> createState() => _AddTodoSheetState();
}

class _AddTodoSheetState extends ConsumerState<AddTodoSheet> {
  late final TextEditingController _titleCtrl;
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

  /// date-repeat — 반복 주기. null = 반복 안 함(단발). non-null 이면 마스터로 저장.
  /// 추가 모드 전용 (편집 모드에서 규칙 수정은 별도 동작 — PRD FR-6).
  RecurrenceFreq? _recurrenceFreq;

  /// 반복 N간격 (1 이상). 예: weekly + 2 = 격주.
  int _recurrenceInterval = 1;

  /// weekly 전용 — 반복 요일 집합(1=월..7=일). 비면 anchor 요일.
  final Set<int> _recurrenceWeekdays = {};

  /// 반복 종료일(선택). null = 무한.
  DateTime? _recurrenceEndAt;

  /// v1.2 — 상세 메모 펼침/접힘. default 접힘. description 가 비어있지 않으면 펼침.
  bool _showDescription = false;

  /// edit 모드 (initialTodo != null) 여부 — 시그니처 / 버튼 라벨 / submit 분기 사용.
  bool get _isEditMode => widget.initialTodo != null;

  /// Task C — "하위 추가" 모드 (parentId 지정 + edit 아님). 카테고리 선택 UI 를 숨기고
  /// 부모 category 로 프리셋한다.
  bool get _isChildMode => !_isEditMode && widget.parentId != null;

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
    _descriptionCtrl = TextEditingController(text: source?.description ?? '');
    _category = source?.category ?? widget.initialCategory;
    // prefill 카테고리(edit/복사 공통)는 이미 영속된 실제 값 → 신뢰. add 기본값은 미신뢰.
    _categoryTrusted = source != null;
    _dueAt = source?.dueAt ?? widget.initialDueAt;
    _allDay = widget.initialAllDay;
    _type = source?.type ?? TodoType.task;
    // prefill 시 description 이 비어있지 않으면 펼친 상태로 시작.
    _showDescription = (source?.description ?? '').isNotEmpty;
    _restoreDateMode(source);
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
        _endAt = initial.endAt;
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

  void _submit() {
    if (_submitted || _titleCtrl.text.trim().isEmpty || _rangeInvalid) return;
    _submitted = true;
    final isNote = _type == TodoType.note;
    final trimmedDesc = _descriptionCtrl.text.trim();
    final descOrNull = trimmedDesc.isEmpty ? null : trimmedDesc;
    final date = _serializeDate();

    // edit 모드 — onUpdate 콜백 호출 (updatedAt 갱신은 호출자/Controller 책임).
    final initial = widget.initialTodo;
    if (_isEditMode && initial != null) {
      // 카테고리를 바꿨고 이 항목이 하위(자식)였다면 → 부모에서 분리해 새 카테고리의
      // 최상위로 올린다. (자식은 parentId 로 부모 밑에 고정되므로, 분리하지 않으면
      // 카테고리만 바뀌고 화면상 부모 아래 그대로 남아 "이동이 안 되는" 것처럼 보인다.)
      final movedCategory = _category.id != initial.category.id;
      final detach = movedCategory && initial.parentId != null;
      final updated = initial.copyWith(
        title: _titleCtrl.text.trim(),
        category: _category,
        dueAt: date.dueAt,
        endAt: date.endAt,
        isAllDay: date.isAllDay,
        timeAnchor: date.timeAnchor,
        type: _type,
        description: descOrNull,
        parentId: detach ? null : initial.parentId,
        // §14-C — task→note 전환 시 doneAt/calendar 제거. note 는 체크·일정 개념이
        // 없어 옛 doneAt 이 남으면 note→task 복귀 때 갑자기 완료로 표시되는 사고가 난다.
        // (dueAt/isAllDay 는 _serializeDate 가 note 일 때 이미 null/false 로 비운다.)
        doneAt: isNote ? null : initial.doneAt,
        calendarEventId: isNote ? null : initial.calendarEventId,
      );
      widget.onUpdate?.call(updated);
      Navigator.of(context).maybePop();
      return;
    }

    // date-repeat — 반복 규칙(추가 모드 + task + 주기 선택 시). dueAt 없으면 무의미.
    final recurrence =
        (!isNote && _recurrenceFreq != null && date.dueAt != null)
        ? RecurrenceRule(
            freq: _recurrenceFreq!,
            interval: _recurrenceInterval < 1 ? 1 : _recurrenceInterval,
            byWeekday: _recurrenceFreq == RecurrenceFreq.weekly
                ? {..._recurrenceWeekdays}
                : const {},
          )
        : null;

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

  /// 같은 카테고리 / parent / dueAt / type 으로 N건 일괄 추가. _submitted race 가드.
  /// v1.1 첫 cut — 평탄 (들여쓰기 인식 X). 들여쓰기 자동 트리화는 v1.2.
  void _submitBulk(List<String> titles) {
    if (_submitted || titles.isEmpty || _rangeInvalid) return;
    _submitted = true;
    final isNote = _type == TodoType.note;
    final trimmedDesc = _descriptionCtrl.text.trim();
    final descOrNull = trimmedDesc.isEmpty ? null : trimmedDesc;
    final date = _serializeDate();
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
        ),
      );
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  /// TextField onChanged 콜백. 멀티라인 paste 면 confirm dialog → bulk submit.
  /// 단일 라인 입력은 일반 setState 만 (추가 버튼 활성화 토글).
  Future<void> _onTitleChanged(String value) async {
    if (!value.contains('\n')) {
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
      // 취소 — \n 제거하여 단일 row 로 복구 (paste 전 상태 회복은 어렵지만 cursor 정상화).
      _titleCtrl.text = lines.join(' ');
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
        content: Text('$n개의 항목을 같은 카테고리 / 일정으로 한 번에 추가하시겠습니까?'),
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
          // 기간 — 시작은 현재 dueAt(날짜), 종료는 시작 다음날 디폴트.
          final base = _dueAt ?? (widget.now ?? DateTime.now)();
          final startDay = DateTime(base.year, base.month, base.day);
          _dueAt = startDay;
          _endAt = startDay.add(const Duration(days: 1));
          _rangeAllDay = true;
          _allDay = true;
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
    final time = await showTimePicker(context: context, initialTime: initial);
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

  /// 빠른 칩 — 날짜만 지정 (시간 = 자정, allDay = true).
  /// 사용자가 같은 칩을 다시 누르면 토글 해제 (= dueAt 비우기).
  void _setQuickDate(DateTime date) {
    final d0 = DateTime(date.year, date.month, date.day);
    setState(() {
      if (_dueAt != null && _allDay && _isSameDate(_dueAt!, d0)) {
        _dueAt = null;
        _endAt = null;
        _allDay = true;
        _dateMode = _DateInputMode.allDay;
        _addToCalendar = false;
      } else {
        _dueAt = d0;
        _endAt = null;
        _allDay = true;
        _dateMode = _DateInputMode.allDay;
      }
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
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null || !mounted) return;
    setState(() {
      _rangeAllDay = false;
      _dueAt = DateTime(
        base.year,
        base.month,
        base.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _pickRangeEndTime() async {
    final base = _endAt ?? _dueAt ?? (widget.now ?? DateTime.now)();
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
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

    return Material(
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
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _DismissIntent: CallbackAction<_DismissIntent>(
                onInvoke: (_) {
                  Navigator.of(context).maybePop();
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
                  Text(
                    _isEditMode
                        ? '할 일 편집'
                        : (_isChildMode ? '하위 항목 추가' : '새 할 일'),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppTokens.space16),
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
                  const SizedBox(height: AppTokens.space12),
                  // v1.2 — 상세 메모 토글 + multi-line TextField.
                  _DescriptionToggle(
                    expanded: _showDescription,
                    onToggle: () =>
                        setState(() => _showDescription = !_showDescription),
                  ),
                  if (_showDescription) ...[
                    const SizedBox(height: AppTokens.space8),
                    TextField(
                      key: const ValueKey('add-todo-description'),
                      controller: _descriptionCtrl,
                      minLines: 3,
                      maxLines: 8,
                      maxLength: 5000,
                      keyboardType: TextInputType.multiline,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: '상세 메모 (선택)',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                    ),
                  ],
                  // Task C — "하위 추가" 모드는 부모 category 로 고정 → 선택 UI 숨김.
                  if (!_isChildMode) ...[
                    const SizedBox(height: AppTokens.space16),
                    _SectionLabel(text: '카테고리'),
                    const SizedBox(height: AppTokens.space8),
                    _CategoryChips(
                      categories: categories,
                      groups: groups,
                      selected: _category,
                      // 사용자가 명시 선택 → 신뢰 표시 (자동 보정 대상에서 제외).
                      onSelect: (c) => setState(() {
                        _category = c;
                        _categoryTrusted = true;
                      }),
                    ),
                  ],
                  const SizedBox(height: AppTokens.space16),
                  _SectionLabel(text: '종류'),
                  const SizedBox(height: AppTokens.space8),
                  _TypeToggle(selected: _type, onSelect: _setType),
                  const SizedBox(height: AppTokens.space16),
                  // note 면 일정 영역 자체를 숨김 — 의미 없음.
                  if (_type == TodoType.task) ...[
                    _SectionLabel(text: '일정'),
                    const SizedBox(height: AppTokens.space8),
                    _DateModeSelector(
                      selected: _dateMode,
                      onSelect: _setDateMode,
                    ),
                    const SizedBox(height: AppTokens.space12),
                    if (_dateMode == _DateInputMode.range)
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
                      )
                    else ...[
                      // 단일 모드 (하루종일/시작/마감) — 기존 빠른 칩 + DueRow.
                      _QuickDueChips(
                        today: _today(),
                        dueAt: _dueAt,
                        allDay: _allDay,
                        onSelectDate: _setQuickDate,
                        onPickTime: _pickTime,
                      ),
                      const SizedBox(height: AppTokens.space8),
                      _DueRow(
                        dueAt: _dueAt,
                        allDay: _allDay,
                        onPickDate: _pickDueDate,
                        onPickTime: _pickTime,
                        onMakeAllDay: _makeAllDay,
                        onClear: _clearDueAt,
                      ),
                    ],
                    AnimatedSize(
                      duration: AppTokens.motionFast,
                      alignment: Alignment.topCenter,
                      child: _dueAt == null
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(
                                top: AppTokens.space12,
                              ),
                              child: _CalendarToggle(
                                value: _addToCalendar,
                                onChanged: (v) =>
                                    setState(() => _addToCalendar = v),
                              ),
                            ),
                    ),
                    // date-repeat — 반복 규칙 (추가 모드 + 날짜 지정 시에만).
                    // 편집 모드에서 규칙 수정은 별도 동작이라 노출하지 않는다 (PRD FR-6).
                    if (!_isEditMode && _dueAt != null) ...[
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
                        onClearEnd: () =>
                            setState(() => _recurrenceEndAt = null),
                      ),
                    ],
                    // 편집 모드 + 반복 시리즈 항목 → 규칙 요약 + "반복 중지" (FR-6).
                    // 규칙 자체 수정은 미지원이라 입력 UI 대신 정보+중지만 노출.
                    if (_isEditMode &&
                        (widget.initialTodo?.isInRecurringSeries ?? false)) ...[
                      const SizedBox(height: AppTokens.space16),
                      _SectionLabel(text: '반복'),
                      const SizedBox(height: AppTokens.space8),
                      _RecurrenceEditInfo(item: widget.initialTodo!),
                    ],
                  ],
                  const SizedBox(height: AppTokens.space20),
                  _Actions(
                    canSubmit: _canSubmit,
                    onSubmit: _submit,
                    submitLabel: _isEditMode ? '저장' : '추가',
                  ),
                ],
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

class _CategoryChips extends StatelessWidget {
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

  Widget _wrap(List<Category> items) {
    return Wrap(
      spacing: AppTokens.space8,
      runSpacing: AppTokens.space8,
      children: [
        for (final c in items)
          _CategoryChip(
            category: c,
            // 전체 동등 비교는 DB 인스턴스 ↔ const 차이로 어긋날 수 있어 id 로 비교.
            selected: c.id == selected.id,
            onTap: () => onSelect(c),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 그룹이 하나도 없으면 기존처럼 평면 한 줄 Wrap (불필요한 헤더 미노출).
    if (groups.isEmpty) return _wrap(categories);

    final ungrouped = <Category>[];
    final byGroup = <String, List<Category>>{};
    for (final c in categories) {
      final gid = c.groupId;
      if (gid == null) {
        ungrouped.add(c);
      } else {
        byGroup.putIfAbsent(gid, () => <Category>[]).add(c);
      }
    }
    // 존재하지 않는 그룹에 매인 카테고리는 미분류로 흡수.
    final groupIds = groups.map((g) => g.id).toSet();
    for (final entry in byGroup.entries.toList()) {
      if (!groupIds.contains(entry.key)) {
        ungrouped.addAll(entry.value);
        byGroup.remove(entry.key);
      }
    }

    final sections = <Widget>[];
    if (ungrouped.isNotEmpty) {
      sections.add(const _GroupSectionLabel(label: '미분류'));
      sections.add(const SizedBox(height: AppTokens.space8));
      sections.add(_wrap(ungrouped));
    }
    for (final g in groups) {
      final items = byGroup[g.id] ?? const <Category>[];
      if (items.isEmpty) continue;
      if (sections.isNotEmpty) {
        sections.add(const SizedBox(height: AppTokens.space12));
      }
      sections.add(_GroupSectionLabel(label: g.label, color: g.color));
      sections.add(const SizedBox(height: AppTokens.space8));
      sections.add(_wrap(items));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: sections,
    );
  }
}

/// J — 카테고리 칩 섹션 헤더 (그룹명/'미분류' + 색 dot).
class _GroupSectionLabel extends StatelessWidget {
  const _GroupSectionLabel({required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dot = color ?? scheme.onSurface.withValues(alpha: 0.4);
    return Row(
      children: [
        Icon(Icons.circle, size: 9, color: dot),
        const SizedBox(width: AppTokens.space8),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.6),
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
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

class _DueRow extends StatelessWidget {
  const _DueRow({
    required this.dueAt,
    required this.allDay,
    required this.onPickDate,
    required this.onPickTime,
    required this.onMakeAllDay,
    required this.onClear,
  });

  final DateTime? dueAt;
  final bool allDay;
  final VoidCallback onPickDate;
  final VoidCallback onPickTime;
  final VoidCallback onMakeAllDay;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasDue = dueAt != null;
    final label = !hasDue
        ? '날짜 추가 (선택)'
        : (allDay
              ? '${KoDate.pretty(dueAt!)} · 하루 종일'
              : '${KoDate.pretty(dueAt!)} · ${KoDate.time(dueAt!)}');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
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
                  Icon(
                    Icons.event_outlined,
                    size: 18,
                    color: hasDue
                        ? scheme.primary
                        : scheme.onSurface.withValues(alpha: 0.55),
                  ),
                  const SizedBox(width: AppTokens.space12),
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: hasDue
                            ? scheme.onSurface
                            : scheme.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                  if (hasDue)
                    IconButton(
                      onPressed: onClear,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      tooltip: '일정 비우기',
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
          ),
        ),
        if (hasDue) ...[
          const SizedBox(height: AppTokens.space8),
          Row(
            children: [
              if (allDay)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onPickTime,
                    icon: const Icon(Icons.schedule_outlined, size: 16),
                    label: const Text('시간 추가'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppTokens.space8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTokens.radiusM),
                      ),
                    ),
                  ),
                )
              else ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onPickTime,
                    icon: const Icon(Icons.schedule_outlined, size: 16),
                    label: const Text('시간 변경'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppTokens.space8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTokens.radiusM),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppTokens.space8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onMakeAllDay,
                    icon: const Icon(Icons.wb_sunny_outlined, size: 16),
                    label: const Text('하루 종일'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppTokens.space8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTokens.radiusM),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
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
  });

  final bool canSubmit;
  final VoidCallback onSubmit;
  final String submitLabel;

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
            child: const Text('취소'),
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

/// v1.2 — 상세 메모 펼침/접힘 토글.
class _DescriptionToggle extends StatelessWidget {
  const _DescriptionToggle({required this.expanded, required this.onToggle});

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const ValueKey('add-todo-description-toggle'),
        onPressed: onToggle,
        icon: Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18),
        label: const Text('상세 메모'),
        style: TextButton.styleFrom(
          foregroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.78),
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space8,
            vertical: AppTokens.space4,
          ),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
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

/// 빠른 dueAt 선택 칩 — "오늘 / 내일 / 다음주 / 시간 지정".
///
/// "다음주" 는 오늘로부터 7일 후 자정 (= 1주일 뒤) 으로 정의 — "다음주 월요일" 처럼
/// 주의 시작 정의에 따라 의미가 달라지는 모호함을 피하기 위함.
///
/// 같은 칩을 다시 누르면 toggle 해제 → dueAt 비우기. "시간 지정" 만 별개 동작 —
/// 항상 [showTimePicker] 를 띄움 (현재 _dueAt 보존 + 시간만 변경).
class _QuickDueChips extends StatelessWidget {
  const _QuickDueChips({
    required this.today,
    required this.dueAt,
    required this.allDay,
    required this.onSelectDate,
    required this.onPickTime,
  });

  final DateTime today;
  final DateTime? dueAt;
  final bool allDay;
  final void Function(DateTime date) onSelectDate;
  final VoidCallback onPickTime;

  bool _isSelectedDate(DateTime target) {
    final d = dueAt;
    if (d == null || !allDay) return false;
    return d.year == target.year &&
        d.month == target.month &&
        d.day == target.day;
  }

  @override
  Widget build(BuildContext context) {
    final tomorrow = today.add(const Duration(days: 1));
    final nextWeek = today.add(const Duration(days: 7));
    final timeChipSelected = dueAt != null && !allDay;

    return Wrap(
      spacing: AppTokens.space8,
      runSpacing: AppTokens.space8,
      children: [
        _QuickDueChip(
          key: const ValueKey('quick-due-today'),
          label: '오늘',
          icon: Icons.today_outlined,
          selected: _isSelectedDate(today),
          onTap: () => onSelectDate(today),
        ),
        _QuickDueChip(
          key: const ValueKey('quick-due-tomorrow'),
          label: '내일',
          icon: Icons.update_outlined,
          selected: _isSelectedDate(tomorrow),
          onTap: () => onSelectDate(tomorrow),
        ),
        _QuickDueChip(
          key: const ValueKey('quick-due-next-week'),
          label: '다음주',
          icon: Icons.next_week_outlined,
          selected: _isSelectedDate(nextWeek),
          onTap: () => onSelectDate(nextWeek),
        ),
        _QuickDueChip(
          key: const ValueKey('quick-due-time'),
          label: '시간 지정',
          icon: Icons.schedule_outlined,
          selected: timeChipSelected,
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

/// fast-tasks — 4 모드 (하루종일/시작시간/마감시간/기간) 선택 ChoiceChip 줄.
class _DateModeSelector extends StatelessWidget {
  const _DateModeSelector({required this.selected, required this.onSelect});

  final _DateInputMode selected;
  final ValueChanged<_DateInputMode> onSelect;

  static const _items = <(_DateInputMode, String, IconData, String)>[
    (
      _DateInputMode.allDay,
      '하루종일',
      Icons.wb_sunny_outlined,
      'date-mode-all-day',
    ),
    (
      _DateInputMode.startTime,
      '시작시간',
      Icons.play_arrow_outlined,
      'date-mode-start',
    ),
    (_DateInputMode.endTime, '마감시간', Icons.flag_outlined, 'date-mode-end'),
    (_DateInputMode.range, '기간', Icons.date_range_outlined, 'date-mode-range'),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppTokens.space8,
      runSpacing: AppTokens.space8,
      children: [
        for (final (mode, label, icon, key) in _items)
          _TypeChip(
            key: ValueKey(key),
            label: label,
            icon: icon,
            selected: selected == mode,
            onTap: () => onSelect(mode),
          ),
      ],
    );
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
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
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
