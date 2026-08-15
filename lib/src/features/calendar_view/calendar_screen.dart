import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../calendar/google_auth_service.dart';
import '../home/today_providers.dart';
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

/// 데스크탑 우측 선택일 패널의 폭.
const double _panelWidth = 340;

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
/// `[목록]` 세그먼트로 그대로 살렸다 — 자리 문제도 기능 손실도 없다.
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

  late DateTime _focusedMonth;
  late DateTime _selectedDay;
  CalendarSegment _segment = CalendarSegment.grid;

  /// 모바일에서 달력을 접어 목록을 넓게 보는 상태.
  bool _gridCollapsed = false;

  /// 데스크탑에서 우측 선택일 패널을 접은 상태.
  ///
  /// 접으면 격자가 그만큼 넓어진다 — 칸이 넓어야 기간 막대 제목이 잘리지 않는다.
  /// 모바일의 [_gridCollapsed] 와 같은 성격(세션 내에서만 유지)이라 영속 저장하지 않는다.
  bool _panelCollapsed = false;

  @override
  void initState() {
    super.initState();
    final today = dateOnly(ref.read(nowProvider)());
    _baseMonth = DateTime(today.year, today.month);
    _focusedMonth = _baseMonth;
    _selectedDay = today;
    _pager = PageController(initialPage: _basePage);
  }

  @override
  void dispose() {
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

  void _selectDay(DateTime date) {
    setState(() => _selectedDay = dateOnly(date));
    // 넘침 날짜를 탭했으면 그 달로 따라 이동한다 — 안 그러면 선택 표시가
    // 화면 밖 달에 가 있어 무슨 일이 일어났는지 알 수 없다.
    if (date.month != _focusedMonth.month || date.year != _focusedMonth.year) {
      _goToMonth(date);
    }
  }

  void _goToToday() {
    final today = dateOnly(ref.read(nowProvider)());
    setState(() => _selectedDay = today);
    _goToMonth(today);
  }

  /// 달력 칸에 항목을 떨어뜨렸을 때 — 날짜만 바꾸고 순서는 보존한다.
  ///
  /// 고스트(미래 반복 예정)는 옮길 row 자체가 없으므로 먼저 그 회차를 실체화한다.
  Future<void> _handleDrop(CalendarDragData data, DateTime date) async {
    final todo = switch (data) {
      UndatedDragData(:final todo) => todo,
      EntryDragData(:final entry) => await resolveEntryTodo(ref, entry),
    };
    if (todo == null) return;

    final moved = applyDateDrop(todo, date);
    // 같은 날에 떨어뜨렸으면 applyDateDrop 이 원본을 그대로 돌려준다 → 저장 생략.
    if (!identical(moved, todo)) {
      await ref.read(todoActionsProvider).setDueAt(moved);
    }
    if (!mounted) return;
    // 옮긴 결과를 바로 보여준다 — 어디로 갔는지 눈으로 확인시키는 게 핵심.
    setState(() => _selectedDay = dateOnly(date));
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

  @override
  Widget build(BuildContext context) {
    // 과거~오늘 반복 회차의 실체화 보장 — '오늘' 화면을 거치지 않고 캘린더로
    // 바로 들어와도 반복이 비어 보이지 않게 한다 (HomeScreen 과 같은 규약).
    ref.watch(recurrenceMaterializerProvider);

    final today = dateOnly(ref.watch(nowProvider)());
    final compact = AppPlatform.isMobile;

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
                gridCollapsed: _gridCollapsed,
                onPrev: () => _shiftMonth(-1),
                onNext: () => _shiftMonth(1),
                onToday: _goToToday,
                onSegment: (s) => setState(() => _segment = s),
                onToggleCollapse: compact
                    ? () => setState(() => _gridCollapsed = !_gridCollapsed)
                    : null,
                panelCollapsed: _panelCollapsed,
                // 우측 패널은 데스크탑에만 있다 — 모바일은 아래위 분할이라 대상이 없다.
                onTogglePanel: compact
                    ? null
                    : () => setState(() => _panelCollapsed = !_panelCollapsed),
              ),
              Expanded(
                child: _segment == CalendarSegment.list
                    ? const TimelineScreen(showHeader: false)
                    : compact
                    ? _buildMobileBody(today)
                    : _buildDesktopBody(today),
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

  Widget _buildDesktopBody(DateTime today) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildPager(today)),
        // 접으면 격자가 패널 폭만큼 넓어진다. 애니메이션 없이 즉시 전환하는 건
        // 모바일의 달력 접기와 같은 규약 — 폭이 크게 바뀌는 전환은 중간 프레임이
        // 오히려 어수선하다.
        if (!_panelCollapsed) ...[
          const VerticalDivider(width: 1, thickness: AppTokens.hairline),
          SizedBox(width: _panelWidth, child: _buildPanel()),
        ],
      ],
    );
  }

  Widget _buildMobileBody(DateTime today) {
    return Column(
      children: [
        // 접으면 목록이 화면 전체를 쓴다 — 좁은 폰에서 그날 할 일을 길게 볼 때.
        if (!_gridCollapsed) Expanded(flex: 6, child: _buildPager(today)),
        Expanded(flex: 5, child: _buildPanel()),
      ],
    );
  }

  Widget _buildPager(DateTime today) {
    return PageView.builder(
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
              onSelectDay: _selectDay,
              onLongPressDay: (date) {
                _selectDay(date);
                openAddTodoOnDate(context, ref, date);
              },
              dayCellBuilder: _dropTarget,
            ),
          ),
        );
      },
    );
  }

  Widget _buildPanel() => _DayPanelSection(selectedDay: _selectedDay);
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
    return Draggable<CalendarDragData>(
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
  const _DayPanelSection({required this.selectedDay});

  final DateTime selectedDay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = CalendarRange.forMonth(selectedDay);
    final buckets = ref.watch(calendarBucketsProvider(range));
    final entries =
        buckets.asData?.value[selectedDay] ?? const <CalendarEntry>[];
    return CalendarDayPanel(
      date: selectedDay,
      entries: entries,
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
  });

  final DateTime month;
  final DateTime today;
  final DateTime selectedDay;
  final void Function(DateTime) onSelectDay;
  final void Function(DateTime) onLongPressDay;
  final Widget Function(DateTime, CalendarDayCellBuilder) dayCellBuilder;

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
      dayCellBuilder: dayCellBuilder,
    );
  }
}

