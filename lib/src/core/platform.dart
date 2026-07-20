import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Solo Todo 가 지원하는 두 폼팩터.
///
/// 비전상 macOS desktop + Android phone 만 지원하므로 둘 외 플랫폼이 와도
/// [mobile] 로 fallback (현재 환경에선 발생하지 않음).
enum FormFactor { desktop, mobile }

/// 런타임 플랫폼 분기 헬퍼.
///
/// 위젯 트리는 가급적 `if (AppPlatform.isDesktop)` 한 줄로만 분기하고,
/// 두 구현체를 각각 stateless 위젯으로 분리해 유지·관리한다.
class AppPlatform {
  const AppPlatform._();

  /// 테스트 전용 override — 실제 OS 대신 지정한 폼팩터로 판정하게 한다.
  ///
  /// [formFactor] 는 `Platform.isMacOS` (dart:io) 로 결정되므로 macOS 테스트
  /// 호스트에서는 항상 desktop 이 된다. 모바일 전용 위젯 흐름 (Drawer / 시스템
  /// 뒤로가기 등) 을 검증하려면 setUp 에서 이 값을 세팅하고 tearDown 에서 null 로
  /// 되돌린다.
  @visibleForTesting
  static FormFactor? debugFormFactorOverride;

  static FormFactor get formFactor =>
      debugFormFactorOverride ??
      (Platform.isMacOS ? FormFactor.desktop : FormFactor.mobile);

  static bool get isDesktop => formFactor == FormFactor.desktop;
  static bool get isMobile => formFactor == FormFactor.mobile;
}
