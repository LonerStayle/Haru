import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../core/ui_prefs.dart';
import '../../data/providers.dart';
import '../../ui/widgets/click_tolerant_draggable.dart';
import '../../ui/widgets/undo_snackbar.dart';
import '../home/today_providers.dart';
import '../search/search_screen.dart';
import '../settings/settings_sheet.dart';
import '../timeline/timeline_screen.dart';
import '../todo_actions/todo_actions_controller.dart';
import 'calendar_actions.dart';
import 'calendar_day_panel.dart';
import 'calendar_drag.dart';
import 'calendar_entry.dart';
import 'calendar_month_grid.dart';
import 'calendar_providers.dart';
import 'calendar_undated_drawer.dart';
import 'calendar_week_row.dart';

/// 데스크탑 우측 선택일 패널의 기본 폭. 경계를 끌어 바꿀 수 있다(저장됨).
const double _panelWidth = 340;

/// 패널 폭 조절 범위.
const double _panelMinWidth = 280;
const double _panelMaxWidth = 560;

const String _panelCollapsedFlag = 'panelCollapsed';

/// 패널을 띄우고도 격자에 남겨야 하는 최소 폭.
///
/// 이보다 좁아지면 패널을 자동으로 접는다 — 안 그러면 패널이 창보다 넓어
/// 가로 오버플로가 난다 (사이드바까지 낀 좁은 창에서 실제로 났다).
const double _minGridWidth = 280;

/// 캘린더 화면의 두 보기 방식.
enum CalendarSegment {
  /// 월 달력 격자 + 선택일 목록.
  grid,

  /// v1.5 타임라인 버킷 목록 (지남/오늘/내일/이번주/이후).
  list,
}

