import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform.dart';
import '../../../core/theme.dart';
import '../../../domain/todo.dart';
import '../../outline/tree_providers.dart';
import '../widgets/ai_inline_error.dart';
import 'ai_ask.dart';

enum AiAskPhase { idle, waiting, streaming, done, failed }

/// 물어보기 한 화면 동안의 상태 — 질문 하나의 답 스트림을 들고 있다.
///
/// 새 질문([start])·모드 전환([reset])·[dispose] 에서 이전 스트림 구독을 반드시 취소한다
/// (플랜 한도를 쓰는 호출이 화면 밖에서 계속 흐르지 않게).
class AiAskController extends ChangeNotifier {
  AiAskPhase _phase = AiAskPhase.idle;
  String _asked = '';
  String _raw = '';
  Map<int, String> _nToId = const {};
  AiAskAnswer _answer = AiAskAnswer.empty;
  int _selected = -1;
  StreamSubscription<String>? _sub;

  AiAskPhase get phase => _phase;

  /// 마지막으로 보낸 질문.
  String get asked => _asked;

  /// 보낸 할 일 수.
  int get sentCount => _nToId.length;

  AiAskAnswer get answer => _answer;

  /// ↑↓ 로 고른 인용 칩 (없으면 -1).
  int get selected => _selected;

  AiAskCitation? get selectedCitation =>
      _selected >= 0 && _selected < _answer.citations.length
      ? _answer.citations[_selected]
      : null;

  bool get isActive => _phase != AiAskPhase.idle;

  /// 질문 하나를 시작한다. [request] 가 null 이면(창구 없음·목록 미로딩) 곧바로 실패.
  void start(String question, AiAskRequest? request) {
    _cancel();
    _asked = question;
    _raw = '';
    _answer = AiAskAnswer.empty;
    _selected = -1;
    if (request == null) {
      _nToId = const {};
      _phase = AiAskPhase.failed;
      notifyListeners();
      return;
    }
    _nToId = request.nToId;
    _phase = AiAskPhase.waiting;
    _sub = request.stream.listen(
      _onChunk,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
    notifyListeners();
  }

  void _onChunk(String chunk) {
    _raw += chunk;
    _answer = parseCitations(_raw, _nToId);
    _phase = AiAskPhase.streaming;
    notifyListeners();
  }

  void _onError(Object _) {
    // 내용은 로그에 남기지 않는다(질문·할 일 제목이 담겨 있다).
    _sub = null;
    _phase = AiAskPhase.failed;
    notifyListeners();
  }

  void _onDone() {
    _sub = null;
    _answer = parseCitations(_raw, _nToId);
    _phase = _answer.text.isEmpty ? AiAskPhase.failed : AiAskPhase.done;
    notifyListeners();
  }

  void moveSelection(int delta) {
    final count = _answer.citations.length;
    if (count == 0) return;
    _selected = _selected < 0
        ? (delta > 0 ? 0 : count - 1)
        : (_selected + delta).clamp(0, count - 1);
    notifyListeners();
  }

  void clearSelection() {
    if (_selected < 0) return;
    _selected = -1;
    notifyListeners();
  }

  /// 물어보기 모드를 벗어났다 — 흐르던 답을 멈추고 처음 상태로.
  void reset() {
    _cancel();
    if (_phase == AiAskPhase.idle && _asked.isEmpty) return;
    _phase = AiAskPhase.idle;
    _asked = '';
    _raw = '';
    _nToId = const {};
    _answer = AiAskAnswer.empty;
    _selected = -1;
    notifyListeners();
  }

  void _cancel() {
    _sub?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }
}

/// ⌘K 오버레이·폰 검색 화면의 물어보기 본문 — 답 + 인용 칩.
///
/// **쓰기 경로 없음**: 저장소·todoActions 를 읽지도 부르지도 않는다. 칩은 그 할 일을
/// 여는 것([onOpen])까지만 한다.
class AiAskPanel extends ConsumerWidget {
  const AiAskPanel({super.key, required this.controller, required this.onOpen});

  final AiAskController controller;

  /// 인용 칩 — 오버레이는 그 위치(카테고리 + 인스펙터), 폰은 상세.
  final void Function(Todo todo) onOpen;

  /// 인용된 할 일을 연다. 그사이 지워졌으면 안내만.
  static void openCitation(
    BuildContext context,
    WidgetRef ref,
    String todoId,
    void Function(Todo todo) onOpen,
  ) {
    // .value — 이전 값을 든 loading 에서도 목록을 본다(asData 는 null).
    final todo = ref
        .read(allTodosProvider)
        .value
        ?.where((t) => t.id == todoId)
        .firstOrNull;
    if (todo == null) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('지워진 항목이에요')));
      return;
    }
    onOpen(todo);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SingleChildScrollView(
        key: const ValueKey('ai-ask-panel'),
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space16,
          AppTokens.space12,
          AppTokens.space16,
          AppTokens.space16,
        ),
        child: controller.phase == AiAskPhase.idle
            ? const _Idle()
            : _Answer(controller: controller, onOpen: onOpen),
      ),
    );
  }
}

