# Solo Todo — 자주 쓰는 명령 모음
#
# 사용법: `make <target>` 또는 그냥 `make` (= help).
# .env.local 이 있을 때만 --dart-define-from-file 자동 주입 (없으면 local-only 모드).

ENV_FILE := .env.local
DART_DEFINE := $(if $(wildcard $(ENV_FILE)),--dart-define-from-file=$(ENV_FILE),)

# ────────────────────────────────────────────────────────────────────────────
# Help (default)
# ────────────────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "Solo Todo — Makefile"
	@echo ""
	@echo "  make setup        deps 받기 + (macOS) pod install"
	@echo "  make codegen      freezed / json / drift codegen"
	@echo ""
	@echo "  make run          macOS 데스크탑 실행 (env 자동)"
	@echo "  make emulator     Android 에뮬레이터 부팅 (첫 AVD 자동 선택)"
	@echo "  make run-android  Android 첫 device 자동 선택 실행 (에뮬레이터/실기기)"
	@echo ""
	@echo "  make build-macos  release .app 산출 (build/macos/.../haru.app)"
	@echo "  make build-apk    release .apk 산출 (build/app/outputs/flutter-apk/)"
	@echo ""
	@echo "  make test         flutter test (전체)"
	@echo "  make check        analyze + format check + test"
	@echo "  make format       dart format ."
	@echo "  make analyze      dart analyze"
	@echo ""
	@echo "  make clean        flutter clean + pub get"
	@echo ""
	@echo "  make sql          supabase/schema.sql 클립보드 복사 (Supabase SQL Editor 붙여넣기용)"
	@echo "  make sql-migrate  supabase/migrate.sql 클립보드 복사"
	@echo ""
	@echo "  현재 env 파일: $(if $(wildcard $(ENV_FILE)),found ✓,없음 — local-only 모드)"

.PHONY: sql sql-migrate
sql:
	@pbcopy < supabase/schema.sql && echo "✓ supabase/schema.sql 클립보드 복사됨 — Supabase SQL Editor 에 붙여넣기"

sql-migrate:
	@pbcopy < supabase/migrate.sql && echo "✓ supabase/migrate.sql 클립보드 복사됨"

# ────────────────────────────────────────────────────────────────────────────
# Setup / Codegen
# ────────────────────────────────────────────────────────────────────────────
.PHONY: setup
setup:
	flutter pub get
	@if [ "$(shell uname)" = "Darwin" ] && [ -d macos ]; then \
		echo "→ pod install --project-directory=macos"; \
		pod install --project-directory=macos || echo "⚠️  CocoaPods 미설치. sudo gem install cocoapods 후 재시도"; \
	fi

.PHONY: codegen
codegen:
	dart run build_runner build

.PHONY: codegen-watch
codegen-watch:
	dart run build_runner watch --delete-conflicting-outputs

# ────────────────────────────────────────────────────────────────────────────
# Run
# ────────────────────────────────────────────────────────────────────────────
.PHONY: run
run:
	flutter run -d macos $(DART_DEFINE)

.PHONY: emulator
emulator:
	@AVD=$$(flutter emulators 2>/dev/null | awk -F'•' '/android/{gsub(/ /,"",$$1); print $$1; exit}'); \
	if [ -z "$$AVD" ]; then \
		echo "❌ Android 에뮬레이터 없음. 'flutter emulators --create' 로 생성"; \
		exit 1; \
	fi; \
	echo "→ 부팅: $$AVD (홈 화면 뜨면 'make run-android')"; \
	flutter emulators --launch $$AVD

.PHONY: run-android
run-android:
	@DEV=$$(flutter devices --machine 2>/dev/null | awk -F'"' '/"id":/{id=$$4} /targetPlatform/ && /android/{print id; exit}'); \
	if [ -z "$$DEV" ]; then \
		echo "❌ 연결된 Android 기기 없음. 'make emulator' 로 에뮬레이터를 먼저 켜세요"; \
		exit 1; \
	fi; \
	echo "→ device: $$DEV"; \
	flutter run -d $$DEV $(DART_DEFINE)

# ────────────────────────────────────────────────────────────────────────────
# Build (release)
# ────────────────────────────────────────────────────────────────────────────
# --no-tree-shake-icons: 카테고리 아이콘을 codepoint 로 동적 생성 (사용자 선택) 하므로
# non-const IconData 가 필수 → tree-shaking 비활성. 폰트 전체 번들 (APK 약간 커짐).
.PHONY: build-macos
build-macos:
	flutter build macos --release --no-tree-shake-icons $(DART_DEFINE)
	@echo "✓ build/macos/Build/Products/Release/haru.app"

.PHONY: build-apk
build-apk:
	flutter build apk --release --no-tree-shake-icons $(DART_DEFINE)
	@echo "✓ build/app/outputs/flutter-apk/app-release.apk"

# ────────────────────────────────────────────────────────────────────────────
# Quality gates
# ────────────────────────────────────────────────────────────────────────────
.PHONY: analyze
analyze:
	dart analyze

.PHONY: format
format:
	dart format .

.PHONY: format-check
format-check:
	dart format --output=none --set-exit-if-changed .

.PHONY: test
test:
	flutter test

.PHONY: check
check: analyze format-check test
	@echo "✓ analyze + format + test 모두 PASS"

# ────────────────────────────────────────────────────────────────────────────
# Housekeeping
# ────────────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	flutter clean
	flutter pub get
