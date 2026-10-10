import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/skeleton.dart';
import '../../ui/widgets/todo_tile.dart';
import '../add_todo/add_todo_controller.dart';
import '../ai/ai_providers.dart';
import '../ai/ai_readiness.dart';
import '../ai/ask/ai_ask.dart';
import '../ai/ask/ai_ask_panel.dart';
import '../category/categories_controller.dart';
import '../category/groups_controller.dart';
import '../move_todo/move_todo_sheet.dart';
import '../outline/tree_providers.dart';
import '../todo_actions/todo_actions_controller.dart';
import '../todo_actions/todo_row_actions.dart';
import '../todo_actions/toggle_with_undo.dart';
import 'recent_searches.dart';
import 'todo_search.dart';

/// 할 일·메모 전역 검색.
///
/// 카테고리/그룹/트리 깊이를 가리지 않고 제목과 메모 본문을 함께 훑는다. 결과는
/// 평탄한 한 겹 목록이라 항목마다 소속 경로(breadcrumb)를 붙여 위치를 잃지 않게 한다.
///
/// 데스크탑은 화면 위에 뜨는 **오버레이**(Spotlight 형 — 사이드바·목록을 덮지 않고
/// ↑↓ 로 고르고 ↩ 로 그 위치를 연다), 폰은 전체 화면 페이지.
///
/// AI 가 준비됐으면 **물어보기 모드**(T5, 읽기 전용)가 있다 — 오버레이는 `?` 로
/// 시작하면, 폰은 [검색 | 물어보기] 세그먼트(또는 `?`). Enter 를 눌러야만 보낸다.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({
    super.key,
    this.overlay = false,
    this.onReveal,
    this.onEdit,
  });

  /// 데스크탑 오버레이로 떠 있는가 (false = 폰 전체 화면 페이지).
  final bool overlay;

  /// 오버레이에서 결과를 열 때 — 셸이 "그 카테고리 화면 + 오른쪽 인스펙터" 로 보낸다.
  /// null 이면 상세를 연다.
  final void Function(Todo todo)? onReveal;

  /// 오버레이에서 ⌘↩ — 셸이 편집 시트를 연다. null 이면 이 자리에서 연다.
  final void Function(Todo todo)? onEdit;

  /// 어느 화면에서든 검색을 띄우는 단일 진입점 (사이드바 버튼 / 앱바 버튼 / ⌘K·⌘F).
  static Future<void> show(
    BuildContext context, {
    void Function(Todo todo)? onReveal,
    void Function(Todo todo)? onEdit,
  }) {
    if (AppPlatform.isDesktop) {
      return showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '검색 닫기',
        barrierColor: Colors.black.withValues(alpha: 0.18),
        transitionDuration: AppTokens.motionFast,
        pageBuilder: (_, _, _) =>
            SearchScreen(overlay: true, onReveal: onReveal, onEdit: onEdit),
        transitionBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      );
    }
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()));
  }

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _CloseSearchIntent extends Intent {
  const _CloseSearchIntent();
}

/// 카테고리 필터 "모든 카테고리" 센티널.
const String _allCategories = '__all__';