/// 앱 내 캘린더 화면.
///
/// v1.5 의 '타임라인' destination 을 흡수했다. 모바일 NavigationBar 가 4슬롯
/// 고정이라 destination 을 늘리는 대신 교체하고, 기존 버킷 목록은 이 화면의
/// `[타임라인]` 세그먼트로 그대로 살렸다 — 자리 문제도 기능 손실도 없다.
///
/// 포커스 달 / 선택일 / 세그먼트는 이 State 에 둔다. 요구사항이 "세션 내에서만
/// 유지, 영속 저장 없음" 이라 전역 provider 로 뺄 이유가 없고, 위젯 테스트가
/// 상호작용만으로 전부 검증 가능해진다.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  /// 무한 스와이프를 위한 가상 페이지 원점. 이 값에서 ±로 달을 센다
  /// (실제로 6000개월 = 500년이라 사용 중 경계에 닿을 일이 없다).
  static const int _basePage = 6000;

  late final DateTime _baseMonth;
  late final PageController _pager;
  late final CalendarSelectionHolder _selection;

  late DateTime _focusedMonth;
  late DateTime _selectedDay;
  CalendarSegment _segment = CalendarSegment.grid;

  /// 모바일 위(달력)·아래(선택일 목록) 분할 상태. 패널 위 손잡이 하나로 바꾼다
  /// (예전엔 달력 접기·목록 접기·아래 막대, 조작이 세 벌이었다). 세션 안에서만 유지.
  _MobileSplit _mobileSplit = _MobileSplit.split;

  /// 데스크탑 패널 폭을 끄는 중의 임시 값 — 끄는 동안 매 프레임 저장하지 않으려고.
  double? _draggingPanelWidth;

  /// 데스크탑 칸 두 번 클릭 판정 — 첫 클릭은 곧바로 선택(지연 없음), 같은 칸을
  /// [_doubleClickWindow] 안에 다시 누르면 그 날짜로 새 할 일.
  DateTime? _lastTapDay;
  DateTime? _lastTapAt;
  static const Duration _doubleClickWindow = Duration(milliseconds: 400);

  /// 드래그 중 달력 가장자리에 머물면 달을 넘기는 타이머.
  Timer? _edgeFlipTimer;

  @override
  void initState() {
    super.initState();
    final today = dateOnly(ref.read(nowProvider)());
    _baseMonth = DateTime(today.year, today.month);
    _focusedMonth = _baseMonth;
    _selectedDay = today;
    _pager = PageController(initialPage: _basePage);
    _selection = ref.read(calendarSelectionProvider)..selectedDay = today;
  }

  @override
  void dispose() {
    _edgeFlipTimer?.cancel();
    _selection.selectedDay = null;
    _pager.dispose();
    super.dispose();
  }

  DateTime _monthForPage(int page) =>
      DateTime(_baseMonth.year, _baseMonth.month + (page - _basePage));

  int _pageForMonth(DateTime month) =>
      _basePage +
      (month.year - _baseMonth.year) * 12 +
      (month.month - _baseMonth.month);

  void _goToMonth(DateTime month, {bool animate = true}) {
    // 의도한 달을 **즉시** 반영한다. 애니메이션이 끝날 때(onPageChanged)만 갱신하면
    // ← ← 를 빠르게 두 번 눌렀을 때 두 번째가 옛 달을 기준으로 계산해 한 칸만 움직인다.
    setState(() => _focusedMonth = DateTime(month.year, month.month));
    final page = _pageForMonth(month);
    if (!_pager.hasClients) return;
    if (animate) {
      _pager.animateToPage(
        page,
        duration: AppTokens.motionMid,
        curve: Curves.easeOutCubic,
      );
    } else {
      _pager.jumpToPage(page);
    }
  }

  void _shiftMonth(int delta) =>
      _goToMonth(DateTime(_focusedMonth.year, _focusedMonth.month + delta));

  void _setSelected(DateTime date) {
    _selectedDay = dateOnly(date);
    _selection.selectedDay = _selectedDay;
  }

  void _selectDay(DateTime date) {
    setState(() => _setSelected(date));
    // 넘침 날짜를 탭했으면 그 달로 따라 이동한다 — 안 그러면 선택 표시가
    // 화면 밖 달에 가 있어 무슨 일이 일어났는지 알 수 없다.
    if (date.month != _focusedMonth.month || date.year != _focusedMonth.year) {
      _goToMonth(date);
    }
  }

  /// 칸 탭. 데스크탑에서 같은 칸을 곧바로 한 번 더 누르면 그 날짜로 새 할 일.
  ///
  /// InkWell 의 onDoubleTap 을 쓰지 않는 이유: 그걸 달면 한 번 클릭도 두 번째 클릭을
  /// 기다리느라 약 300ms 늦게 선택된다. 첫 클릭은 즉시 선택하고 두 번째만 따로 본다.
  void _tapDay(DateTime date) {
    final day = dateOnly(date);
    final now = DateTime.now();
    final isDouble =
        AppPlatform.isDesktop &&
        _lastTapDay == day &&
        _lastTapAt != null &&
        now.difference(_lastTapAt!) <= _doubleClickWindow;
    _selectDay(day);
    if (isDouble) {
      _lastTapDay = null;
      _lastTapAt = null;
      openAddTodoOnDate(context, ref, day);
      return;
    }
    _lastTapDay = day;
    _lastTapAt = now;
  }

  /// 데스크탑 칸 우클릭 메뉴 — 커서 자리에 뜬다.
  Future<void> _showDayMenu(DateTime date, Offset globalPosition) async {
    _selectDay(date);
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final action = await showMenu<_DayMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          key: const ValueKey('calendar-day-menu-add'),
          value: _DayMenuAction.add,
          child: Text('${KoDate.dayWithWeekday(date)}에 추가'),
        ),
        const PopupMenuItem(
          key: ValueKey('calendar-day-menu-today'),
          value: _DayMenuAction.today,
          child: Text('오늘로 이동'),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _DayMenuAction.add:
        await openAddTodoOnDate(context, ref, date);
      case _DayMenuAction.today:
        _goToToday();
    }
  }

  void _goToToday() {
    final today = dateOnly(ref.read(nowProvider)());
    setState(() => _setSelected(today));
    _goToMonth(today);
  }

  /// 달력 칸에 항목을 떨어뜨렸을 때 — 날짜만 바꾸고 순서는 보존한다. 되돌리기 제공.
  ///
  /// 고스트(미래 반복 예정)는 옮길 row 자체가 없으므로 먼저 그 회차를 실체화한다 —
  /// 반복 전체가 아니라 **그 회차만** 옮겨진다(안내 문구에 밝힌다).
  Future<void> _handleDrop(CalendarDragData data, DateTime date) async {
    _edgeFlipTimer?.cancel();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final actions = ref.read(todoActionsProvider);
    final isOccurrence = switch (data) {
      UndatedDragData() => false,
      EntryDragData(:final entry) =>
        entry.isGhost || (entry is TodoEntry && entry.todo.isInRecurringSeries),
    };
    final todo = switch (data) {
      UndatedDragData(:final todo) => todo,
      EntryDragData(:final entry) => await resolveEntryTodo(ref, entry),
    };
    if (todo == null) return;

    final moved = applyDateDrop(todo, date);
    // 같은 날에 떨어뜨렸으면 applyDateDrop 이 원본을 그대로 돌려준다 → 저장 생략.
    if (identical(moved, todo)) return;
    await actions.updatePreservingOrder(moved);
    if (!mounted) return;
    // 옮긴 결과를 바로 보여준다 — 어디로 갔는지 눈으로 확인시키는 게 핵심.
    setState(() => _setSelected(date));
    if (messenger == null || !messenger.mounted) return;
    final where = KoDate.dayWithWeekday(dateOnly(date));
    showUndoSnackbarOn(
      messenger,
      message: isOccurrence
          ? '"${todo.title}" 이 회차만 $where(으)로 옮겼어요'
          : '"${todo.title}" → $where',
      onUndo: () => actions.restoreSchedule(todo),
    );
  }

  Widget _dropTarget(DateTime date, CalendarDayCellBuilder build) {
    return DragTarget<CalendarDragData>(
      onWillAcceptWithDetails: (details) => switch (details.data) {
        UndatedDragData() => true,
        // 구글 이벤트는 읽기 전용이라 애초에 드래그되지 않지만, 방어적으로 한 번 더.
        // 원래 자리에 다시 놓는 건 변화가 아니라 하이라이트도 하지 않는다.
        EntryDragData(:final entry) =>
          entry.isDraggable && isMeaningfulDrop(entry, date),
      },
      onAcceptWithDetails: (details) => _handleDrop(details.data, date),
      builder: (context, candidate, _) =>
          build(isDropTarget: candidate.isNotEmpty),
    );
  }

  /// 드래그 중 가장자리에 머물면 [delta] 방향으로 달을 넘긴다(머무는 동안 반복).
  void _startEdgeFlip(int delta) {
    _edgeFlipTimer?.cancel();
    _edgeFlipTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (mounted) _shiftMonth(delta);
    });
  }

  void _stopEdgeFlip() {
    _edgeFlipTimer?.cancel();
    _edgeFlipTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    // 과거~오늘 반복 회차의 실체화 보장 — '오늘' 화면을 거치지 않고 캘린더로
    // 바로 들어와도 반복이 비어 보이지 않게 한다 (HomeScreen 과 같은 규약).
    ref.watch(recurrenceMaterializerProvider);

    final today = dateOnly(ref.watch(nowProvider)());
    final compact = AppPlatform.isMobile;
    final panelCollapsed = ref
        .watch(persistedIdSetProvider(calendarPrefsKey))
        .contains(_panelCollapsedFlag);

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowLeft): _PrevMonthIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight): _NextMonthIntent(),
        SingleActivator(LogicalKeyboardKey.keyT): _TodayIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _PrevMonthIntent: CallbackAction<_PrevMonthIntent>(
            onInvoke: (_) => _shiftMonth(-1),
          ),
          _NextMonthIntent: CallbackAction<_NextMonthIntent>(
            onInvoke: (_) => _shiftMonth(1),
          ),
          _TodayIntent: CallbackAction<_TodayIntent>(
            onInvoke: (_) => _goToToday(),
          ),
        },
        // 이 화면 안에 포커스 노드를 둬야 위 Shortcuts 가 키를 받는다.
        // (app_shell 의 Focus 는 우리보다 **위**에 있어 그쪽에 포커스가 있으면
        // 여기까지 내려오지 않는다.) 시트의 TextField 가 포커스를 가져가면
        // 자동으로 비활성화되므로 입력 중 오작동도 없다.
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              _CalendarHeader(
                focusedMonth: _focusedMonth,
                segment: _segment,
                onPrev: () => _shiftMonth(-1),
                onNext: () => _shiftMonth(1),
                onToday: _goToToday,
                onSegment: (s) => setState(() => _segment = s),
                panelCollapsed: panelCollapsed,
                // 우측 패널은 데스크탑에만 있다 — 모바일은 아래위 분할이라 대상이 없다.
                onTogglePanel: compact
                    ? null
                    : () => ref
                          .read(
                            persistedIdSetProvider(calendarPrefsKey).notifier,
                          )
                          .toggle(_panelCollapsedFlag),
              ),
              Expanded(
                child: _segment == CalendarSegment.list
                    ? const TimelineScreen(showHeader: false)
                    : compact
                    ? _buildMobileBody(today)
                    : _buildDesktopBody(today, panelCollapsed),
              ),
              // 서랍은 달력 보기에서만. 목록(타임라인)에는 날짜 지정 항목만 나오므로
              // 무날짜 서랍이 붙을 자리가 아니다.
              if (_segment == CalendarSegment.grid)
                CalendarUndatedDrawer(
                  itemWrapper: (todo, tile) => _dragSource(
                    data: UndatedDragData(todo),
                    title: todo.title,
                    color: todo.category.color,
                    child: tile,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopBody(DateTime today, bool panelCollapsed) {
    final saved = ref.watch(persistedIdSetProvider(calendarPanelWidthKey));
    final savedWidth = saved.isEmpty ? null : double.tryParse(saved.first);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 창이 좁으면 패널이 통째로 안 들어가 가로로 넘친다. 격자가 최소한
        // [_minGridWidth] 는 남아야 달력 구실을 하므로, 자리가 없으면 패널을 접는다.
        final fits = constraints.maxWidth >= _panelMinWidth + _minGridWidth;
        final showPanel = !panelCollapsed && fits;
        final maxWidth = math.min(
          _panelMaxWidth,
          constraints.maxWidth - _minGridWidth,
        );
        final width = (_draggingPanelWidth ?? savedWidth ?? _panelWidth)
            .clamp(_panelMinWidth, math.max(_panelMinWidth, maxWidth))
            .toDouble();

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _buildPager(today)),
            // 접으면 격자가 패널 폭만큼 넓어진다. 애니메이션 없이 즉시 전환하는 건
            // 모바일의 달력 접기와 같은 규약 — 폭이 크게 바뀌는 전환은 중간
            // 프레임이 오히려 어수선하다.
            if (showPanel) ...[
              _PanelResizer(
                onDrag: (dx) => setState(
                  () => _draggingPanelWidth = (width - dx)
                      .clamp(_panelMinWidth, math.max(_panelMinWidth, maxWidth))
                      .toDouble(),
                ),
                onDragEnd: () {
                  final w = _draggingPanelWidth;
                  if (w == null) return;
                  ref
                      .read(
                        persistedIdSetProvider(calendarPanelWidthKey).notifier,
                      )
                      .replace({w.round().toString()});
                  setState(() => _draggingPanelWidth = null);
                },
              ),
              SizedBox(width: width, child: _buildPanel()),
            ],
          ],
        );
      },
    );
  }

  /// 모바일은 위아래 분할 — 위 달력 / 아래 선택일 목록.
  ///
  /// 목록 위 손잡이 하나로 세 상태를 오간다: 위로 끌면 목록이 화면 전체(그날 할 일을
  /// 길게 볼 때), 아래로 끌면 달력이 화면 전체(달을 크게 볼 때, 하단에 얇은 막대만).
  /// 손잡이를 누르면 분할 ↔ 달력 크게.
  Widget _buildMobileBody(DateTime today) {
    void setSplit(_MobileSplit s) => setState(() => _mobileSplit = s);
    switch (_mobileSplit) {
      case _MobileSplit.gridOnly:
        return Column(
          children: [
            Expanded(child: _buildPager(today)),
            _CollapsedDayBar(
              selectedDay: _selectedDay,
              onExpand: () => setSplit(_MobileSplit.split),
            ),
          ],
        );
      case _MobileSplit.listOnly:
        return _buildPanel(
          handle: _PanelHandle(
            onTap: () => setSplit(_MobileSplit.split),
            onDragUp: null,
            onDragDown: () => setSplit(_MobileSplit.split),
          ),
        );
      case _MobileSplit.split:
        return Column(
          children: [
            Expanded(flex: 6, child: _buildPager(today)),
            Expanded(
              flex: 5,
              child: _buildPanel(
                handle: _PanelHandle(
                  onTap: () => setSplit(_MobileSplit.gridOnly),
                  onDragUp: () => setSplit(_MobileSplit.listOnly),
                  onDragDown: () => setSplit(_MobileSplit.gridOnly),
                ),
              ),
            ),
          ],
        );
    }
  }

  Widget _buildPager(DateTime today) {
    final pager = PageView.builder(
      key: const ValueKey('calendar-grid-pager'),
      controller: _pager,
      onPageChanged: (page) =>
          setState(() => _focusedMonth = _monthForPage(page)),
      itemBuilder: (context, page) {
        final month = _monthForPage(page);
        return Padding(
          padding: EdgeInsets.all(
            AppPlatform.isMobile ? AppTokens.space4 : AppTokens.space12,
          ),
          // 옆 달 페이지가 이 달의 리페인트에 딸려오지 않게 격리한다 —
          // 스와이프 중 프레임 비용을 눈에 띄게 줄인다.
          child: RepaintBoundary(
            child: _MonthPage(
              month: month,
              today: today,
              selectedDay: _selectedDay,
              onSelectDay: _tapDay,
              onLongPressDay: (date) {
                _selectDay(date);
                openAddTodoOnDate(context, ref, date);
              },
              onSecondaryTapDay: AppPlatform.isDesktop ? _showDayMenu : null,
              // 데스크탑 칩을 끌어 다른 날로 — 모바일 칸은 점이라 끌 대상이 없다
              // (모바일은 아래 목록에서 길게 눌러 끈다).
              chipWrapper: AppPlatform.isDesktop
                  ? (entry, chip) => entry.isDraggable
                        ? _dragSource(
                            data: EntryDragData(entry),
                            title: entry.title,
                            color: entry.color,
                            child: chip,
                          )
                        : chip
                  : null,
              dayCellBuilder: _dropTarget,
            ),
          ),
        );
      },
    );
    // 끄는 중 좌우 가장자리에 머물면 달을 넘긴다 — 다른 달로 옮길 수 있게.
    return Stack(
      children: [
        Positioned.fill(child: pager),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _edgeFlipWidth,
          child: _EdgeFlipTarget(
            key: const ValueKey('calendar-edge-prev'),
            onEnter: () => _startEdgeFlip(-1),
            onLeave: _stopEdgeFlip,
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: _edgeFlipWidth,
          child: _EdgeFlipTarget(
            key: const ValueKey('calendar-edge-next'),
            onEnter: () => _startEdgeFlip(1),
            onLeave: _stopEdgeFlip,
          ),
        ),
      ],
    );
  }

  Widget _buildPanel({Widget? handle}) =>
      _DayPanelSection(selectedDay: _selectedDay, handle: handle);
}

