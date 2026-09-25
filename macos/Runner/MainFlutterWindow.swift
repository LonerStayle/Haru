import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 창 제목 = 앱 표시 이름 (Info.plist CFBundleName 과 일치).
    self.title = "하루"

    // 로그인 시 자동 실행 토글 — Dart 설정 시트의 MethodChannel 백엔드.
    // SMAppService.mainApp (macOS 13+) 사용. 샌드박스 앱에서 별도 entitlement 불필요.
    // register/unregister 는 정식 .app 번들(서명됨, /Applications 권장)에서만 안정적.
    let launchChannel = FlutterMethodChannel(
      name: "app.haru/launch_at_login",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    launchChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "isEnabled":
        if #available(macOS 13.0, *) {
          result(SMAppService.mainApp.status == .enabled)
        } else {
          // 13 미만은 미지원 — 토글을 끈 상태로 노출.
          result(false)
        }

      case "setEnabled":
        guard #available(macOS 13.0, *) else {
          result(FlutterError(
            code: "unsupported",
            message: "자동 실행은 macOS 13 이상에서만 지원돼요.",
            details: nil))
          return
        }
        let args = call.arguments as? [String: Any]
        let enabled = (args?["enabled"] as? Bool) ?? false
        do {
          if enabled {
            if SMAppService.mainApp.status != .enabled {
              try SMAppService.mainApp.register()
            }
          } else {
            if SMAppService.mainApp.status == .enabled {
              try SMAppService.mainApp.unregister()
            }
          }
          // 실제 반영된 상태를 돌려줘 UI 가 진실을 표시하게 한다.
          result(SMAppService.mainApp.status == .enabled)
        } catch {
          result(FlutterError(
            code: "launch_at_login_error",
            message: error.localizedDescription,
            details: nil))
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // 메인 창 앞으로 — Dart WindowService 백엔드. 트레이 "하루 열기"·전역 ⌘⇧N 이
    // 쓴다. 창이 다른 앱 뒤에 있거나 최소화돼 있으면 시트를 띄워도 안 보였다.
    let windowChannel = FlutterMethodChannel(
      name: "app.haru/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowChannel.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "show":
        guard let window = self else {
          result(nil)
          return
        }
        if window.isMiniaturized {
          window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