enum _SearchMode { search, ask }

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _fieldFocus = FocusNode();

  /// 검색어·필터는 이 화면에서만 쓰는 일시 상태라 로컬로 둔다 (닫으면 초기화).
  String _query = '';
  bool _includeDone = true;
  bool _notesOnly = false;
  String? _categoryId;

  /// ↑↓ 로 고른 결과 위치.
  int _selected = 0;
  final Map<String, GlobalKey> _rowKeys = {};

  /// 물어보기(T5) — 답 스트림을 든 상태. dispose 에서 구독을 취소한다.
  final AiAskController _ask = AiAskController();

  /// 물어보기 본문 자리 — 오버레이 안 스낵바 창구를 찾을 때 쓴다(이 State 의 context 는
  /// 오버레이의 ScaffoldMessenger 바깥이다).
  final GlobalKey _askPanelKey = GlobalKey();

  /// 폰 세그먼트에서 [물어보기] 를 골랐는가.
  bool _phoneAsk = false;

  /// 이번 build 가 물어보기 모드인가 (build 안 하위 위젯용).
  bool _asking = false;

  @override
  void dispose() {
    _ask.dispose();
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  /// 물어보기 모드 판정 — AI 가 준비됐을 때만. 아니면 `?` 도 평범한 검색어.
  bool _askMode(bool ready) =>
      ready && (_query.startsWith('?') || (!widget.overlay && _phoneAsk));

  bool _askModeNow() => _askMode(ref.read(aiReadinessProvider).isReady);

  /// 보낼 질문 — 앞의 `?` 를 뗀다.
  String get _question =>
      (_query.startsWith('?') ? _query.substring(1) : _query).trim();

  /// 물어보기 모드를 벗어났으면 흐르던 답을 멈춘다.
  void _syncAskMode() {
    if (!_askModeNow()) _ask.reset();
  }

  void _setQuery(String value) {
    setState(() {
      _query = value;
      _selected = 0;
    });
    _ask.clearSelection();
    _syncAskMode();
  }

  void _setPhoneMode(_SearchMode mode) {
    setState(() => _phoneAsk = mode == _SearchMode.ask);
    if (mode == _SearchMode.search && _query.startsWith('?')) {
      _fillQuery(_query.substring(1));
    } else {
      _syncAskMode();
      _fieldFocus.requestFocus();
    }
  }

  /// Enter — 질문을 보낸다. 같은 질문에서 ↑↓ 로 칩을 골라 뒀으면 그 할 일을 연다.
  Future<void> _submitAsk() async {
    final question = _question;
    if (question.isEmpty) return;
    final picked = _ask.selectedCitation;
    if (picked != null && question == _ask.asked) {
      _openCited(picked.todoId);
      return;
    }
    // '설명 보내기' 는 비동기 복원이다 — 복원 전 기본값(켬)으로 보내면 끈 설정이 무시된다.
    await ref.read(aiSendDescriptionProvider.notifier).restored;
    if (!mounted || !_askModeNow() || _question != question) return;
    final gateway = ref.read(aiGatewayProvider);
    final all = ref.read(allTodosProvider).value;
    _ask.start(
      question,
      gateway == null || all == null
          ? null
          : ref
                .read(aiAskServiceProvider)
                .ask(
                  gateway,
                  question: question,
                  all: all,
                  archivedCategoryIds: ref.read(archivedCategoryIdsProvider),
                  sendDescription: ref.read(aiSendDescriptionProvider),
                  now: ref.read(nowProvider)(),
                ),
    );
    // 폰은 키보드를 내려 답을 보이게 한다.
    if (!widget.overlay) _fieldFocus.unfocus();
  }

  /// 인용 칩 열기 — 질문은 최근 검색에 남기지 않는다.
  void _openCited(String todoId) => AiAskPanel.openCitation(
    _askPanelKey.currentContext ?? context,
    ref,
    todoId,
    (todo) => _open(todo, record: false),
  );

  void _fillQuery(String value) {
    _controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _setQuery(value);
    _fieldFocus.requestFocus();
  }

  /// 마지막 build 의 결과 — 결과 수 표시가 쓴다.
  List<TodoSearchHit> _lastHits = const [];

  /// 키 입력(↑↓·↩) 처리용 — 지금 검색어로 **새로** 계산한다. 붙여넣기·한글 조합
  /// 확정과 Enter 가 같은 프레임에 오면 지난 build 의 결과는 옛 검색어 것이다.
  List<TodoSearchHit> _hits() {
    final all = ref.read(allTodosProvider).asData?.value;
    return all == null ? const [] : _search(all, watch: false);
  }

  /// [watch] 는 build 안에서만 true (build 밖 watch 금지).
  List<TodoSearchHit> _search(List<Todo> all, {bool watch = true}) {
    final groups =
        (watch
                ? ref.watch(activeGroupsProvider)
                : ref.read(activeGroupsProvider))
            .asData
            ?.value ??
        const <Group>[];
    return searchTodos(
      all: all,
      query: _query,
      // 보관된 카테고리의 항목은 다른 화면과 마찬가지로 검색에서도 빠진다.
      excludedCategoryIds: watch
          ? ref.watch(archivedCategoryIdsProvider)
          : ref.read(archivedCategoryIdsProvider),
      includeDone: _includeDone,
      notesOnly: _notesOnly,
      categoryId: _categoryId,
      groupLabels: {for (final g in groups) g.id: g.label},
    );
  }

  /// 결과 열기 — 폰은 상세 화면, 데스크탑 오버레이는 닫고 그 위치(카테고리 + 인스펙터).
  /// [record] false = 물어보기 인용 칩(질문은 최근 검색어가 아니다).
  Future<void> _open(Todo todo, {bool edit = false, bool record = true}) async {
    if (record) ref.read(recentSearchesProvider.notifier).record(_query);
    if (!widget.overlay) {
      if (edit) {
        await openTodoEdit(context, ref, todo);
      } else {
        await openTodoDetail(context, todo);
      }
      return;
    }
    final handler = edit ? widget.onEdit : widget.onReveal;
    if (handler == null) {
      // 셸 밖에서 띄웠다 — 오버레이 위에 연다.
      if (edit) {
        await openTodoEdit(context, ref, todo);
      } else {
        await openTodoDetail(context, todo);
      }
      return;
    }
    Navigator.of(context).pop();
    handler(todo);
  }

  void _moveSelection(int delta) {
    final hits = _hits();
    if (hits.isEmpty) return;
    setState(() => _selected = (_selected + delta).clamp(0, hits.length - 1));
    final key = _rowKeys[hits[_selected].todo.id];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: AppTokens.motionFast,
        alignmentPolicy: delta > 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    }
  }

  /// ↩ — 오버레이는 고른 결과를 연다. 폰 키보드의 "검색" 키는 검색어만 기록하고
  /// 키보드를 내린다(결과를 멋대로 열지 않는다).
  void _submit({bool edit = false}) {
    if (_askModeNow()) {
      _submitAsk();
      return;
    }
    final hits = _hits();
    if (hits.isNotEmpty) {
      ref.read(recentSearchesProvider.notifier).record(_query);
    }
    if (!widget.overlay || hits.isEmpty) {
      _fieldFocus.unfocus();
      return;
    }
    final i = _selected.clamp(0, hits.length - 1);
    _open(hits[i].todo, edit: edit || HardwareKeyboard.instance.isMetaPressed);
  }

  /// 입력칸의 ↑↓ — 커서 이동 대신 결과 고르기.
  KeyEventResult _onFieldKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_askModeNow()) return _onAskKey(event);
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveSelection(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveSelection(-1);
      return KeyEventResult.handled;
    }
    // ⌘↩ 는 여기서 직접 — 입력칸의 onSubmitted 를 거치지 않을 수 있다(macOS).
    // 그냥 ↩ 는 한글 조합 확정과 얽히지 않게 onSubmitted 에 맡긴다.
    if (widget.overlay &&
        event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        HardwareKeyboard.instance.isMetaPressed) {
      _submit(edit: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 물어보기 모드의 키 — ↑↓ 는 인용 칩 고르기, ⌘↩ 도 그냥 보내기.
  KeyEventResult _onAskKey(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _ask.moveSelection(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _ask.moveSelection(-1);
      return KeyEventResult.handled;
    }
    if (widget.overlay &&
        event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        HardwareKeyboard.instance.isMetaPressed) {
      _submitAsk();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final readiness = ref.watch(aiReadinessProvider);
    _asking = _askMode(readiness.isReady);
    // 설명 보내기 설정을 미리 복원해 둔다(Enter 때 기다리지 않게).
    if (readiness.isReady) ref.watch(aiSendDescriptionProvider);
    if (!_asking && _ask.isActive) {
      // 준비 상태가 바뀌어(로그아웃·한도) 모드에서 밀려났다 — 다음 프레임에 멈춘다
      // (build 중 notify 금지).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncAskMode();
      });
    }
    final todosAsync = ref.watch(allTodosProvider);
    final all = todosAsync.asData?.value;
    // 물어보기 모드면 `?…` 로 검색하지 않는다.
    _lastHits = _asking || all == null ? const [] : _search(all);
    final body = _asking
        ? AiAskPanel(
            key: _askPanelKey,
            controller: _ask,
            onOpen: (todo) => _open(todo, record: false),
          )
        : todosAsync.when(
            loading: () => const TodoListSkeleton(),
            error: (_, _) => const EmptyState(
              icon: Icons.error_outline,
              title: '검색할 수 없어요',
              subtitle: '항목을 불러오지 못했습니다. 잠시 뒤 다시 시도해주세요.',
            ),
            data: (_) => _body(_lastHits, aiReady: readiness.isReady),
          );

    return Shortcuts(
      // Esc 로 닫기 — 다른 시트/오버레이와 같은 관례. 기본 DismissIntent 를 쓰면
      // 입력칸에서 가장 가까운 Scaffold(오버레이 스낵바 자리)의 서랍 닫기 동작이 먼저
      // 잡아 아무 일도 안 일어났다(기기 E2E 에서 발견) — 검색 전용 의도로 보낸다.
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): _CloseSearchIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CloseSearchIntent: CallbackAction<_CloseSearchIntent>(
            onInvoke: (_) {
              Navigator.of(context).maybePop();
              return null;
            },
          ),
        },
        child: widget.overlay
            // 오버레이 안에서 체크·삭제하면 되돌리기 스낵바가 배리어 **아래**(뒤 화면)에
            // 떠서 누를 수 없었다 — 오버레이 자신의 스낵바 자리를 둔다.
            ? ScaffoldMessenger(
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: _overlay(context, body),
                ),
              )
            : _page(context, body),
      ),
    );
  }

  Widget _field(BuildContext context, {required bool overlay}) {
    final theme = Theme.of(context);
    return Focus(
      onKeyEvent: _onFieldKey,
      child: TextField(
        key: const ValueKey('search-field'),
        controller: _controller,
        focusNode: _fieldFocus,
        autofocus: true,
        textInputAction: _asking
            ? TextInputAction.send
            : TextInputAction.search,
        style: overlay
            ? theme.textTheme.titleLarge
            : theme.textTheme.titleMedium,
        decoration: InputDecoration(
          hintText: _asking ? '할 일에 대해 물어보기' : '제목·메모 내용 검색',
          border: InputBorder.none,
          prefixIcon: overlay
              ? Icon(_asking ? Icons.auto_awesome : Icons.search)
              : null,
        ),
        onChanged: _setQuery,
        // 오버레이에서 질문을 보낸 뒤에도 입력칸에 포커스를 둔다(이어 묻기·↑↓·Esc).
        onEditingComplete: _asking && overlay ? () {} : null,
        onSubmitted: (_) => _submit(),
      ),
    );
  }

  Widget _clearButton() => IconButton(
    key: const ValueKey('search-clear-button'),
    icon: const Icon(Icons.close),
    tooltip: '검색어 지우기',
    onPressed: () {
      _controller.clear();
      _setQuery('');
      _fieldFocus.requestFocus();
    },
  );

  Widget _page(BuildContext context, Widget body) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _field(context, overlay: false),
        actions: [if (_query.isNotEmpty) _clearButton()],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ref.watch(aiReadinessProvider).isReady) _modeBar(),
          ..._aiUnavailableLine(context),
          if (!_asking) _filterBar(context),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _overlay(BuildContext context, Widget body) {
    // 카드 바깥을 누르면 닫힌다 — 오버레이 스낵바 자리(Scaffold)가 배리어를 가리므로
    // 바깥 탭을 여기서 직접 받는다.
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('search-overlay-outside'),
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        _overlayCard(context, body),
      ],
    );
  }

  Widget _overlayCard(BuildContext context, Widget body) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(
            top: size.height < 600 ? AppTokens.space16 : 72,
            left: AppTokens.space24,
            right: AppTokens.space24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 640,
              maxHeight: size.height * 0.72,
            ),
            child: Material(
              key: const ValueKey('search-overlay'),
              elevation: 16,
              color: scheme.surface,
              borderRadius: BorderRadius.circular(AppTokens.radiusL),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppTokens.space8,
                      AppTokens.space4,
                      AppTokens.space8,
                      0,
                    ),
                    child: Row(
                      children: [
                        Expanded(child: _field(context, overlay: true)),
                        if (_query.isNotEmpty) _clearButton(),
                      ],
                    ),
                  ),
                  const Divider(height: 1, thickness: AppTokens.hairline),
                  ..._aiUnavailableLine(context),
                  if (!_asking) _filterBar(context),
                  Flexible(child: body),
                  const Divider(height: 1, thickness: AppTokens.hairline),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTokens.space16,
                      vertical: AppTokens.space8,
                    ),
                    child: Text(
                      _asking
                          ? 'Enter 물어보기 · ↑↓ 인용 고르기 · Esc 닫기'
                          : '↑↓ 고르기 · Enter 열기 · ⌘Enter 편집 · Esc 닫기',
                      key: const ValueKey('search-key-hints'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 폰 [검색 | 물어보기] — AI 가 준비됐을 때만.
  Widget _modeBar() {
    final mobile = AppPlatform.isMobile;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space12,
        AppTokens.space8,
        AppTokens.space12,
        0,
      ),
      child: SegmentedButton<_SearchMode>(
        key: const ValueKey('search-mode'),
        showSelectedIcon: false,
        style: mobile
            ? null
            : const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
        segments: const [
          ButtonSegment(
            value: _SearchMode.search,
            icon: Icon(Icons.search, size: 18),
            label: Text('검색'),
          ),
          ButtonSegment(
            value: _SearchMode.ask,
            icon: Icon(Icons.auto_awesome, size: 18),
            label: Text('물어보기'),
          ),
        ],
        selected: {_asking ? _SearchMode.ask : _SearchMode.search},
        onSelectionChanged: (s) => _setPhoneMode(s.first),
      ),
    );
  }

  /// AI 가 준비되지 않았는데 `?` 로 시작했다 — 평범한 검색으로 찾되 이유를 한 줄.
  List<Widget> _aiUnavailableLine(BuildContext context) {
    final readiness = ref.watch(aiReadinessProvider);
    if (readiness.isReady || !_query.startsWith('?')) return const [];
    final theme = Theme.of(context);
    final faint = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final text = switch (readiness.state) {
      AiReadyState.off => 'AI 가 꺼져 있어 일반 검색으로 찾아요 · 설정 > AI 에서 켜면 물어볼 수 있어요',
      AiReadyState.loading => 'AI 연결을 확인하는 중이라 일반 검색으로 찾아요',
      _ => '${readiness.failureHint} · 지금은 일반 검색으로 찾아요',
    };
    return [
      Padding(
        key: const ValueKey('ai-ask-unavailable'),
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space16,
          AppTokens.space8,
          AppTokens.space16,
          0,
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 14, color: faint),
            const SizedBox(width: AppTokens.space8),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(color: faint),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _filterBar(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final categories =
        ref.watch(activeCategoriesProvider).asData?.value ?? const <Category>[];
    final selectedCategory = _categoryId == null
        ? null
        : categories.where((c) => c.id == _categoryId).firstOrNull;
    final loaded = ref.watch(allTodosProvider).hasValue;
    final count = _query.trim().isEmpty || !loaded ? null : _lastHits.length;
    final mobile = AppPlatform.isMobile;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space12,
        AppTokens.space8,
        AppTokens.space12,
        AppTokens.space4,
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  FilterChip(
                    key: const ValueKey('search-filter-done'),
                    label: const Text('완료 포함'),
                    selected: _includeDone,
                    showCheckmark: true,
                    materialTapTargetSize: mobile
                        ? MaterialTapTargetSize.padded
                        : MaterialTapTargetSize.shrinkWrap,
                    onSelected: (v) => setState(() {
                      _includeDone = v;
                      _selected = 0;
                    }),
                  ),
                  const SizedBox(width: AppTokens.space8),
                  FilterChip(
                    key: const ValueKey('search-filter-notes'),
                    label: const Text('메모만'),
                    selected: _notesOnly,
                    showCheckmark: true,
                    materialTapTargetSize: mobile
                        ? MaterialTapTargetSize.padded
                        : MaterialTapTargetSize.shrinkWrap,
                    onSelected: (v) => setState(() {
                      _notesOnly = v;
                      _selected = 0;
                    }),
                  ),
                  const SizedBox(width: AppTokens.space8),
                  // 값 null 인 항목을 고르면 Flutter 는 onSelected 대신 onCanceled 를
                  // 부른다 — "모든 카테고리" 는 센티널 값으로 둔다.
                  PopupMenuButton<String>(
                    key: const ValueKey('search-filter-category'),
                    tooltip: '카테고리로 좁히기',
                    initialValue: _categoryId ?? _allCategories,
                    onSelected: (id) => setState(() {
                      _categoryId = id == _allCategories ? null : id;
                      _selected = 0;
                    }),
                    itemBuilder: (context) => [
                      const PopupMenuItem<String>(
                        key: ValueKey('search-filter-category-all'),
                        value: _allCategories,
                        child: Text('모든 카테고리'),
                      ),
                      for (final c in categories)
                        PopupMenuItem<String>(
                          value: c.id,
                          child: Row(
                            children: [
                              Icon(c.icon, size: 16, color: c.color),
                              const SizedBox(width: AppTokens.space8),
                              Text(c.label),
                            ],
                          ),
                        ),
                    ],
                    child: Chip(
                      avatar: selectedCategory == null
                          ? null
                          : Icon(
                              selectedCategory.icon,
                              size: 16,
                              color: selectedCategory.color,
                            ),
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(selectedCategory?.label ?? '모든 카테고리'),
                          const Icon(Icons.arrow_drop_down, size: 18),
                        ],
                      ),
                      materialTapTargetSize: mobile
                          ? MaterialTapTargetSize.padded
                          : MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: AppTokens.space8),
            Text(
              '$count건',
              key: const ValueKey('search-result-count'),
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body(List<TodoSearchHit> hits, {required bool aiReady}) {
    if (_query.trim().isEmpty) {
      final recent = ref.watch(recentSearchesProvider);
      if (recent.isEmpty) {
        final base = widget.overlay
            ? '할 일 제목과 메모 내용을 함께 검색합니다. ↑↓ 로 고르고 ↩ 로 엽니다.'
            : '할 일 제목과 메모 내용을 함께 검색합니다.';
        return EmptyState(
          key: const ValueKey('search-idle'),
          icon: Icons.search,
          title: '무엇을 찾을까요?',
          subtitle: aiReady ? '$base\n? 로 시작하면 AI 에게 물어봐요.' : base,
        );
      }
      return _RecentList(
        recent: recent,
        shrinkWrap: widget.overlay,
        onPick: _fillQuery,
        onRemove: (q) => ref.read(recentSearchesProvider.notifier).remove(q),
        onClear: () => ref.read(recentSearchesProvider.notifier).clear(),
      );
    }
    if (hits.isEmpty) {
      return EmptyState(
        key: const ValueKey('search-empty'),
        icon: Icons.search_off,
        title: '"${_query.trim()}" 결과 없음',
        subtitle: _includeDone && !_notesOnly && _categoryId == null
            ? '다른 단어로 찾아보세요. 보관된 카테고리는 검색되지 않습니다.'
            : '필터를 풀면 더 찾을 수 있어요.',
      );
    }

    final selected = _selected.clamp(0, hits.length - 1);
    return ListView.builder(
      shrinkWrap: widget.overlay,
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space12,
        AppTokens.space8,
        AppTokens.space12,
        AppTokens.space16,
      ),
      itemCount: hits.length,
      itemBuilder: (context, i) {
        final hit = hits[i];
        final todo = hit.todo;
        final isSelected = widget.overlay && i == selected;
        final rowKey = _rowKeys.putIfAbsent(todo.id, GlobalKey.new);
        return Padding(
          key: ValueKey('search-hit-${todo.id}'),
          padding: const EdgeInsets.only(bottom: AppTokens.space8),
          child: DecoratedBox(
            key: rowKey,
            // 키보드로 고른 줄 — 오버레이에서만.
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTokens.radiusM),
              border: Border.all(
                color: isSelected ? AppPalette.accent : Colors.transparent,
                width: 2,
              ),
              color: isSelected
                  ? AppPalette.accent.withValues(alpha: 0.06)
                  : null,
            ),
            child: TodoTile(
              todo: todo,
              breadcrumb: hit.breadcrumb,
              snippet: hit.snippet,
              highlight: _query,
              onToggle: () =>
                  toggleWithUndo(context, ref.read(todoActionsProvider), todo),
              // 메모는 체크 개념이 없어 진행중 토글도 두지 않는다.
              onToggleInProgress: todo.type == TodoType.note
                  ? null
                  : () => ref.read(todoActionsProvider).toggleInProgress(todo),
              onTap: () => _open(todo),
              onEditItem: () => _open(todo, edit: true),
              onMove: () => showMoveTodoSheet(context, ref, item: todo),
              onCopy: () => showCopyTodoSheet(context, ref, original: todo),
              onDelete: () => deleteTodoWithUndo(context, ref, todo),
            ),
          ),
        );
      },
    );
  }
}