class _Idle extends StatelessWidget {
  const _Idle();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Column(
      key: const ValueKey('ai-ask-idle'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.auto_awesome, size: 18, color: AppPalette.accent),
            const SizedBox(width: AppTokens.space8),
            Text(
              '할 일에 대해 물어보세요',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTokens.space8),
        Text(
          'Enter 로 보내면 AI 가 할 일 목록을 읽고 답해요. 읽기만 하고 아무것도 바꾸지 않아요.',
          style: theme.textTheme.bodyMedium?.copyWith(color: faint),
        ),
        const SizedBox(height: AppTokens.space4),
        Text(
          '예: 이번 주 마감인 일은? · 진행중인 일 정리해줘 · 결제 관련 할 일 뭐 있지?',
          style: theme.textTheme.bodySmall?.copyWith(color: faint),
        ),
      ],
    );
  }
}

class _Answer extends ConsumerWidget {
  const _Answer({required this.controller, required this.onOpen});

  final AiAskController controller;
  final void Function(Todo todo) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final faint = scheme.onSurface.withValues(alpha: 0.6);
    final phase = controller.phase;
    final answer = controller.answer;
    final titles = {
      for (final t in ref.watch(allTodosProvider).value ?? const <Todo>[])
        t.id: t.title,
    };
    final mobile = AppPlatform.isMobile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          controller.asked,
          key: const ValueKey('ai-ask-question'),
          style: theme.textTheme.labelLarge?.copyWith(
            color: faint,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppTokens.space8),
        if (phase == AiAskPhase.waiting)
          Row(
            key: const ValueKey('ai-ask-loading'),
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppTokens.space8),
              Text(
                '할 일 ${controller.sentCount}개를 읽는 중…',
                style: theme.textTheme.bodyMedium?.copyWith(color: faint),
              ),
            ],
          ),
        if (answer.text.isNotEmpty)
          Text(
            answer.text,
            key: const ValueKey('ai-ask-answer'),
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
        if (phase == AiAskPhase.streaming)
          const Padding(
            key: ValueKey('ai-ask-streaming'),
            padding: EdgeInsets.only(top: AppTokens.space8),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (phase == AiAskPhase.failed) const AiInlineError(),
        if (answer.citations.isNotEmpty) ...[
          const SizedBox(height: AppTokens.space12),
          Wrap(
            spacing: AppTokens.space8,
            runSpacing: AppTokens.space8,
            children: [
              for (final (i, c) in answer.citations.indexed)
                _CitationChip(
                  key: ValueKey('ai-ask-cite-${c.todoId}'),
                  index: c.index,
                  title: titles[c.todoId],
                  selected: i == controller.selected,
                  mobile: mobile,
                  onTap: () =>
                      AiAskPanel.openCitation(context, ref, c.todoId, onOpen),
                ),
            ],
          ),
        ],
        if (phase == AiAskPhase.done || phase == AiAskPhase.streaming) ...[
          const SizedBox(height: AppTokens.space12),
          Text(
            'AI 는 읽기만 해요 · 할 일 ${controller.sentCount}개를 보고 답했어요',
            key: const ValueKey('ai-ask-footnote'),
            style: theme.textTheme.labelSmall?.copyWith(color: faint),
          ),
        ],
      ],
    );
  }
}

class _CitationChip extends StatelessWidget {
  const _CitationChip({
    super.key,
    required this.index,
    required this.title,
    required this.selected,
    required this.mobile,
    required this.onTap,
  });

  final int index;

  /// null = 그사이 지워진 항목.
  final String? title;
  final bool selected;
  final bool mobile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final gone = title == null;
    return ActionChip(
      onPressed: onTap,
      materialTapTargetSize: mobile
          ? MaterialTapTargetSize.padded
          : MaterialTapTargetSize.shrinkWrap,
      backgroundColor: selected
          ? AppPalette.accent.withValues(alpha: 0.10)
          : null,
      side: BorderSide(
        color: selected ? AppPalette.accent : scheme.outlineVariant,
        width: selected ? 2 : 1,
      ),
      avatar: CircleAvatar(
        radius: 10,
        backgroundColor: AppPalette.accent.withValues(alpha: 0.14),
        child: Text(
          '$index',
          style: theme.textTheme.labelSmall?.copyWith(
            color: AppPalette.accent,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      label: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: mobile ? 220 : 280),
        child: Text(
          title ?? '지워진 항목',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: gone
              ? TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.45),
                  decoration: TextDecoration.lineThrough,
                )
              : null,
        ),
      ),
    );
  }
}