enum _MobileSplit { split, gridOnly, listOnly }

enum _DayMenuAction { add, today }

/// 끄는 중 가장자리 감지 폭 — 격자 바깥 여백(12) 안쪽에 대부분 걸치게.
const double _edgeFlipWidth = 18;

/// 드래그 중 달력 가장자리 — 위에 머물면 달을 넘긴다. 떨어뜨려도 아무 일 없다.
///
/// 드래그가 없을 땐 빈 영역이라 아래 칸의 클릭을 막지 않는다.
class _EdgeFlipTarget extends StatelessWidget {
  const _EdgeFlipTarget({
    super.key,
    required this.onEnter,
    required this.onLeave,
  });

  final VoidCallback onEnter;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return DragTarget<CalendarDragData>(
      onWillAcceptWithDetails: (_) {
        onEnter();
        return true;
      },
      onLeave: (_) => onLeave(),
      onAcceptWithDetails: (_) => onLeave(),
      builder: (context, candidate, _) => candidate.isEmpty
          ? const SizedBox.expand()
          : DecoratedBox(
              decoration: BoxDecoration(
                color: AppPalette.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppTokens.radiusS),
              ),
              child: const SizedBox.expand(),
            ),
    );
  }
}

/// 데스크탑 격자와 패널 사이 — 끌어서 패널 폭을 바꾼다(저장됨).
class _PanelResizer extends StatelessWidget {
  const _PanelResizer({required this.onDrag, required this.onDragEnd});