/// 최근 검색어 — 검색어가 비었을 때 보인다. 누르면 그 검색어로 다시 찾는다.
class _RecentList extends StatelessWidget {
  const _RecentList({
    required this.recent,
    required this.shrinkWrap,
    required this.onPick,
    required this.onRemove,
    required this.onClear,
  });

  final List<String> recent;
  final bool shrinkWrap;
  final void Function(String) onPick;
  final void Function(String) onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    return ListView(
      key: const ValueKey('search-recent'),
      shrinkWrap: shrinkWrap,
      padding: const EdgeInsets.symmetric(vertical: AppTokens.space8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space16,
            0,
            AppTokens.space8,
            0,
          ),
          child: Row(
            children: [
              Text(
                '최근 검색',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: faint,
                ),
              ),
              const Spacer(),
              TextButton(
                key: const ValueKey('search-recent-clear'),
                onPressed: onClear,
                child: const Text('모두 지우기'),
              ),
            ],
          ),
        ),
        for (final q in recent)
          ListTile(
            key: ValueKey('search-recent-$q'),
            dense: true,
            leading: Icon(Icons.history, size: 18, color: faint),
            title: Text(q),
            onTap: () => onPick(q),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: '이 검색어 지우기',
              onPressed: () => onRemove(q),
            ),
          ),
      ],
    );
  }
}
