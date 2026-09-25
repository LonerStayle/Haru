import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/platform.dart';

/// macOS 메인 창 제어 — 트레이 "하루 열기"·전역 ⌘⇧N 이 창을 앞으로 가져온다.
///
/// 창이 다른 앱 뒤에 있거나 최소화돼 있으면, 시트를 띄워도 사용자 눈에 안 보였다.
/// 네이티브 채널(`app.haru/window`, MainFlutterWindow.swift) 하나로 해결한다 —
/// 창 관리 패키지를 새로 들이지 않는다.
class WindowService {
  const WindowService();

  static const MethodChannel _channel = MethodChannel('app.haru/window');

  /// 창을 보이게 하고 앞으로. 채널이 없는 환경(테스트·안드로이드)은 조용히 넘어간다.
  Future<void> showMainWindow() async {
    if (!AppPlatform.isDesktop) return;
    try {
      await _channel.invokeMethod<void>('show');
    } on MissingPluginException {
      // 테스트 환경 등 — 무시.
    } catch (e) {
      debugPrint('[haru] 창 앞으로 가져오기 실패: $e');
    }
  }
}