  /// 가로 이동량(오른쪽 +). 패널은 오른쪽에 있으니 호출측이 빼서 쓴다.
  final void Function(double dx) onDrag;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: const ValueKey('calendar-panel-resizer'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd(),
        child: const SizedBox(
          width: 7,
          child: Center(
            child: VerticalDivider(width: 1, thickness: AppTokens.hairline),
          ),
        ),
      ),
    );
  }
}

/// 모바일 선택일 목록 위 손잡이 — 끌어서 달력/목록 크기를 바꾸고, 누르면 목록을 접는다.
class _PanelHandle extends StatefulWidget {
  const _PanelHandle({
    required this.onTap,
    required this.onDragUp,
    required this.onDragDown,
  });

  final VoidCallback onTap;
  final VoidCallback? onDragUp;
  final VoidCallback? onDragDown;

  @override
  State<_PanelHandle> createState() => _PanelHandleState();
}

class _PanelHandleState extends State<_PanelHandle> {
  double _dy = 0;

  /// 이만큼 끌거나 빠르게 튕기면 한 단계 넘어간다.
  static const double _threshold = 36;

  void _end(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final up = _dy < -_threshold || v < -300;
    final down = _dy > _threshold || v > 300;
    _dy = 0;
    if (up) widget.onDragUp?.call();
    if (down) widget.onDragDown?.call();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '목록 크기 바꾸기',
      child: GestureDetector(
        key: const ValueKey('calendar-panel-handle'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onVerticalDragStart: (_) => _dy = 0,
        onVerticalDragUpdate: (d) => _dy += d.delta.dy,
        onVerticalDragEnd: _end,
        child: SizedBox(
          height: 20,
          child: Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(AppTokens.radiusFull),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 목록을 접었을 때 하단에 남는 얇은 막대 — 날짜 + 건수 + 펼치기.
///
/// 접기를 되돌릴 유일한 통로라 반드시 보이게 남긴다. 건수는 패널과 같은 버킷을
/// 보므로 여기서만 다시 watch 한다 (화면 전체 재빌드를 유발하지 않도록 분리).
class _CollapsedDayBar extends ConsumerWidget {
  const _CollapsedDayBar({required this.selectedDay, required this.onExpand});

  final DateTime selectedDay;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final range = CalendarRange.forMonth(selectedDay);
    final buckets = ref.watch(calendarBucketsProvider(range));
    final count = buckets.asData?.value[selectedDay]?.length ?? 0;

    return Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        key: const ValueKey('calendar-panel-expand'),
        onTap: onExpand,
        // 위로 밀어 올려도 펼쳐진다 — 목록 위 손잡이와 같은 동작.
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < 0) onExpand();
          },
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.space16,
                vertical: AppTokens.space8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      KoDate.dayWithWeekday(selectedDay),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    count == 0 ? '없음' : '$count건',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: AppTokens.space4),
                  const Icon(Icons.expand_less, size: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 드래그 소스 래퍼.
///
/// 데스크탑은 즉시 드래그([Draggable]), 모바일은 롱프레스([LongPressDraggable]).
/// 모바일에서 즉시 드래그를 쓰면 목록의 세로 스크롤과 제스처가 겹쳐 목록을
/// 못 굴린다. 데스크탑은 휠로 스크롤하므로 즉시 드래그가 더 빠르다.
/// (사이드바 카테고리 이동이 이미 쓰는 분기 규약과 동일.)
///
/// State 메서드가 아니라 top-level 인 이유: 화면 State 와 아래 [_DayPanelSection]
/// 이 함께 쓰는데, State 에 두면 패널을 분리할 수 없다.
Widget _dragSource({
  required CalendarDragData data,
  required String title,
  required Color color,
  required Widget child,
}) {
  final feedback = _DragFeedback(title: title, color: color);
  final placeholder = Opacity(opacity: 0.35, child: child);
  if (AppPlatform.isDesktop) {
    // 기본 Draggable 은 마우스 1px 이동에도 드래그를 시작해 카드 탭·체크 클릭을 빼앗았다
    // (대표님 제보 "클릭이 잘 안 된다"). 6px 이상 움직여야 드래그로 본다.
    return ClickTolerantDraggable<CalendarDragData>(
      data: data,
      feedback: feedback,
      childWhenDragging: placeholder,
      child: child,
    );
  }
  return LongPressDraggable<CalendarDragData>(
    data: data,
    feedback: feedback,
    childWhenDragging: placeholder,
    child: child,
  );
}

/// 선택일 목록 패널.
///
/// **별도 위젯으로 떼어낸 이유(성능)**: 예전엔 화면 State 의 build 안에서 직접
/// `calendarBucketsProvider` 를 watch 했다. 그래서 할 일 stream 이 한 번 튀거나
/// 구글 이벤트가 도착할 때마다 화면 전체 — PageView 의 달 3개 × 42칸 × DragTarget —
/// 가 통째로 재빌드돼 눈에 띄게 버벅였다. 이제 버킷 변화는 이 패널만 다시 그린다.
class _DayPanelSection extends ConsumerWidget {
  const _DayPanelSection({required this.selectedDay, this.handle});

  final DateTime selectedDay;

  /// 모바일 목록 위 손잡이 (데스크탑은 헤더의 패널 토글이 담당 → null).
  final Widget? handle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = CalendarRange.forMonth(selectedDay);
    final buckets = ref.watch(calendarBucketsProvider(range));
    final entries =
        buckets.asData?.value[selectedDay] ?? const <CalendarEntry>[];
    return CalendarDayPanel(
      date: selectedDay,
      entries: entries,
      handle: handle,
      entryWrapper: (entry, tile) => entry.isDraggable
          ? _dragSource(
              data: EntryDragData(entry),
              title: entry.title,
              color: entry.color,
              child: tile,
            )
          : tile,
    );
  }
}

/// 드래그 중 손끝을 따라다니는 미리보기.
///
/// 사이드바 카테고리 이동의 피드백과 같은 시각 언어 — 색 바 + 제목의 작은 카드.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.title, required this.color});

  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space8,
          vertical: AppTokens.space4,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(AppTokens.radiusM),
          border: Border.all(color: color, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 4,
              height: 18,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(AppTokens.radiusFull),
              ),
            ),
            const SizedBox(width: AppTokens.space8),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 한 달 페이지 — provider 구독을 페이지 단위로 가둔다.
///
/// 페이지마다 별도 위젯인 이유: `calendarBucketsProvider` 를 화면 전체에서 한 번
/// watch 하면 스와이프 중 이웃 달까지 한 프레임에 재계산돼 스크롤이 끊긴다.
class _MonthPage extends ConsumerWidget {
  const _MonthPage({
    required this.month,
    required this.today,
    required this.selectedDay,
    required this.onSelectDay,
    required this.onLongPressDay,
    required this.dayCellBuilder,
    this.onSecondaryTapDay,
    this.chipWrapper,
  });

  final DateTime month;
  final DateTime today;
  final DateTime selectedDay;
  final void Function(DateTime) onSelectDay;
  final void Function(DateTime) onLongPressDay;
  final Widget Function(DateTime, CalendarDayCellBuilder) dayCellBuilder;
  final void Function(DateTime date, Offset globalPosition)? onSecondaryTapDay;
  final Widget Function(CalendarEntry entry, Widget chip)? chipWrapper;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = CalendarRange.forMonth(month);
    final buckets = ref.watch(calendarBucketsProvider(range));
    return CalendarMonthGrid(
      focusedMonth: month,
      buckets: buckets.asData?.value ?? const {},
      today: today,
      selectedDay: selectedDay,
      onSelectDay: onSelectDay,
      onLongPressDay: onLongPressDay,
      onSecondaryTapDay: onSecondaryTapDay,
      chipWrapper: chipWrapper,
      dayCellBuilder: dayCellBuilder,
    );
  }
}

class _CalendarHeader extends StatelessWidget {
  const _CalendarHeader({
    required this.focusedMonth,
    required this.segment,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.onSegment,
    this.panelCollapsed = false,
    this.onTogglePanel,
  });

