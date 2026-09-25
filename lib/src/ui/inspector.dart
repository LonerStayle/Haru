import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../domain/todo.dart';
import '../features/outline/tree_providers.dart';
import '../features/todo_detail/todo_detail_screen.dart';

/// 데스크탑 인스펙터 — 메인 영역 오른쪽 패널에 할 일 상세를 띄운다 (UX 개선 Phase 3).
///
/// 예전엔 상세가 루트 Navigator 로 push 돼 사이드바까지 덮었다. 이제 데스크탑 셸 안에서
/// 항목을 누르면 목록은 그대로 두고 오른쪽에 상세가 열린다(메일 앱처럼). 하위 항목을
/// 누르면 패널 안에서 한 단계 들어가고 ← 로 돌아온다. Esc / × 로 닫는다.
///
/// 셸 밖(루트 Navigator 로 push 된 화면들)에는 이 scope 가 없으므로 [maybeOf] 가 null →
/// 호출자는 예전처럼 상세 화면을 push 한다. 폰은 셸이 scope 를 두지 않는다.
class InspectorScope extends InheritedWidget {
  const InspectorScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final InspectorController controller;

  static InspectorController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InspectorScope>()?.controller;

  @override
  bool updateShouldNotify(InspectorScope oldWidget) =>
      controller != oldWidget.controller;
}

/// 인스펙터 스택 — 맨 끝이 지금 보이는 항목.
class InspectorController extends ChangeNotifier {
  final List<Todo> _stack = [];

  List<Todo> get stack => List.unmodifiable(_stack);
  Todo? get current => _stack.isEmpty ? null : _stack.last;
  bool get isOpen => _stack.isNotEmpty;

  /// 목록에서 항목을 열기 — 스택을 그 항목 하나로 새로 시작.
  void open(Todo todo) {
    if (_stack.length == 1 && _stack.single.id == todo.id) return;
    _stack
      ..clear()
      ..add(todo);
    notifyListeners();
  }

  /// 패널 안에서 하위 항목으로 들어가기.
  void push(Todo todo) {
    _stack.add(todo);
    notifyListeners();
  }

  /// 한 단계 뒤로. 마지막이면 닫힌다.
  void pop() {
    if (_stack.isEmpty) return;
    _stack.removeLast();
    notifyListeners();
  }

  /// [id] 가 스택에 있으면 그 위치부터 걷어낸다 (지워진 항목).
  void removeFrom(String id) {
    final i = _stack.indexWhere((t) => t.id == id);
    if (i < 0) return;
    _stack.removeRange(i, _stack.length);
    notifyListeners();
  }

  void close() {
    if (_stack.isEmpty) return;
    _stack.clear();
    notifyListeners();
  }
}

/// 오른쪽 패널 본체 — 머리(← · 제목 · ⋮ · ×) + [TodoDetailView].
class InspectorPanel extends ConsumerWidget {
  const InspectorPanel({super.key, required this.controller});

  final InspectorController controller;

  /// 패널 폭 — 상세 카드와 하위 목록이 한 줄에 읽히는 최소 폭.
  static const double width = 440;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final top = controller.current;
    if (top == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final all = ref.watch(allTodosProvider).asData?.value;
    final live =
        all?.firstWhere((t) => t.id == top.id, orElse: () => top) ?? top;
    final canGoBack = controller.stack.length > 1;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): controller.close,
      },
      child: Material(
        key: const ValueKey('inspector-panel'),
        color: scheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  const SizedBox(width: AppTokens.space4),
                  if (canGoBack)
                    IconButton(
                      key: const ValueKey('inspector-back'),
                      tooltip: '상위 항목으로',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: controller.pop,
                    )
                  else
                    const SizedBox(width: AppTokens.space12),
                  Expanded(
                    child: Text(
                      canGoBack
                          ? controller.stack[controller.stack.length - 2].title
                          : '상세',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TodoDetailMenuButton(
                    todo: live,
                    onDeleted: () => controller.removeFrom(live.id),
                  ),
                  IconButton(
                    key: const ValueKey('inspector-close'),
                    tooltip: '닫기 (Esc)',
                    icon: const Icon(Icons.close),
                    onPressed: controller.close,
                  ),
                  const SizedBox(width: AppTokens.space4),
                ],
              ),
            ),
            Divider(height: AppTokens.hairline, color: scheme.outlineVariant),
            Expanded(
              child: TodoDetailView(
                // 항목이 바뀌면 화면 상태(칩·스크롤)를 새로.
                key: ValueKey('inspector-${top.id}'),
                parent: top,
                // 인스펙터는 목록 옆이라 지워지는 게 보인다(목록 삭제 되돌리기와
                // 겹치는 알림을 띄우지 않고 조용히 닫는다).
                suppressGoneNotice: true,
                onGone: () => controller.removeFrom(top.id),
                onOpenTodo: controller.push,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
