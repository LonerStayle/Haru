import 'package:flutter/material.dart';

/// 진행중(in-progress) 표식 — 위를 향한 세모(삼각형).
///
/// [active] 면 카테고리색으로 **채운** 세모, 아니면 옅은(0.55) **외곽선** 세모.
/// 완료 체크(원)와 나란히 두어 "진행중" 상태를 한눈에 구분한다. (대표님 확정 — 세모 채움.)
///
/// 자체는 그림만 그린다. 탭 동작은 호출자가 [IconButton]/[InkWell] 로 감싼다.
class InProgressTriangle extends StatelessWidget {
  const InProgressTriangle({
    super.key,
    required this.active,
    required this.color,
    this.size = 18,
  });

  /// 진행중이면 true → 채운 세모. false → 외곽선 세모(진행 가능 힌트).
  final bool active;

  /// 카테고리색. 완료 체크 원과 같은 색 계열로 통일감을 준다.
  final Color color;

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _TrianglePainter(
          // 미진행도 완료 체크 ring(0.55) 과 동일 대비로 "진행 가능" 힌트.
          color: active ? color : color.withValues(alpha: 0.55),
          filled: active,
        ),
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  _TrianglePainter({required this.color, required this.filled});

  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    // 위를 향한 정삼각형(살짝 여백). 꼭짓점을 둥글게 하기 위해 strokeJoin.round.
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w / 2, h * 0.14)
      ..lineTo(w * 0.9, h * 0.86)
      ..lineTo(w * 0.1, h * 0.86)
      ..close();

    final paint = Paint()
      ..color = color
      ..isAntiAlias = true
      ..strokeJoin = StrokeJoin.round;
    if (filled) {
      paint.style = PaintingStyle.fill;
    } else {
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 2;
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) =>
      old.color != color || old.filled != filled;
}