  final DateTime focusedMonth;
  final CalendarSegment segment;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final void Function(CalendarSegment) onSegment;

  /// 데스크탑 우측 선택일 패널이 접혀 있는가.
  final bool panelCollapsed;

  /// 우측 패널 접기/펼치기. null 이면 버튼 미표시 (모바일).
  final VoidCallback? onTogglePanel;

  /// 이 폭 아래로는 ‹ › 를 접는다. 달 이동은 ←/→ 키와 좌우 스와이프로도 되므로
  /// 잃는 기능이 없다.
  static const double _arrowsMinWidth = 460;

  /// 이 폭 아래로는 구글 일정 칩을 접는다 — 부가 표시라 가장 먼저 양보한다.
  static const double _googleToggleMinWidth = 380;

  @override
  Widget build(BuildContext context) {
    return AppPlatform.isMobile
        ? _buildMobile(context)
        : _buildDesktop(context);
  }

  Widget _title(BuildContext context) {
    final theme = Theme.of(context);
    final style =
        (AppPlatform.isMobile
                ? theme.textTheme.titleLarge
                : theme.textTheme.headlineSmall)
            ?.copyWith(fontWeight: FontWeight.w800);
    if (segment != CalendarSegment.grid) return Text('타임라인', style: style);
    return Text(
      KoDate.monthTitle(focusedMonth),
      key: const ValueKey('calendar-month-title'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }

  Widget _todayButton() => TextButton(
    key: const ValueKey('calendar-today-button'),
    onPressed: onToday,
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.space8),
    ),
    child: const Text('오늘'),
  );

