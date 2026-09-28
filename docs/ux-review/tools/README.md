# 화면 렌더링 캡처 방법 (UX 리뷰용)

터미널에 화면 기록 권한이 없어 실행 중인 앱은 `screencapture` 로 못 찍는다.
대신 위젯 테스트로 실제 폰트를 실어 각 화면을 PNG 로 뽑는다.

1. `ux_snapshot_test.dart` 를 `test/_ux_snapshot_test.dart` 로 복사 (커밋 금지)
2. `flutter test test/_ux_snapshot_test.dart --plain-name "desktop light"` (모바일은 "mobile light")
3. 결과 PNG 는 `UX_SHOTS_OUT` 환경변수 경로(기본 /tmp/haru_ux_shots)에 생성. 캡처 후 test 쪽 복사본 삭제.

핵심: `AppDatabase.memory()` 시드 + `tester.runAsync` + `RepaintBoundary.toImage`,
폰트는 `/System/Library/Fonts/Supplemental/AppleGothic.ttf` 를 'Roboto' 등 family 로 로드,
아이콘은 flutter SDK 의 `MaterialIcons-Regular.otf` 를 'MaterialIcons' 로 로드.