class _CalendarHeader extends StatelessWidget {
  const _CalendarHeader({
    required this.focusedMonth,
    required this.segment,
    required this.gridCollapsed,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.onSegment,
    this.onToggleCollapse,
    this.panelCollapsed = false,
    this.onTogglePanel,
  });

  final DateTime focusedMonth;
  final CalendarSegment segment;
  final bool gridCollapsed;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final void Function(CalendarSegment) onSegment;
  final VoidCallback? onToggleCollapse;

  /// 데스크탑 우측 선택일 패널이 접혀 있는가.
  final bool panelCollapsed;

  /// 우측 패널 접기/펼치기. null 이면 버튼 미표시 (모바일).
  final VoidCallback? onTogglePanel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = AppPlatform.isMobile;
    final showMonthNav = segment == CalendarSegment.grid;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? AppTokens.space8 : AppTokens.space24,
        compact ? AppTokens.space8 : AppTokens.space20,
        compact ? AppTokens.space8 : AppTokens.space24,
        AppTokens.space8,
      ),
      child: Row(
        children: [
          if (showMonthNav) ...[
            Flexible(
              child: Text(
                KoDate.monthTitle(focusedMonth),
                key: const ValueKey('calendar-month-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    (compact
                            ? theme.textTheme.titleLarge
                            : theme.textTheme.headlineSmall)
                        ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            // 모바일에는 ‹ › 를 두지 않는다. 폭이 40px 모자라 헤더가 넘치고,
            // 확정 요구상 모바일의 달 이동 수단은 좌우 스와이프다 (데스크탑은 키/버튼).
            if (!compact) ...[
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
            TextButton(
              key: const ValueKey('calendar-today-button'),
              onPressed: onToday,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.space8,
                ),
              ),
              child: const Text('오늘'),
            ),
          ] else
            Text(
              '타임라인',
              style:
                  (compact
                          ? theme.textTheme.titleLarge
                          : theme.textTheme.headlineSmall)
                      ?.copyWith(fontWeight: FontWeight.w800),
            ),
          const Spacer(),
          if (showMonthNav) const _GoogleEventsToggle(),
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
          if (onToggleCollapse != null && showMonthNav)
            IconButton(
              key: const ValueKey('calendar-collapse-toggle'),
              onPressed: onToggleCollapse,
              icon: Icon(gridCollapsed ? Icons.expand_more : Icons.expand_less),
              tooltip: gridCollapsed ? '달력 펼치기' : '달력 접기',
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          _SegmentToggle(segment: segment, onSegment: onSegment),
        ],
      ),
    );
  }
}

/// 구글 캘린더 이벤트 표시 on/off.
///
/// 연동이 구성돼 있지 않으면 버튼 자체를 숨긴다 — 눌러도 아무 일이 없는 버튼이
/// 헤더에 남아 있을 이유가 없다.
class _GoogleEventsToggle extends ConsumerWidget {
  const _GoogleEventsToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(googleCalendarAvailableProvider)) {
      return const SizedBox.shrink();
    }
    final on = ref.watch(showGoogleEventsProvider);
    return IconButton(
      key: const ValueKey('calendar-google-toggle'),
      onPressed: () => ref.read(showGoogleEventsProvider.notifier).toggle(),
      icon: Icon(on ? Icons.event_available : Icons.event_busy_outlined),
      color: on ? GoogleEventEntry.eventColor : null,
      tooltip: on ? 'Google 일정 숨기기' : 'Google 일정 표시',
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
            label: '목록',
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