  /// 모바일 — 두 줄. [월 제목 · 오늘 · ⋮] / [달력|타임라인 · Google].
  /// 한 줄에 여섯 개를 몰아넣던 헤더를 나눠 버튼마다 제 폭을 준다.
  Widget _buildMobile(BuildContext context) {
    final grid = segment == CalendarSegment.grid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space12,
        AppTokens.space4,
        AppTokens.space4,
        AppTokens.space4,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Flexible(child: _title(context)),
              if (grid) ...[
                const SizedBox(width: AppTokens.space4),
                _todayButton(),
              ],
              const Spacer(),
              // 모바일은 이 화면에 앱바가 없다 (달력 높이를 위해 뺐다) — 앱바가
              // 들고 있던 검색·설정을 여기서 이어받는다.
              const _MobileOverflowMenu(),
            ],
          ),
          const SizedBox(height: AppTokens.space4),
          Row(
            children: [
              _SegmentToggle(segment: segment, onSegment: onSegment),
              const Spacer(),
              if (grid) const _GoogleEventsToggle(),
              const SizedBox(width: AppTokens.space8),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDesktop(BuildContext context) {
    final showMonthNav = segment == CalendarSegment.grid;

    // 헤더는 폭이 줄면 가로로 넘친다 — 제목을 0 으로 줄여도 버튼들만으로 넘치는
    // 구간이 실제로 있었다(사이드바까지 낀 좁은 창). 그래서 실측 폭을 보고 덜
    // 중요한 것부터 접는다. **패널 토글은 절대 접지 않는다** — 패널을 접어 둔
    // 상태에서 그 버튼까지 사라지면 되돌릴 방법이 없다.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final showArrows = width >= _arrowsMinWidth;
        final showGoogle = width >= _googleToggleMinWidth;

        // 좌우 여백도 좁은 창에서는 양보한다 — 버튼을 더 접는 것보다 여백을 줄이는
        // 쪽이 기능을 안 잃는다 (24+24 → 8+8 로 32px 확보).
        final tight = width < _arrowsMinWidth;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            tight ? AppTokens.space8 : AppTokens.space24,
            AppTokens.space20,
            tight ? AppTokens.space8 : AppTokens.space24,
            AppTokens.space8,
          ),
          child: Row(
            children: [
              if (showMonthNav) ...[
                Flexible(child: _title(context)),
                if (showArrows) ...[
                  const SizedBox(width: AppTokens.space4),
                  IconButton(
                    key: const ValueKey('calendar-prev-month'),
                    onPressed: onPrev,
                    icon: const Icon(Icons.chevron_left),
                    tooltip: '이전 달 (←)',
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('calendar-next-month'),
                    onPressed: onNext,
                    icon: const Icon(Icons.chevron_right),
                    tooltip: '다음 달 (→)',
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
                const SizedBox(width: AppTokens.space4),
                _todayButton(),
              ] else
                _title(context),
              const Spacer(),
              if (showMonthNav && showGoogle) ...[
                const _GoogleEventsToggle(),
                const SizedBox(width: AppTokens.space8),
              ],
              if (onTogglePanel != null && showMonthNav)
                IconButton(
                  key: const ValueKey('calendar-panel-toggle'),
                  onPressed: onTogglePanel,
                  icon: Icon(
                    panelCollapsed
                        ? Icons.view_sidebar_outlined
                        : Icons.view_sidebar,
                  ),
                  tooltip: panelCollapsed ? '목록 패널 펼치기' : '목록 패널 접기',
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              _SegmentToggle(segment: segment, onSegment: onSegment),
            ],
          ),
        );
      },
    );
  }
}

/// 모바일 캘린더 헤더의 ⋮ — 앱바를 없애며 잃은 검색·설정 통로.
class _MobileOverflowMenu extends StatelessWidget {
  const _MobileOverflowMenu();

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_HeaderMenuAction>(
      key: const ValueKey('calendar-overflow-menu'),
      icon: const Icon(Icons.more_vert, size: 20),
      tooltip: '더보기',
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onSelected: (action) {
        switch (action) {
          case _HeaderMenuAction.search:
            SearchScreen.show(context);
          case _HeaderMenuAction.settings:
            SettingsSheet.show(context);
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _HeaderMenuAction.search,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.search, size: 18),
            title: Text('검색'),
          ),
        ),
        PopupMenuItem(
          value: _HeaderMenuAction.settings,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.settings_outlined, size: 18),
            title: Text('설정'),
          ),
        ),
      ],
    );
  }
}

