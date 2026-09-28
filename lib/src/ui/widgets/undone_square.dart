import 'package:flutter/material.dart';

/// 미완료 표식 — 모서리가 둥근 네모.
///
/// 3-상태 기호 세트(□ 미완료 / △ 진행중 / ◯ 완료)의 첫 칸. [InProgressTriangle] 과
/// 같은 규칙으로 그린다 — [active] 면 카테고리색으로 **채운** 네모, 아니면 옅은(0.55)
/// **외곽선** 네모. 세모·원과 굵기·여백을 맞춰 세 기호가 한 줄에서 같은 크기로 읽힌다.
///
/// 자체는 그림만 그린다. 탭 동작은 호출자가 [InkWell] 등으로 감싼다.
class UndoneSquare extends StatelessWidget {
  const UndoneSquare({
    super.key,
    required this.active,
    required this.color,
    this.size = 18,
  });

  /// 미완료 상태면 true → 채운 네모. false → 외곽선 네모.
  final bool active;

  /// 카테고리색. 완료 체크 원·진행중 세모와 같은 색으로 통일감을 준다.
  final Color color;

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SquarePainter(
          color: active ? color : color.withValues(alpha: 0.55),
          filled: active,
        ),
      ),
    );
  }
}

class _SquarePainter extends CustomPainter {
  _SquarePainter({required this.color, required this.filled});

  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    // 세모(0.1~0.9 여백)와 같은 비율로 안쪽에 그려 두 기호의 시각 크기를 맞춘다.
    final w = size.width;
    final h = size.height;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * 0.13, h * 0.13, w * 0.87, h * 0.87),
      Radius.circular(w * 0.18),
    );

    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    if (filled) {
      paint.style = PaintingStyle.fill;
    } else {
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 2;
    }
    canvas.drawRRect(rect, paint);
  }

  @override
  bool shouldRepaint(_SquarePainter old) =>
      old.color != color || old.filled != filled;
}
