import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 마우스 드래그 시작 임계 (logical px).
///
/// Flutter 기본값은 마우스(맥 트랙패드 클릭 포함) 1px 이라, 클릭하는 동안 손이 살짝만
/// 흔들려도 드래그로 판정돼 클릭이 사라졌다 (대표님 제보 2026-09-25 "클릭 자체가 잘
/// 안 된다"). macOS 의 네이티브 드래그 시작 거리와 비슷한 수준으로 올린다.
const double kClickTolerantDragSlop = 6;

/// [Draggable] 과 같지만 드래그 시작 임계를 [kClickTolerantDragSlop] 이상으로 둔 버전.
///
/// 데스크탑의 "누르자마자 끄는" 드래그 소스(캘린더 패널 카드 등)에 쓴다. 안쪽의 탭·체크
/// 버튼 클릭이 1~5px 흔들림에 빼앗기지 않는다. 터치는 원래 임계(18px)가 더 크므로 그대로.
class ClickTolerantDraggable<T extends Object> extends Draggable<T> {
  const ClickTolerantDraggable({
    super.key,
    required super.child,
    required super.feedback,
    super.data,
    super.childWhenDragging,
    super.onDragStarted,
    super.onDragEnd,
    super.onDraggableCanceled,
    super.onDragCompleted,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) {
    return _TolerantImmediateMultiDragRecognizer(
      allowedButtonsFilter: allowedButtonsFilter,
    )..onStart = onStart;
  }
}

class _TolerantImmediateMultiDragRecognizer
    extends ImmediateMultiDragGestureRecognizer {
  _TolerantImmediateMultiDragRecognizer({super.allowedButtonsFilter});

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return _TolerantPointerState(event.position, event.kind, gestureSettings);
  }
}

class _TolerantPointerState extends MultiDragPointerState {
  _TolerantPointerState(
    super.initialPosition,
    super.kind,
    super.gestureSettings,
  );

  @override
  void checkForResolutionAfterMove() {
    final slop = math.max(
      computeHitSlop(kind, gestureSettings),
      kClickTolerantDragSlop,
    );
    if (pendingDelta!.distance > slop) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPosition);
  }
}