enum _HeaderMenuAction { search, settings }

/// 구글 캘린더 일정 표시 on/off — "Google" 이름표 칩.
///
/// 예전엔 아이콘 버튼이라 무엇을 켜고 끄는지 알 수 없었다. 연결돼 있을 때만 보인다 —
/// 연결 전엔 켤 수 있는 일정이 없다.
class _GoogleEventsToggle extends ConsumerWidget {
  const _GoogleEventsToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(googleCalendarConnectedProvider)) {
      return const SizedBox.shrink();
    }
    final on = ref.watch(showGoogleEventsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const color = GoogleEventEntry.eventColor;
    return Tooltip(
      message: on ? 'Google 일정 숨기기' : 'Google 일정 함께 보기',
      child: Semantics(
        toggled: on,
        button: true,
        child: InkWell(
          key: const ValueKey('calendar-google-toggle'),
          onTap: () => ref.read(showGoogleEventsProvider.notifier).toggle(),
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
          child: Container(
            constraints: const BoxConstraints(minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: AppTokens.space12),
            decoration: BoxDecoration(
              color: on ? color.withValues(alpha: 0.12) : null,
              border: Border.all(
                color: on
                    ? color.withValues(alpha: 0.6)
                    : scheme.outlineVariant,
                width: 1,
              ),
              borderRadius: BorderRadius.circular(AppTokens.radiusFull),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 상태 점 — 켜짐(색) / 꺼짐(빈 원).
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? color : null,
                    border: on
                        ? null
                        : Border.all(
                            color: scheme.onSurface.withValues(alpha: 0.4),
                          ),
                  ),
                ),
                const SizedBox(width: AppTokens.space8),
                Text(
                  'Google',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface.withValues(alpha: on ? 0.9 : 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SegmentToggle extends StatelessWidget {
  const _SegmentToggle({required this.segment, required this.onSegment});

  final CalendarSegment segment;
  final void Function(CalendarSegment) onSegment;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SegmentButton(
            valueKey: 'calendar-segment-grid',
            label: '달력',
            selected: segment == CalendarSegment.grid,
            onTap: () => onSegment(CalendarSegment.grid),
          ),
          _SegmentButton(
            valueKey: 'calendar-segment-list',
            label: '타임라인',
            selected: segment == CalendarSegment.list,
            onTap: () => onSegment(CalendarSegment.list),
          ),
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.valueKey,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String valueKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey(valueKey),
      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppTokens.motionFast,
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space12,
          vertical: AppTokens.space4,
        ),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.surface : null,
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            color: theme.colorScheme.onSurface.withValues(
              alpha: selected ? 1 : 0.6,
            ),
          ),
        ),
      ),
    );
  }
}

class _PrevMonthIntent extends Intent {
  const _PrevMonthIntent();
}

class _NextMonthIntent extends Intent {
  const _NextMonthIntent();
}

class _TodayIntent extends Intent {
  const _TodayIntent();
}
