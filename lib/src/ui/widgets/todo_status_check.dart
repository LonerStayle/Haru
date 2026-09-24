import 'package:flutter/material.dart';

import '../../domain/todo.dart';

/// 할 일 한 줄의 **체크 하나** — 3-상태를 모양 하나로 보여 준다 (UX Phase 1).
///
/// - ○ 미완료: 카테고리색 옅은 테두리 (0.55)
/// - ◐ 진행중: 테두리 + 왼쪽 반 채움
/// - ● 완료: 카테고리색으로 꽉 찬 원 + 체크
///
/// 예전엔 세모(진행중) + 원(완료) 두 버튼이 나란히 있어 "무엇을 눌러야 끝나는지"
/// 매번 읽어야 했다. 이제 누르는 곳은 이 원 하나(= 완료 토글)이고, 진행중 전환은
/// 데스크탑 hover 버튼·우클릭 / 폰 길게 누르기 메뉴로 옮겼다.
///
/// 그림만 그린다. 탭은 호출자가 [IconButton] 등으로 감싼다.
class TodoStatusCheck extends StatelessWidget {
  const TodoStatusCheck({
    super.key,
    required this.status,
    required this.color,
    this.size = 24,
  });

  final TodoStatus status;

  /// 카테고리색.
  final Color color;

  final double size;

  @override
  Widget build(BuildContext context) {
    // ○ / ● 는 Material 아이콘 그대로 — 다른 화면(캘린더·검색)과 모양이 같다.
    return switch (status) {
      TodoStatus.undone => Icon(
        Icons.radio_button_unchecked,
        size: size,
        color: color.withValues(alpha: 0.55),
      ),
      TodoStatus.done => Icon(
        Icons.check_circle_rounded,
        size: size,
        color: color,
      ),
      TodoStatus.inProgress => SizedBox(
        key: const ValueKey('todo-status-check-half'),
        width: size,
        height: size,
        child: CustomPaint(painter: _HalfCirclePainter(color: color)),
      ),
    };
  }
}

/// ◐ — radio_button_unchecked 와 같은 외곽 크기(아이콘 박스의 약 83%)로 그린다.
class _HalfCirclePainter extends CustomPainter {
  _HalfCirclePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    // Material 아이콘의 원은 24 박스에서 반지름 10 (2px 여백).
    final radius = size.shortestSide * 10 / 24;
    final stroke = size.shortestSide * 2 / 24;
    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..isAntiAlias = true;
    canvas.drawCircle(center, radius - stroke / 2, ring);
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    // 왼쪽 반원 채움 — "절반쯤 했다".
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - stroke / 2),
      // 위(-90°)에서 반시계로 180° → 왼쪽 반.
      -1.5707963267948966,
      -3.141592653589793,
      true,
      fill,
    );
  }

  @override
  bool shouldRepaint(_HalfCirclePainter old) => old.color != color;
}
