import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// 삭제/이동 같은 reversible action 후 호출. floating SnackBar + "되돌리기" 액션.
///
/// - 자동 dismiss 후에는 onUndo 호출되지 않음. 사용자가 액션 누르면 즉시 dismiss + onUndo 호출.
/// - 호출자는 이전 SnackBar 가 떠 있을 가능성을 고려해 [hideCurrentBeforeShow] 로 즉시 교체 가능.
/// - content 영역에 [duration] 과 같은 길이의 progress bar 가 표시되어 "남은 undo 시간"
///   을 시각적으로 알려준다 (1.0 → 0.0 감소).
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showUndoSnackbar(
  BuildContext context, {
  required String message,
  required VoidCallback onUndo,
  Duration duration = const Duration(seconds: 5),
  bool hideCurrentBeforeShow = true,
}) => showUndoSnackbarOn(
  ScaffoldMessenger.of(context),
  message: message,
  onUndo: onUndo,
  duration: duration,
  hideCurrentBeforeShow: hideCurrentBeforeShow,
)!;

/// 지금 떠 있는 되돌리기 스낵바의 동작 — ⌘Z 가 부른다 ([runLatestUndo]).
({
  VoidCallback onUndo,
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> controller,
})?
_latestUndo;

/// 되돌릴 게 떠 있는지 — ⌘Z 를 받을지 결정.
bool hasLatestUndo() => _latestUndo != null;

/// ⌘Z — 화면에 떠 있는 되돌리기 스낵바를 누른 것과 같다. 없으면 false.
bool runLatestUndo() {
  final latest = _latestUndo;
  if (latest == null) return false;
  _latestUndo = null;
  latest.controller.close();
  latest.onUndo();
  return true;
}

/// 화면에 떠 있는 "양보하지 않는"(삭제·이동) 되돌리기 스낵바 수 — 창구별.
final Expando<int> _firmVisible = Expando('undo-snackbar-firm');

/// [showUndoSnackbar] 의 messenger 버전 — 호출 context 가 곧 사라질 수 있을 때
/// (목록의 한 줄 등) 미리 잡아 둔 [messenger] 로 띄운다.
///
/// [yieldToOthers] 가 true 면 이미 떠 있는 삭제·이동 되돌리기를 밀어내지 않고
/// 아예 띄우지 않는다(null 반환). 체크 완료처럼 다른 길로도 되돌릴 수 있는 동작용.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showUndoSnackbarOn(
  ScaffoldMessengerState messenger, {
  required String message,
  required VoidCallback onUndo,
  Duration duration = const Duration(seconds: 5),
  bool hideCurrentBeforeShow = true,
  bool yieldToOthers = false,
}) {
  if (yieldToOthers && (_firmVisible[messenger] ?? 0) > 0) return null;
  if (hideCurrentBeforeShow) messenger.hideCurrentSnackBar();

  final controller = messenger.showSnackBar(
    SnackBar(
      content: _UndoContent(message: message, duration: duration),
      behavior: SnackBarBehavior.floating,
      duration: duration,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
      ),
      action: SnackBarAction(label: '되돌리기', onPressed: onUndo),
    ),
  );
  final entry = (onUndo: onUndo, controller: controller);
  _latestUndo = entry;
  controller.closed.whenComplete(() {
    if (identical(_latestUndo, entry)) _latestUndo = null;
  });
  if (!yieldToOthers) {
    _firmVisible[messenger] = (_firmVisible[messenger] ?? 0) + 1;
    controller.closed.whenComplete(() {
      final n = (_firmVisible[messenger] ?? 1) - 1;
      _firmVisible[messenger] = n < 0 ? 0 : n;
    });
  }
  return controller;
}

class _UndoContent extends StatelessWidget {
  const _UndoContent({required this.message, required this.duration});

  final String message;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(message),
        const SizedBox(height: AppTokens.space8),
        // SnackBar content 의 onSurfaceVariant 색 위에 시각 대비를 확보 — 진행 trace 는
        // 반투명, 진행 bar 자체는 onInverseSurface (SnackBar 의 텍스트 톤과 어울리는 색).
        ClipRRect(
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 1.0, end: 0.0),
            duration: duration,
            // 사용자가 직관적으로 "시간이 줄어든다" 를 느끼게 linear.
            curve: Curves.linear,
            builder: (_, value, _) => LinearProgressIndicator(
              key: const ValueKey('undo-snackbar-progress'),
              value: value,
              minHeight: 3,
              backgroundColor: theme.colorScheme.onInverseSurface.withValues(
                alpha: 0.22,
              ),
              color: theme.colorScheme.onInverseSurface,
            ),
          ),
        ),
      ],
    );
  }
}
