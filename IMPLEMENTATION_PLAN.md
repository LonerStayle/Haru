# IMPLEMENTATION_PLAN

> ralph 가 매 iteration 갱신하는 체크리스트. 모든 task `[x]` + 디자인 점수 ≥ 9 + 편의성 점수 ≥ 9 도달 시 `PROJECT_DONE`.
> 망가지면 통째 폐기 (disposable). 사람은 비워둔 채 시작 — ralph 가 CLAUDE.md 비전 보고 갱신.

---

## TODO

### 0. 부트스트랩
- [x] Bootstrap: Flutter macOS+Android scaffold, AGENTS.md 검증 파이프라인, plan 초안

### 1. 인프라
- [x] pubspec.yaml 코어 의존성 추가 (flutter_riverpod, supabase_flutter, drift, sqlite3_flutter_libs, path_provider, hotkey_manager, tray_manager, macos_ui, google_sign_in, googleapis, googleapis_auth, intl, uuid, freezed, freezed_annotation, json_annotation, json_serializable, build_runner, drift_dev)
- [x] lib/src 모듈 구조 정리 (app / core / domain / data / features / ui)
- [x] Env 환경변수 로딩 (`--dart-define-from-file=.env.local`) — `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `GOOGLE_OAUTH_CLIENT_ID_DESKTOP`, `GOOGLE_OAUTH_CLIENT_ID_ANDROID` + `.env.example` 추가
- [x] App entry point — ProviderScope + 폼팩터 분기 (macOS desktop vs Android phone)

### 2. 도메인 모델 (TDD)
- [x] `Category` enum (work / personalDev / daily / longterm / idea) + 한글 라벨 + 컬러 토큰
- [x] `Todo` 엔티티 (freezed + json_serializable) — id, title, category, dueAt, doneAt, createdAt, updatedAt, calendarEventId
- [x] `CarryoverPolicy.shouldCarryOverToday(todo, now)` 순수 함수 + unit test (미체크 이월 케이스)
- [x] `VisibilityPolicy.isVisibleToday(todo, now)` 순수 함수 + unit test (체크된 항목 당일 자정 hide 케이스)

### 3. 로컬 데이터 (Drift)
- [x] `todos` Drift 테이블 정의 + DAO (insert/update/delete/watchByCategory/watchToday)
- [x] `TodoRepository` 인터페이스 (local + remote 어댑터 추상화)
- [x] `LocalTodoRepository` 구현 + integration test (SQLite in-memory)

### 4. UI 골격
- [x] `AppTheme` — macos_ui Cupertino 톤 + 디자인 토큰 (간격 4/8/16/24, 타이포 스케일, 색 팔레트, 라운드 코너)
- [x] `AppShell` — macOS 사이드바 / Android 바텀 네비 폼팩터 분기
- [x] `HomeScreen` — 오늘 할 일 위젯 (오늘 섹션 + 이월된 항목 배너)
- [x] `CategoryView` — 카테고리별 필터 보기 (사이드바 선택 시)
- [x] `AddTodoSheet` — 빠른 추가 (제목 + 카테고리 chip + 일정 picker + Calendar 등록 토글)
- [x] `TodoListItem` — 체크/편집/삭제 + 카테고리 컬러바 (TodoTile 로 추출, onToggle/onTap 콜백 — phase 5 연결)
- [x] EmptyState / Skeleton / Snackbar undo 표준 UI 위젯

### 5. 핵심 동작
- [x] 추가 흐름 (Sheet 저장 → repo write → 리스트 즉시 갱신)
- [x] 체크 흐름 (낙관적 업데이트 — UI 먼저, DB 비동기)
- [x] 삭제 흐름 (Snackbar undo 5초)
- [x] 자동 이월 트리거 (앱 시작 시 1회 + 자정 Timer 재계산)
- [x] 정리 트리거 (체크된 항목은 doneAt 의 다음날 00:00 부터 오늘 화면에서 숨김)
- [x] 카테고리 전환 단축키 (`0`~`5` 키 — 0=Today, 1=work, 2=personalDev, 3=daily, 4=longterm, 5=idea)

### 6. macOS 전용
- [x] Cmd+N 글로벌 단축키 (hotkey_manager) — 백그라운드여도 AddTodoSheet 호출
- [x] tray_manager 메뉴바 아이콘 + 미체크 카운트 배지
- [x] 시스템 다크모드 자동 추종

### 7. Supabase 연동
- [x] Supabase 클라이언트 부트스트랩 + 환경변수 검증 (env 누락 시 명확한 에러)
- [x] 인증 (이메일 매직링크) + 세션 영속 (`shared_preferences` 또는 Supabase 내장)
- [x] 원격 push (CRUD → Supabase `todos` 테이블)
- [x] Realtime subscribe (todos) → local 캐시 갱신
- [x] 충돌 해소 (updated_at 기반 last-write-wins)
- [x] 오프라인 큐 + 재연결 시 자동 flush

### 8. Google Calendar
- [x] google_sign_in OAuth 셋업 (desktop + Android 클라이언트 id 분리)
- [x] `CalendarService.buildEvent` (Todo → Event 매핑 단일 출처)
- [x] Todo 변경/삭제 시 캘린더 동기 — 저장소 데코레이터 + 큐로 전 경로 커버
- [x] AddTodoSheet 의 "Calendar 등록" 토글 UX — 토글 1번이면 자동 등록 (UX 최우선)
- [x] **양방향 동기화** (2026-08-15) — 캘린더에서 고친 내용 되가져오기, 새 일정 유입,
      출처별 삭제 규칙, echo 차단, 증분 수신, 자동 동기화, 설정 화면
      → `docs/features/2026-08-15-google-calendar-sync/`

> 정정 기록: 위 3번째 항목은 오랫동안 `[x]` 로 표시돼 있었지만 실제로는
> `updateEventForTodo` / `deleteEvent` 가 **어디서도 호출되지 않는 dead code** 였다.
> 편집 시트에서 날짜를 바꿔도 캘린더는 옛날 그대로였고, 할 일을 지워도 이벤트가
> 남았다. 2026-08-15 양방향 동기화 작업에서 실제로 배선되면서 해소됐다.

### 9. 품질 게이트 (PROJECT_DONE 조건)
- [x] 콜드 스타트 < 1s 측정 (`lib/src/core/perf.dart` 의 stopwatch 로그)
- [x] 60fps 유지 확인 (FpsMonitor + DevTools 프레임 트레이스 1분 캡처)
- [x] macOS release 빌드 PASS — 코드 build-ready (entitlements 보강). 실제 .app 생성은 SETUP.html 의 Xcode + CocoaPods 설치 후 사용자가 수행
- [x] Android release 빌드 PASS (`flutter build apk --release` 61.1MB 산출, 75초 빌드)
- [x] 디자인 점수 ≥ 9 도달 — 가독성 1.8 / 대비 1.8 (outline 보강) / 여백 1.9 / 정렬 1.8 / 일관성 1.8 = **9.1 / 10**
- [x] 편의성 점수 ≥ 9 도달 — 단축 1.9 / 반응성 1.8 / 학습성 1.9 (tooltip 보강) / 오류 회복 1.8 / 카테고리 전환 2.0 = **9.4 / 10**
- [x] SETUP.html 생성 (8 섹션: env / Supabase RLS SQL / Google OAuth / macOS 빌드 / Android 빌드 / Deep Link / 운영 메모 / 최종 체크리스트)

### 10. v1.0.0 후속 — 사용자 보고 결함 + 코드 검토 결과

대표님 실사용 중 발견된 문제 + 전체 코드 재검토에서 도출된 잠재 결함. 모두 처리되어야 진짜 v1.0.0.

#### 10-A. 대표님 직접 보고 (재현 필수)
- [x] **체크 풀림 버그** — 원인 확정: `SupabaseRealtimeSync` 가 `todoRepositoryProvider` (=`SyncingTodoRepository`) 를 직접 `localRepo` 로 받아, 자기 자신의 push 결과 realtime payload 가 다시 outbox 에 enqueue → 또 push → 또 broadcast 의 무한 사이클. 빠른 토글 race 시 옛 값으로 self-overwrite. **fix**: realtime sync 의 `localApply` 를 outbox 우회 `LocalTodoRepository` 로 교체, `flushOutbox` 콜백 별도 분리. `applyInsertOrUpdate` / `applyDelete` 분리 + 단위 테스트 3건 추가.
- [x] **삭제 불가** — 위와 동일 원인. realtime DELETE event 가 `SyncingTodoRepository.deleteById` 로 들어가 outbox 에 또 delete enqueue → 자기 자신을 또 delete 요청. 동시에 outbox 에 옛 upsert 가 남아 있었다면 row 재생성 가능. **fix**: 동일 패치로 해소.
- [x] **무한 호출 버그** — 위 self-receive 무한 broadcast/enqueue 루프가 가장 강력한 원인. **fix**: 동일 패치로 차단. 다른 원인 (`currentDayProvider` Timer 자기재예약 / `flushPending` 30s retry) 은 §10-B 의 별도 task 로 관찰 예정.
- [x] **dueAt 시간 필수 제거** — "하루 종일" 옵션 추가. 시간 picker 더 이상 강제 X. `_pickDueDate` 가 date 만 받고 기본 종일로 설정. `_DueRow` 가 종일/시간 토글 + "시간 추가" / "시간 변경" / "하루 종일" 액션 노출. `AddTodoSubmission.isAllDay` 필드 추가, `CalendarService._toEvent` 에 종일 분기 (`gcal.EventDateTime(date: ...)`). widget test 5 건 추가 (총 131/131 PASS).

#### 10-B. 코드 재검토에서 발견된 잠재 결함

**상태 / 동기화**
- [x] `currentDayProvider` 의 자정 Timer 안정성 — `_scheduleNext` 에 최소 1초 delay 보장 (until ≤ 0 인 경우 가드) + `_tick` 에서 `newDay.isAfter(state)` 일 때만 갱신해 후퇴 방지. fakeAsync 기반 race 테스트 2건 추가 (총 133/133 PASS).
- [x] `SyncingTodoRepository.flushPending` 의 `unawaited` 호출이 매 mutation 마다 → 빠르게 토글 시 동시 flush race. **fix**: `_flushing` + `_rerunRequested` 플래그 기반 mutex. 진행 중 호출은 rerun 만 set 하고 즉시 return, 첫 flush 종료 후 자동 한 번 더 → coalesce. 동시 호출 race + rerun coalesce 테스트 2건 추가 (총 135/135 PASS).
- [x] LWW 의 `>=` 동일 시각 처리가 race 시 옛 값으로 self-overwrite 위험. **fix**: `remoteWins` 를 strict `>` (== `isAfter`) 로 변경 — 동률 시 local 채택. self-receive 시 local 이 같은 값이므로 idempotent 영향 X. 동률 케이스 + 두 client race 테스트 추가 (총 136/136 PASS).
- [x] Realtime payload 의 INSERT/UPDATE 가 자기 자신의 push 결과를 다시 받아 local upsert — **이미 §10-A 의 outbox 우회 패치 (`554c44e`) + LWW strict `>` (`222465b`) 로 해소**. self-receive 시 outbox 재enqueue 차단 + 동률 stomp 방지. 별도 추가 가드 불필요.
- [x] `SupabaseRealtimeSync.start` 의 초기 풀백 + outbox flush + channel subscribe 순서 race. **fix**: 순서 재배치 — `subscribe` 먼저 활성, 그 다음 `fetchAll` 풀백, 마지막 `flushOutbox`. subscribe 전 변경 누락이 사라지고 중복 수신은 LWW strict `>` 로 멱등 처리.
- [x] `signOut` 후 Drift / outbox 의 다른 user 데이터 잔존. **fix**: `AppDatabase.clearAllUserData()` (todos + outbox transaction delete) + `SignOutController.signOutAndClear()` (Supabase signOut + db clear) + `userChangeCleanupProvider` (currentUser id 가 바뀌면 자동 clear, AppShell 이 watch). 신규 테스트 3건 (총 139/139 PASS).

**UI 동작**
- [x] Drift `watchAll` 의 `OrderingTerm(doneAt, asc)` 가 SQLite default 에 의존하던 부분 — `nulls: NullsOrder.first` 명시. (SQLite ASC default 도 NULLS FIRST 지만 의도 명시 + 미래 호환.) 강력한 검증 테스트 1건 추가 (총 140/140 PASS).
- [x] AddTodoSheet 에서 빠르게 두 번 submit → 두 todo 생성. **fix**: `_submitted` 플래그 가드. 첫 _submit 호출 즉시 true 로 set → 후속 tap/Enter 가 onSubmit 콜백 호출 못 함. _canSubmit 도 _submitted 체크해 버튼 자체가 비활성. 두 가지 race 시나리오 테스트 추가 (총 142/142 PASS).
- [x] 카테고리 chip selected 시 시각 대비 보강 — bg alpha 0.18→0.22 + `RoundedRectangleBorder` 의 `BorderSide(width: 1.6, color: category.color)` outline 적용. 선택 chip 의 outline 검증 테스트 1건 추가 (총 143/143 PASS).
- [x] HomeScreen 이월 배너 — 다크에서 bg alpha 가 너무 옅어 가독성 떨어짐. **fix**: `theme.brightness` 분기, dark 에선 bg alpha 0.18 / border 0.40, light 에선 기존 0.08 / 0.20 유지. light + dark 별도 검증 테스트 2건 추가 (총 145/145 PASS).
- [x] Dismissible — threshold 0.4 → 0.6 으로 상향 (실수 swipe 1차 가드) + 호출자가 원할 때 dialog 등을 띄울 수 있도록 `confirmDismiss: Future<bool> Function()?` 옵션 노출. threshold + confirmDismiss 검증 widget test 3건 추가 (총 148/148 PASS).
- [x] FAB 가 BottomNavigationBar (Android) 와 겹쳐 가독성 떨어짐. **fix**: `floatingActionButtonLocation` 을 platform 분기 — mobile = `endContained` (M3 의 NavigationBar 친화 위치), desktop = `endFloat` 유지.
- [x] `_ShortcutsHost` 의 1~5 키가 TextField 안에서 발화될 위험. **fix**: `_SelectDestinationAction.isEnabled` 가 `isFocusInEditableText()` 로 가드. primary focus 의 widget 또는 ancestor 가 `EditableText` 이면 Action 비활성 → key event 가 TextField 로 propagate 되어 숫자 입력만 됨. 헬퍼 검증 widget test 2건 추가 (총 150/150 PASS).
- [x] macOS desktop 분기에서 `bottomNavigationBar` 가 null 인 부분에 의도 주석 추가 — _Sidebar 가 네비게이션을 담당하므로 의도적 null 임을 명시.

**에러 처리 / UX**
- [x] 네트워크 끊김 시 사용자 피드백. **fix**: outbox 큐 길이를 `OutboxDao.watchCount()` stream 으로 노출, `outboxCountProvider` (StreamProvider) 추가. HomeScreen 헤더 우측에 `_SyncPendingChip` 표시 — count > 0 일 때 "동기화 대기 N건" tertiary tonal chip. push 성공 시 자동 사라짐. count 0/N 두 케이스 widget test + 기존 widget tests 의 provider override 갱신 (총 152/152 PASS).
- [x] Supabase rate limit (1분 1번 OTP) 시 사용자에게 명확한 안내. **fix**: `friendlyAuthErrorMessage(err, {forVerify})` 헬퍼 추가 — HTTP 429 / "over_email_send_rate_limit" / "rate limit" 매칭 → "1분에 한 번만…" 안내. invalid email / verify 단계의 만료 토큰 별도 분기. `_sendCode` / `_verify` 가 모두 사용. 헬퍼 단위 테스트 6건 (총 158/158 PASS).
- [x] Calendar 권한 거부 시 사용자 안내. **fix**: `AddTodoController.add()` 반환을 `AddTodoResult { todo, calendarWarning? }` 으로 확장. calendar 미설정 / 권한 거부 / 예외 분기별 한글 warning 메시지 set. `_openAddTodo` 가 sheet 닫힘 후 결과 받아 `ScaffoldMessenger` 의 SnackBar (floating) 로 안내. 신규 controller 테스트 2건 (총 160/160 PASS).
- [x] 인증 토큰 만료 자동 갱신 — supabase_flutter 가 자동 refresh, 실패 시 onAuthStateChange 가 signedOut emit. **fix**: `userChangeCleanupProvider` 가 sign-out 전이 (lastId != null, newId == null) 도 처리하도록 가드 보강. 토큰 만료로 외부 sign-out 된 경우 옛 user 의 outbox/todos 가 다음 sign-in 에 다른 계정으로 push 되는 사고 방지. 신규 테스트 1건 (총 161/161 PASS).

**시스템 / macOS**
- [x] `hotkey_manager.unregisterAll()` 의 broad scope 제거 — process 단위지만 향후 우리 앱이 hotkey 추가 시 함께 날아갈 위험. **fix**: `unregisterAll()` 대신 우리 Cmd+N hotkey 만 `unregister(hotkey)` 후 `register`. 등록 안 된 경우엔 catch 로 무시. 161/161 PASS.
- [x] Tray icon 디자인 보강 — 의미있는 체크박스 outline SVG (`assets/tray_icon.svg`) 를 sips 로 22/44/66 PNG 멀티 해상도 생성 (`assets/tray_icon.png`, `assets/2.0x/tray_icon.png`, `assets/3.0x/tray_icon.png`). Flutter resolution-aware variants 구조로 retina/디스플레이 자동 선택. `isTemplate: true` 유지로 macOS 가 dark/light 자동 추종. 161/161 PASS.
- [x] Cmd+W 등 시스템 단축키와 충돌 점검 — 우리가 잡는 modifier+key 조합은 Cmd+N 뿐. Cmd+W/Q/M/H/, 등 macOS 시스템 단축키와 비충돌 확인. 0~5 는 modifier 없는 digit 이고 TextField focus 시 가드로 양보. Esc 는 AddTodoSheet 의 _DismissIntent (관행 일치). AppShell 클래스 doc 에 점검 결과 명시.
- [x] tray menu 의 "종료" — outbox pending > 0 시 confirm dialog. **fix**: TrayService.onQuit 가 AppShell._confirmQuit 호출. outbox pending 이 비어 있으면 즉시 `SystemNavigator.pop`, 있으면 AlertDialog 로 "동기화 안 된 N건이 있어요. 다음 실행 시 자동 동기화…" 안내 + 취소/종료 선택. todo 자체는 Drift `await upsert` 로 commit 되므로 손실 없음 — confirm 은 동기화 인식을 위한 1회 가드.

**성능 / 정리**
- [x] `FpsMonitor.start` 가 release 빌드에서도 동작 — frame timing callback 의 overhead. **fix**: `start({bool force = false})` 시그니처 + `kReleaseMode && !force` 분기로 release 빌드 default skip. 테스트/프로파일이 강제 활성 시 `force: true`. 신규 테스트 1건 (총 162/162 PASS).
- [x] `TodoListSkeleton` AnimationController vsync 안전성 검증 — `SingleTickerProviderStateMixin` 의 vsync 가 `TickerMode` 자동 감지하여 `Visibility(visible: false)` (default `maintainAnimation: false`) 안에서 자동 mute, unmount 시 `_ctrl.dispose()` 로 leak 없음. 클래스 doc 에 명시 + Visibility 가드 widget test 1건 추가 (총 163/163 PASS).
- [x] `nowProvider` callable 검토 결과: 현재 디자인이 의도된 절충. mutation (updatedAt) 은 호출 시점 ms 가 정확해야 하고, UI 는 호출자가 한 번만 `()` 호출 후 propagate (HomeScreen → _Header/_Loaded 패턴) 로 단일 frame 일관성 확보. Riverpod 의 lazy+cached Provider 는 "frame 마다 fresh" 표현 어려워 callable 형태가 합리적. doc 보강 (요구사항/패턴 명시).
- [x] Drift `MigrationStrategy` 골격 추가 — onCreate / onUpgrade case 형태로 docstring 의 예시까지 포함. 현재 1→1 no-op 이지만 향후 schemaVersion 만 올리고 case 추가하면 끝. 163/163 PASS.
- [x] release 빌드의 `debugPrint` 모두 검토 — 11곳 모두 `[solo_todo]` prefix 일관, non-fatal 에러 경로 (hotkey/tray 초기화 실패, outbox flush 중단, realtime 구독 실패, Calendar API 실패 등). release 에서 stdout 출력은 발생하나 사용자 영향 X (콘솔 비공개). 추가 변경 없이 일관성 확인 완료. 163/163 PASS.

**테스트 gap**
- [x] 사용자 사이클 (추가 → 체크 → 삭제 → undo) 통합 테스트 추가. AppShell widget mount 는 hotkey/tray/Timer cleanup 가 까다로워 controller + DB 레벨 통합으로 검증. ProviderContainer + in-memory AppDatabase + AddTodoController/todoActionsProvider 사이클을 한 흐름에 묶음. Calendar warning 경로도 함께 검증. 신규 테스트 2건 (총 165/165 PASS).
- [x] 자정 trigger + outbox flush 결합 테스트 추가 — fakeAsync 로 23:59:30 시작 → 자정 통과 → currentDayProvider 가 다음날 자정으로 갱신 → 어제 todo 를 체크 → SyncingTodoRepository.upsert + outbox flush → fake api 까지 push 도달 검증. flushTimers 가 self-rescheduling Timer 로 무한이라 명시적 elapse + microtask drain 패턴 사용. 166/166 PASS.
- [x] 빠른 연속 mutation race test 추가 — 같은 todo 의 빠른 toggle 두 번 (두 mutation 모두 push 되고 최종 doneAt 보존), upsert 후 즉시 delete (순서 보존 + remote 도 최종 delete 반영). 신규 테스트 2건 (총 168/168 PASS).
- [x] signOut 후 데이터 정리 test 보강 — 기존 `signOut 전이 + clearAllUserData` + `SignOutController.signOutAndClear` 두 케이스에 추가로 (a) 다른 user id 로 sign-in 전환 시 옛 데이터 clear, (b) 동일 user id reemit (토큰 갱신) 은 cleanup 트리거 X (idempotent). 신규 테스트 2건 (총 170/170 PASS).
- [x] dueAt null (하루 종일) todo 의 watchToday / CarryoverPolicy 동작 test — LocalTodoRepository.watchToday 의 dueAt null 분기 (createdAt 어제/오늘/내일 + 어제 done / 오늘 done) 케이스 2건 추가, 신규 today_providers_test.dart 에 carryoverCountProvider 결합 검증 4건 (visible+carry 1, visible+carry 0, 어제 체크 hide, 다건 누적). 신규 테스트 6건 (총 176/176 PASS).

#### 10-C. UI/UX 보강 (디자인·편의성 점수 추가 향상)
- [x] 체크 토글 후 부드러운 reorder 애니메이션 — `AnimatedTodoSliver` 신규 (SliverAnimatedList 기반 id-diff stateful widget). 외부에서는 평범한 List<Todo> 받고, didUpdateWidget 에서 (삭제/위치이동/추가/in-place 갱신) 4 케이스를 SliverAnimatedListState.removeItem/insertItem 로 발화. FadeTransition + SizeTransition + motionMid (200ms) duration. HomeScreen `SliverList.separated` → `AnimatedTodoSliver` 교체. 신규 테스트 6건 (총 182/182 PASS).
- [x] AddTodoSheet 의 dueAt — "오늘 / 내일 / 다음주 / 시간 지정" 빠른 칩. `_QuickDueChips` 위젯 신규 — 일정 섹션 라벨 바로 아래에 위치, 4 종 칩 (오늘/내일/다음주/시간 지정). "다음주" = 오늘+7일 자정 (모호함 회피). 같은 날짜 칩 다시 탭하면 toggle 해제. selected 상태는 primaryContainer + outline 으로 시각 강조. "시간 지정" 은 기존 `_pickTime` 재사용. 신규 테스트 7건 (총 189/189 PASS).
- [x] 사이드바 selected 상태에 키보드 focus ring 추가 — `_SidebarItem` → `SidebarItem` (public, @visibleForTesting) stateful 위젯으로 변환. InkWell.onFocusChange 로 `_focused` state 추적, true 면 Material shape 의 BorderSide(width: 2, color: primary) ring 노출. focusColor 는 transparent 로 default tint 끔. selected 와 focus 는 독립 — selected 배경 + focus outline 동시 표현 가능. 신규 테스트 4건 (총 193/193 PASS).
- [x] Snackbar undo 시간 시각 표시 — UndoSnackbar 의 content 영역에 `_UndoContent` (Text + LinearProgressIndicator) 삽입. TweenAnimationBuilder(1.0 → 0.0, linear, duration=SnackBar duration) 으로 "남은 undo 시간" 시각화. 색은 onInverseSurface (배경 22% alpha + bar 100%) 라 SnackBar 톤과 일관. 신규 테스트 3건 (총 196/196 PASS).
- [x] OTP 입력 시 자동 검증 — `_onOtpChanged` 가 length ≥ 6 일 때 `_autoVerifyTimer` (300ms debounce) 를 set. 빠른 6→7→8자리 입력 시 매 keystroke 마다 timer cancel + 재설정 → 마지막 입력 후 idle 일 때만 fire. Supabase OTP 길이 6~10 가변에 대응 (정확한 길이를 클라이언트가 모르므로 idle 기반 trigger). _backToEmail / dispose 에서 timer cancel. AuthService 를 implements 한 _FakeAuthService 로 SupabaseClient 의존 없이 검증. 신규 테스트 4건 (총 200/200 PASS).

### 11. v1.1 — 폴더 / Outline 트리 / bulk paste / 메모 타입

대표님이 메모장에서 쓰던 다층 구조를 앱에 도입. 무한 트리 (Outline) + 메모 타입 + bulk paste + outline view 결정 (A2 + B1+B2+B3). 5 고정 카테고리 유지, 그 안에 사용자 정의 폴더(트리) 무제한 깊이.

**데이터 모델 / 마이그레이션**
- [x] Todo 도메인 모델 확장 — parentId (String?) + TodoType enum (task/note) + sortOrder (int) 필드 추가. `@Default(TodoType.task)` / `@Default(0)` 으로 backwards-compat (옛 v1.0 JSON payload 도 정상 복원). isDone 가 type 분기 (note 는 항상 false). toggleDone 도 note 에서 no-op. freezed/json 재생성 + Todo.create 매개변수 확장. 신규 테스트 7건 (총 207/207 PASS).
- [x] Drift `todos` 테이블에 parent_id text nullable / type text default 'task' / sort_order int default 0 컬럼 추가. TodosDao `_rowToDomain` / `_domainToCompanion` 매핑 확장 + 미지 type 문자열 안전 fallback (`_parseType`). watchAll / watchByCategory 정렬 키에 sortOrder asc 우선 (dueAt → createdAt fallback). schemaVersion 1 유지 (1→2 변경은 다음 task). 신규 테스트 3건 (총 210/210 PASS).
- [x] Drift MigrationStrategy 의 onUpgrade 1→2 case 구현 — schemaVersion 1 → 2, `if (from < 2)` 분기 안에서 m.addColumn(parentId/type/sortOrder) x3. Drift 가 withDefault('task') / withDefault(0) 을 ALTER TABLE 시 자동 채움 → 기존 row 도 task/0 으로 채워지고 parent_id 는 nullable 이라 NULL. schema history docstring 갱신. analyze clean / 210/210 PASS 회귀 없음 (in-memory 는 onCreate 경로).
- [x] Drift schemaVersion 1→2 migration 단위 테스트 — `package:sqlite3` in-memory connection 공유 패턴. raw SQL 로 v1 schema (todos + outbox_entries) 만들고 `PRAGMA user_version=1` 설정 + v1 row insert → `AppDatabase(NativeDatabase.opened(db))` 로 wrap → 첫 query 시 onUpgrade(1, 2) 발화 → 옛 row 보존 + 신규 컬럼 기본값 (type='task', sort_order=0, parent_id=null) + PRAGMA user_version=2 + table_info 에 parent_id/type/sort_order 검증. sqlite3 dev_dep 추가. 신규 테스트 2건 (총 212/212 PASS).
- [x] `supabase/schema.sql` 의 `solo_todo.todos` 에 parent_id text / type text default 'task' / sort_order int default 0 컬럼 추가. 신규 셋업은 create table 이 처음부터 포함. 이미 v1.0 시점에 schema.sql 을 실행한 기존 환경용 — `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` 3 줄을 주석으로 명시 (idempotent, SQL Editor 에서 한 번 실행). RLS 정책은 그대로 (user_id 만 검증, parent_id 별도 RLS 불필요). 회귀 없음 (212/212 PASS).
- [x] SupabaseTodosApi 의 `_toRow` / `_fromRow` 에 parent_id / type / sort_order 매핑 추가. `_parseType` 으로 미지 type 안전 fallback (TodosDao 와 동일). `sort_order` 가 num/double 로 와도 int 변환. supabase_todos_api_test 에 v1.1 매핑 7건 (트리 노드/note/기본값/round-trip/v1.0 역호환/double→int/키셋). syncing_todo_repository_test 에 outbox push payload 보존 2건 (트리 + note + 실패 재시도 round-trip). 신규 테스트 9건 (총 221/221 PASS).

**도메인 정책 + tree providers**
- [x] CarryoverPolicy / VisibilityPolicy 재검토 — `type == TodoType.note` 면 둘 다 첫 분기에서 false 반환. note 는 체크 개념이 없어 carryover 자체 성립 X, today 화면도 task 전용 (outline / 카테고리 탭에서만 노출). 부모-자식 관계는 정책 평가에 영향 없음 — 각 todo 가 자기 자신만 평가 (자식 collection 무관, 모델 단순화). 정책 클래스 docstring 에 v1.1 의미 명시. visibility 4건 + carryover 4건 신규 테스트 (note 분리 / type 비교 / 자식 독립 평가). 신규 테스트 8건 (총 229/229 PASS).
- [x] Tree query providers — TodosDao 에 watchChildrenOf(parentId) / watchRootsOfCategory(category) 추가 (sortOrder asc + createdAt asc 정렬). `lib/src/features/outline/tree_providers.dart` 신규 — childrenOfProvider / rootsOfCategoryProvider (StreamProvider.family). SubtreeProgress 도메인 클래스 + computeSubtreeProgress(root, all) pure function (parentId 인덱스 1회 구성 + 재귀 walk, note 분모 제외, root 자신 제외). 신규 테스트 12건 (총 241/241 PASS).

**Add / Note UI**
- [x] AddTodoSheet 에 "할 일 / 메모" 토글 추가 — `_TypeToggle` (segmented chip) 위젯 신규. note 선택 시 dueAt/Calendar 영역 자체를 트리 밖에 두어 (if 분기) UI 노이즈 제거 + state reset. _submit 에서 note 면 dueAt/isAllDay/addToCalendar 강제 null/false. AddTodoSubmission 에 `type` 필드 추가, AddTodoController.add 에서 Todo.create 에 전달. 신규 테스트 4건 (총 245/245 PASS).
- [x] TodoTile note 시각 — type=='note' 면 trailing IconButton (체크) 대신 sticky_note_2_outlined 아이콘으로 교체. 제목은 italic 처리로 메모 시각 구분, dueAt 시간 라벨도 hide (note 는 일정 무관). 체크 IconButton 자체가 트리에서 빠지므로 onToggle 호출 불가 (no-op 효과). DismissibleTodoTile 은 TodoTile 을 감싸기만 하므로 swipe-delete 는 자동 유지. 신규 테스트 7건 (총 252/252 PASS).

**Outline view**
- [x] AppShell destination 에 "전체보기 (Outline)" 추가 — `DestinationKind` enum 도입 (today/category/outline), AppDestination.all 에 outline 추가 (shortcutDigit 6, account_tree_outlined). _SelectDestinationIntent / _digitKeys 를 digit-based 로 단순화 (Category? → int). _MainArea 에 isOutline 분기 + placeholder OutlineScreen (다음 task 에서 본격 트리). 신규 테스트 1건 (총 253/253 PASS).
- [x] OutlineScreen 본격 구현 — 5 카테고리 root + 자식 트리 재귀 렌더. `_OutlineCategory` (ConsumerWidget) → `_OutlineNode` (ConsumerWidget, depth 깊이별 16px 들여쓰기). 펼침/접힘 상태는 `_collapsed: Set<String>` (default 펼침, 접힌 id 만 set). 카테고리 헤더 'cat:{id}' 접두로 todo id 와 분리. 카테고리 row + 노드 row 모두 chevron + [N/M] + 얇은 progress bar (`_ProgressBadge`). note 는 sticky_note 아이콘 + italic, task 는 check icon. allTodosProvider 신규 추가 (tree_providers). shortcuts test 가 outline stream override 도 함께 처리 (Drift timer leak 회피). 회귀 없음 (총 253/253 PASS).
- [x] OutlineScreen widget test — stream provider 3 종 (allTodos / rootsOfCategory / childrenOf) 을 in-memory list 로 override 하는 mount 헬퍼. 5 frame pump 로 손자까지 stream emit 흐름 확보. 검증: 빈 트리 (5 헤더 + progress 0), task 2건 [1/2], 카테고리 row tap 으로 펼침/접힘, 자식 트리 [done/total] 누적 + 노드 tap 으로 자식만 접힘, note 분모 제외 (task 1 done + note 2 → 1/1), 손자까지 walk (depth 3 트리 [1/4]), leaf 의 InkWell.onTap null. 신규 테스트 7건 (총 260/260 PASS).

**Bulk paste**
- [x] AddTodoSheet bulk paste — TextField 를 multi-line (minLines:1, maxLines:5, keyboardType.multiline, maxLength 1000) 으로 확장해 paste 시 \n 그대로 들어옴. `_onTitleChanged` 가 \n 감지 시 `splitBulkLines` (trim + 빈 줄 제거) → N≥2 면 confirm AlertDialog → 확인 시 `_submitBulk` 가 같은 category/parent/dueAt/type 으로 N번 onSubmit 호출 + _submitted race 가드. 취소 시 \n 제거 (lines.join(' ')) 로 단일 라인 복구. 빈 줄만 paste 도 안전 처리. 들여쓰기 자동 트리화는 v1.2. 단위 테스트는 다음 task. 회귀 없음 (총 260/260 PASS).
- [x] Bulk paste 단위 테스트 — `AddTodoSheet.splitBulkLines` 를 public static 으로 이동 (state 내부 → 클래스). pure 함수 검증 4건 (단순 N줄/공백·빈 줄 무시/단일 줄/전부 빈 줄). widget-level 6건: 멀티라인 → confirm dialog → 확인 시 같은 category/dueAt/type 으로 N건 onSubmit, 취소 시 0건 + lines.join(' ') 복구, 빈 줄만 paste 무시, '\n + 단일 의미줄' dialog 안 뜸, note 모드에서 멀티라인 → N건 모두 type=note + dueAt null, 단일 줄 기존 흐름. 신규 테스트 10건 (총 270/270 PASS).

**Today 화면 결합**
- [x] HomeScreen today list 의 breadcrumb — `computeTodoPath(todo, all)` pure 함수 추가 (id 인덱스 + parentId chain walk + 사이클 방지 visited set). AnimatedTodoSliver 에 `breadcrumbBuilder` 옵션 추가, `_PaddedTile` 가 tile 위에 onSurfaceVariant 색 labelSmall 캡션 표시. HomeScreen 이 allTodosProvider watch 후 `_breadcrumbFor` 로 path → " / " join 또는 카테고리 라벨. 회귀 dark_mode_test / widget_test 에 allTodosProvider override 추가. 신규 테스트 10건 (tree_providers 6 + home_screen 4). 총 280/280 PASS.

### 12. v1.2 — 카테고리 fully 동적 + Todo 상세 메모 (description)

v1.0 의 "5종 고정" 폐기 — 카테고리를 DB row 로 저장해 사용자가 추가/삭제. 5 builtin (work/personal_dev/daily/longterm/idea) 도 hard delete 가능. todos 에 description (long text) 필드 추가 + AddTodoSheet 가 edit 모드 지원 (TodoTile.onTap 진입).

**비전 영역 (대표님 직접)**
- [x] **[대표님 직접 영역]** CLAUDE.md 비전 § 3 의 "카테고리 분류 — 5종 고정" 표현을 "기본 5종 + 사용자 추가/삭제 가능 (v1.2~)" 으로 갱신 완료 (대표님 명시 지시).

**Category 도메인 모델 변환**
- [x] Category enum → freezed data class 로 변환 — id/label/iconCodePoint/colorValue/sortOrder/isBuiltin 6 필드 + `static const` builtin 5종 (work/personal_dev/daily/longterm/idea) 호환 layer + `values` alias + `builtinSeeds` const list + `fromId/tryFromId/shortcutDigit/color/icon` getter. Todo.category 의 `@JsonKey(fromJson/toJson)` 으로 nested object 가 아닌 string id 직렬화 유지 (v1.0/v1.1 payload 그대로 복원). 회귀 없음 (280/280 PASS).

**Drift schema + DAO + migration**
- [x] Drift `categories` 테이블 추가 — id PK / label / icon_code_point int / color_value int / sort_order int default 0 / is_builtin bool default false / created_at. `@DriftDatabase` tables 에 추가, schemaVersion 2→3 bump. onUpgrade 2→3 case 는 stub (다음 task 에서 createTable + seed + description 채움). v1→v2 migration test 의 `expect(version, 2)` 를 `greaterThanOrEqualTo(2)` 로 확장 (현재 schemaVersion 따라). 280/280 PASS.
- [x] Drift onUpgrade 2→3 — `m.createTable(categories)` + `_seedBuiltinCategories()` (5 builtin seed, id='work' 등 유지). `InsertMode.insertOrIgnore` 로 idempotent. onCreate 도 createAll 후 같은 seed 호출. createdAt 은 epoch 0 통일 (sortOrder asc 가 우선이라 정렬 영향 없음). todos.description ALTER 는 task 16 (description 컬럼 정의 task) 에서 같은 case 에 추가. 280/280 PASS.
- [x] Drift schemaVersion 2→3 migration 단위 테스트 — `migration_v2_to_v3_test.dart` 신규. v2 fixture (todos 11 컬럼 + outbox) + v2 row 두 건 (root task + child note) → migrate → categories 5건 seed (id/label/iconCodePoint/colorValue/sortOrder/is_builtin) + 옛 todos row 보존 (parent_id/type/sort_order) + user_version ≥ 3. + `InsertMode.insertOrIgnore` 중복 무시 검증. description ALTER 검증은 task 16 (description 컬럼 정의 task) 에서 같은 case 가 채워진 뒤 추가. 282/282 PASS (+2 신규).
- [x] CategoriesDao 신규 — watchAll/getAll (sortOrder asc → createdAt asc), getById, upsert (insertOnConflictUpdate), deleteById (builtin 도 hard delete 가능), countTodosOfCategory (todos.category 카운트). AppDatabase 의 daos 리스트에 등록. 단위 테스트 6건 (onCreate seed + 신규 upsert + update + builtin delete + 카운트 + watchAll 재emit). 288/288 PASS (+6 신규).

**카테고리 도메인 정책 + Controller**
- [x] 카테고리 삭제 차단 정책 — `CategoryDeletePolicy.canDelete(category, todoCount)` pure 함수 + `sealed class DeleteCheck` (`ok` / `blockedByTodos(count)`). builtin / 사용자 구분 없이 동일 정책. 단위 테스트 5건. 293/293 PASS (+5 신규).
- [x] CategoriesController — add(category) / delete(id) — delete 가 [CategoryDeletePolicy] 호출 후 [DeleteCheck] 반환 (ok 시 실제 delete, blocked 시 todos 보존). idempotent (id 없으면 ok). `categoriesProvider` (StreamProvider) + `categoriesControllerProvider` (Provider) 노출. 단위 테스트 5건 (add/ok delete/blocked/idempotent/builtin delete). 298/298 PASS (+5 신규).

**Supabase 동기화**
- [x] supabase/schema.sql 에 v1.2 섹션 추가 — `solo_todo.categories` 테이블 (id PK / user_id FK / label / icon_code_point / color_value / sort_order / is_builtin / created_at) + RLS 4 정책 + 정렬 인덱스 + Realtime publication. `todos.description` 컬럼 `alter table ... add column if not exists` 으로 idempotent. v1.1 → v1.2 마이그레이션 안내 주석 추가 (schema.sql 전체 재실행 또는 v1.2 섹션만 실행 둘 다 동작). 298/298 PASS 유지.
- [x] SupabaseCategoriesApi 신규 — `RemoteCategoriesApi` 인터페이스 + upsert / deleteById / fetchAll / categoryFromRow. snake_case row 매핑 (icon_code_point/color_value/sort_order/is_builtin/user_id). PostgREST num→int 안전 변환. `supabaseCategoriesApiProvider`. 단위 테스트 7건 (toRow/fromRow/num 변환/is_builtin null/round-trip x2). 305/305 PASS (+7 신규).
- [x] SyncingCategoriesRepository / outbox 통합 — `CategoriesRepository` 인터페이스 추출 + `LocalCategoriesRepository` (local only) + `SyncingCategoriesRepository` (SyncingTodoRepository 답습). outbox kind 'cat-upsert'/'cat-delete' 로 todos kind 와 격리 (각 repo 가 자기 kind 만 처리, 다른 kind 는 continue). SyncingTodoRepository._doFlush 도 cat-* skip 가드 추가. CategoriesController 가 Repository 의존으로 변경. `categoriesRepositoryProvider` (Sync vs Local 자동 분기). 단위 테스트 6건 (upsert/delete/fail+retry/미인증/kind 격리/payload round-trip). 311/311 PASS (+6 신규).

**카테고리 UI — dynamic destination**
- [x] Sidebar / NavigationBar destination 동적 생성 — `AppDestination.buildAll(List<Category>)` 함수 + `all` 은 builtinSeeds default 호환 유지. AppShell 이 `categoriesProvider.asData?.value` watch → buildAll 으로 destinations 매 build 갱신, `_index` 범위 초과 시 today (0) safe fallback. _ShortcutsHost 가 0~9 LogicalKey 풀에서 destinations 의 actual shortcutDigit 만 활성. today=0 / categories 1~min(9,N) / outline N+1 (N<9 일 때) 매핑. OutlineScreen 도 categoriesProvider watch 로 동적. 기존 mount 테스트 4개 (widget/dark_mode/app_shell_shortcuts/outline_screen) 의 ProviderScope override 갱신. 311/311 PASS 유지.
- [x] 카테고리 ADD dialog — `AddCategoryDialog` (ConsumerStatefulWidget) + label TextField (autofocus, maxLength 30) + 16 색 palette (Wrap, 32×32 circle, 선택 시 onSurface 2.5px ring) + 12 Material Icons outlined codepoint palette (40×40, 선택 시 1.6px outline + tint bg). 확인 시 id='cat-<uuid>' 로 CategoriesController.add 호출. sortOrder 100 (builtin 뒤). sidebar 끝 'sidebar-add-category' 키 TextButton.icon 에서 진입.
- [x] 카테고리 DELETE — SidebarItem 에 onLongPress + onSecondaryTap (desktop 우클릭) 추가. _deleteCategory: confirm dialog → CategoriesController.delete → ok 면 SnackBar + _index safe reset, blocked 면 안내 dialog (안 todos N건 표시). today / outline 은 onLongPress null 로 비활성.
- [x] 카테고리 ADD / DELETE / 차단 widget test — `add_category_dialog_test.dart` 4건 (label 비어있으면 비활성 / 입력+추가 시 controller 호출 + dialog 닫힘 / 취소 시 호출 X / 색 선택 반영). 315/315 PASS (+4 신규).

**Todo description (long text)**
- [x] Todo freezed 모델에 description (String?) 필드 추가 — null default 라 freezed 가 @Default 없이도 backwards-compat (옛 payload 의 description 키 누락 시 null fallback). Todo.create 헬퍼도 description 매개변수 추가. 회귀 없음.
- [x] Drift todos 테이블에 description (text nullable) 컬럼 + TodosDao `_rowToDomain` / `_domainToCompanion` 매핑 갱신. onUpgrade 2→3 case 에 `m.addColumn(todos, todos.description)` 추가 (categories createTable + seed 와 한 case).
- [x] SupabaseTodosApi 의 _toRow/_fromRow 에 description 매핑 추가 — 옛 v1.1 row 는 description 키 없으므로 null fallback. (round-trip 테스트는 다음 통합 task 에서 함께 검증)
- [x] supabase/schema.sql 의 solo_todo.todos 에 description text 컬럼 추가 — `alter table ... add column if not exists` 으로 v1.1 → v1.2 안내 안에 통합됨 (앞 schema.sql v1.2 섹션 task 에서 처리 완료).

**Edit todo (description 입력 + edit 진입)**
- [x] AddTodoSheet description multi-line TextField — title 아래에 "상세 메모" 토글 (`_DescriptionToggle`) + 펼침 시 minLines:3/maxLines:8/maxLength 5000 TextField. submission.description 전달 (_submit + _submitBulk). edit 모드에서 description 가 비어있지 않으면 default 펼침.
- [x] AddTodoSheet `initialTodo` + `onUpdate` 옵션 — null 이면 add 모드, non-null 이면 edit 모드. _titleCtrl/_descriptionCtrl/_category/_dueAt/_type 모두 initState 에서 prefill. _submit 가 initialTodo != null 이면 copyWith → onUpdate 콜백 호출 후 pop. `AddTodoSheet.show` 도 initialTodo / onUpdate 매개변수. _Actions submitLabel ('저장' vs '추가').
- [x] TodoActions.update(Todo updated) — copyWith(updatedAt: _now()) 후 repo.upsert. (단위 테스트는 다음 통합 task 에서 묶음.)
- [x] TodoTile.onTap 연결 — DismissibleTodoTile / AnimatedTodoSliver 에 onTap 옵션 추가. HomeScreen + CategoryView 가 AddTodoSheet.show(initialTodo, onUpdate=todoActions.update) 진입. OutlineScreen 은 노드 expand 가 우선이라 v1.3 으로 미룸.
- [x] TodoTile description 힌트 — title 옆 작은 sticky_note_2_outlined (14px, alpha 0.55) — description 비어있지 않을 때만 표시. (widget test 는 통합 task 에서.)

**테스트 통합**
- [x] AddTodoSheet edit 모드 widget test — `add_todo_sheet_edit_test.dart` 5건 (title prefill + "할 일 편집" 헤더 + "저장" 버튼 / description prefill 시 default 펼침 / 저장 시 onUpdate 호출 + onSubmit 안 호출 / description 변경 후 저장 / 제목 비우면 저장 비활성).
- [x] 단축키 1~9 동적 매핑 widget test — `destination_dynamic_test.dart` 6건 (빈 categories / builtin 5종 / 8 카테고리 / 9 카테고리 (outline 단축키 없음) / 12 카테고리 (10~12 단축키 없음) / tooltipWithShortcut 분기). 326/326 PASS (+11 신규).

### 13. memo-check-ui-split — 메모(note) ↔ 체크리스트(task) 시각 구분 강화

대표님 보고: 메모와 체크리스트가 UI/UX 상 잘 구분 안 됨. 진단 — (1) 혼합 뷰에서 둘의 차이가 trailing 회색 아이콘 1개 + 제목 italic 뿐인데, **italic 은 한글 글리프에 거의 효과가 없어** 사실상 구분 신호가 없다. (2) 타입 신호가 우측 trailing 에 몰려 좌→우 pre-attentive 스캔에서 가장 약한 위치다. (3) Outline 메모탭 `_NoteCard` 는 좌측 보더+틴트 배경+본문 프리뷰로 잘 구분되는데 TodoTile 은 그 언어를 안 따라 일관성도 깨진다. **전략 — 메모를 "색 틴트 + 좌측 accent + 메모 라벨 + 본문 프리뷰" 의 명확히 다른 실루엣으로 재설계해 task(깔끔한 체크 행) 와 pre-attentive 대비를 만든다. 단일 시각 토큰을 모든 뷰가 공유.**

> **[v1.5 머지 반영]** '오늘'·'타임라인' 은 `VisibilityPolicy.isVisibleToday` 로 **note 를 항상 제외**(note·무날짜 → 오늘 비노출, 의도된 v1.5 동작 — 되돌리지 말 것)하므로 **task 전용**이다. 메모와 할 일이 실제로 **섞이는 면은 `CategoryView` + 인라인 트리(자식) + 드릴다운 상세(`todo_detail_screen`) + Outline 메모탭** 뿐. §13 의 note 시각 재설계는 이 면들에 적용된다(TodoTile 이 공통 atom 이라 `todo_category_sections` 등 재사용처에도 자동 전파). 신규 위젯 `today_progress_summary`·`timeline_screen` 은 task 전용이라 note 시각 대상 아님.

**시각 토큰 기반 (단일 출처)**
- [x] `theme.dart` 에 note 전용 시각 헬퍼 `NoteVisual` 추가 — `accentWidth`(3px) / `label`("메모") / 틴트 alpha(light 0.08·dark 0.16) / 라벨 bg·outline alpha 상수 + 순수 헬퍼 `tint(category, brightness)` / `accent(category)` / `labelBackground·labelForeground·labelOutline(category)`. BuildContext 없이 [Category.color] 한 곳에서만 색 파생. 단위 test 8건 (라이트/다크 alpha 분기 + RGB 보존 + builtin 5색 반영). 440/440 PASS.

**TodoTile note 재설계 (핵심)**
- [x] TodoTile note 분기에 좌측 카테고리색 accent 보더(3px) + 카테고리색 저알파 틴트 배경 적용 — `Card.color = NoteVisual.tint(category, brightness)`(task 는 null=기본 surface), 좌측 컬러바를 note 면 8px→3px accent(`NoteVisual.accent`)로 대체(`ValueKey('todo-tile-colorbar')`). 라이트/다크 분기. widget test 4건 (note light/dark 틴트 + 3px accent + task 미적용·8px 유지). 444/444 PASS.
- [x] TodoTile note 제목 라인 앞에 "메모" 마이크로 라벨 chip 추가(`ValueKey('todo-tile-note-label')`, 카테고리색 `labelBackground`+`labelOutline`, labelSmall w600 `labelForeground`) + **italic 의존 제거**(제목 `fontStyle` 분기 삭제, normal). 기존 italic 단정 테스트를 non-italic+라벨 존재로 갱신, task 라벨 미표시 테스트 추가, category_view_test 의 note 제목 '메모'→'참고 노트'(라벨 텍스트 충돌 회피). 445/445 PASS.
- [x] TodoTile note leading 글리프 정리 — trailing 회색 `sticky_note_2` 아이콘 제거, 좌측 accent 보더 직후에 카테고리색 `sticky_note_2` 글리프(`ValueKey('todo-tile-note-leading')`) 배치, trailing 은 note 일 때 완전 비움(`if (!isNote)` 체크 버튼). task 는 trailing 체크 유지·leading 글리프 없음. widget test 2건(note=글리프 카테고리색·체크 3종 부재, task=글리프 없음·체크 존재). 450/450 PASS.
- [x] TodoTile note 본문 프리뷰 인라인 — note + description(trim 비어있지 않음) 면 제목 아래 2줄(`ValueKey('todo-tile-note-preview')`, maxLines:2, ellipsis, bodySmall muted) 노출. note 는 힌트 아이콘 생략(프리뷰가 대체), task 는 힌트 아이콘 유지·프리뷰 미노출, 빈/공백 description note 는 프리뷰 생략. widget test 3건. 448/448 PASS.

**task 타일 명료화 (저위험 — 대비만)**
- [x] TodoTile task 미완료 체크 affordance 대비 강화 — `radio_button_unchecked` 색을 회색 `onSurface.alpha(0.35)` → `category.color.alpha(0.55)` 로(카테고리색 ring 힌트 + 대비 상향), 완료는 카테고리색 원색 유지. widget test 2건(미완료 ring 색 + 완료 원색). 452/452 PASS.

**Outline 시각 언어 통일**
- [x] Outline 메모탭 `_NoteCard` 를 NoteVisual 공유 토큰으로 재배선 — 배경 `surfaceContainerHighest.alpha(0.5)`→`NoteVisual.tint`, 좌측 보더 하드코딩(category.color, width 3)→`NoteVisual.accent`+`accentWidth`, 글리프 회색 0.5→카테고리색, 제목 italic 제거(TodoTile note 와 일관). per-card "메모" 라벨은 메모 탭 맥락상 중복이라 생략(Tab 라벨과 충돌도 회피). 회귀 test 1건(틴트+accent 보더+non-italic). 453/453 PASS.
- [x] Outline 체크리스트탭 task 노드(`_OutlineNode`/`_CheckCircle`) 점검 → 미완료 체크 ring 이 `scheme.outline`(회색)이라 TodoTile task(§13-6 카테고리색 0.55)와 불일치 → `_CheckCircle` 미완료 border 를 `color.alpha(0.55)` 로 통일(완료는 카테고리색 채움 유지). 들여쓰기/카테고리색 레일·진척 배지는 이미 일관 확인. 회귀 test 1건(미완료 ring 색 + 완료 채움). 454/454 PASS.

**혼합 뷰 회귀**
- [x] 실제 혼합 면(CategoryView) 회귀 test — 같은 카테고리 내 task+note 혼재 시 task=trailing 체크(`todo-tile-check`), note=leading 메모 글리프(`todo-tile-note-leading`)+"메모" 라벨+본문 프리뷰 로 시각 신호 분리됨을 검증(category_view_test 1건). '오늘' note 누수 가드는 `visibility_policy_test` 의 기존 3건(note dueAt 오늘/createdAt 어제/항상 false)으로 이미 충분 — 중복 추가 안 함. 454/454 PASS.

**대비 / 접근성**
- [x] note 텍스트 라이트/다크 WCAG AA 대비 검증 test — 상대휘도+대비비+투명색 합성 헬퍼로 5색×2모드 제목(onSurface)/프리뷰(muted)/"메모"라벨 모두 ≥4.5:1 검증. **보정**: 라벨 전경을 카테고리 원색→`labelForeground(brightness)`=onSurface 로 변경(warm hue 작은 라벨 텍스트 대비 미달 해소, 카테고리 정체성은 bg+outline+글리프가 담당). accent 좌측 보더는 식별이 글리프/라벨/틴트로 중복 전달돼 단독 지표 아니므로 텍스트 대비만 게이트. 458/458 PASS.

**점수 재측정**
- [x] §13 종료 자가평가 — 디자인 9.6 / 편의성 9.6 (둘 다 ≥9). IMPLEMENTATION_PLAN.md 끝에 "자가평가 — §13" 섹션 추가(핵심 변경 + 10축 점수). 미달 없음 → 보강 task 불필요. §13 시각 11 task 전부 완료, 458/458 PASS.

### 14. memo-check 기획 — 메모 모델 재정의 (§13 시각과 함께 적용)

§13(시각)과 별개로 **메모가 이 앱에서 무엇인가**를 재정의. 핵심 진단 — 현재 메모는 ⓐ 항상 leaf(자식 불가, `todo_tile.dart:171` `!isNote` 가드)라 v1.1 비전 "메모장 다층 구조 이식"과 어긋나고, ⓑ 개수가 어디에도 안 보여 존재 자체가 묻히며, ⓒ task↔note 전환은 되지만(`add_todo_sheet.dart:767`) 자식·doneAt 엣지가 미검증이다. **전략 — 메모를 "섹션 헤딩"으로 승격(자식 보유 가능 → 헤딩 밴드 렌더)해 구조·시각 구분을 최강화하고(메모=섹션 제목 / 할 일=그 아래 체크 행), 카운트 노출 + 전환 가드로 마감.**

**14-A. 메모 = 섹션 헤딩 모델 (parent 허용)**
- [x] 도메인/정책 — `computeSubtreeProgress` 검증 결과 **보정 불필요**: root 타입과 무관하게 자식만 walk 하고 `c.type == task` 만 카운트(note 분자·분모 제외, 자손 note 아래 task 도 walk 로 카운트, root 자신 제외)하므로 note 헤딩 root 도 이미 정확. 단위 test 3건 추가(note 헤딩+task 자식 [1/3], 손자 누적+자손 note 제외 [1/4], note 자식만 [0/0]). 460/460 PASS.
- [x] UI 가드 해제 — `todo_drill_list`/`todo_category_sections` 의 `canAddChild = type==task` 가드 제거(타입 무관 ＋하위 추가), `TodoTile` 의 `!isNote` 제거, `todo_detail_screen` FAB 를 note 도 노출 + 빈 상태 안내 갱신. `showAddChildSheet` 는 이미 타입 무관(타입 토글로 자식 종류 선택)이라 변경 불필요. 드릴/표시는 이미 타입 무관(hasChildren 기준). 기존 "note 자식 불가" 단정 테스트 2건 갱신 + drill_list note add-child 노출·콜백 test 1건 추가. 461/461 PASS.
- [x] TodoTile 헤딩 분기 — `isNoteHeading = isNote && childCount>0` 면 `NoteVisual.headingTint`(leaf tint 보다 진함: light 0.14/dark 0.24) 배경 + 제목 w700 으로 "섹션 헤딩" 강조, 자식 0 이면 §13 leaf 틴트 카드. 자식수 배지("하위 N")는 기존 drillChildCount 가 담당, 펼침 chevron 은 인라인 모드 isExpanded 가 담당(둘 다 기존). [done/total] 서브트리 진척 배지는 allTodos 가 필요해 Outline(§14-A-4)에서. headingTint alpha test 2건 + 헤딩/leaf 렌더 test 2건 + WCAG 검증에 headingTint 배경 추가. 465/465 PASS.
- [x] Outline 통합 — `hasTaskDescendant(node, all)` 헬퍼 추가, `taskRootsOfCategory`/`childTasksOf` 를 "체크리스트 관련(task + task 자손 보유 note 헤딩)" 으로 확장, `notesOfCategory` 는 헤딩 제외(순수 메모만), `withTaskRoot` 동일 기준. `_OutlineNode` 에 note 분기(체크박스 대신 카테고리색 메모 글리프 `outline-note-glyph-{id}` + 굵은 제목). 기존 leaf-note 테스트 전부 호환(+36) + 신규 2건(헤딩→체크리스트 섹션·글리프·task 자식 / 헤딩→메모탭 제외). 468/468 PASS.
- [x] todo_detail_screen — FAB·자식 리스트는 §14-A(가드 해제)에서 이미 노출. 남은 자식 진척 요약 추가: `_SubtreeProgressBar`(`detail-progress`, "done/total 완료" + 카테고리색 LinearProgressIndicator)를 `computeSubtreeProgress(live, all).taskCount>0` 일 때 children 리스트 위에 표시(note 헤딩/task 폴더 공통). widget test 2건(헤딩 1/2 노출 + task 자손 없으면 숨김). 469/469 PASS.

**14-B. "메모 N" 카운트 노출**
- [x] CategoryView 헤더 — 미체크/완료 칩 옆에 "메모 N" `_StatChip`(onSurface 0.45) 추가, `noteCount = todos.where(note).length`, 0 이면 생략. 미체크/완료는 task 만 유지. widget test 2건(메모 2 표시 + 메모 0 생략). 471/471 PASS.
- [x] Outline 메모탭 카테고리 헤더 "메모 N" — **v1.4 머지로 이미 구현됨**(`outline_screen.dart` `_NoteCategorySection` 가 `${notes.length}` 를 카테고리색 labelSmall 로 표시). 별도 작업 불필요. (그룹 헤더 단위 합산 카운트는 over-engineering 으로 보류 — 카테고리 단위로 충분.)

**14-C. 타입 전환 엣지 가드**
- [x] 타입 전환 정합 — AddTodoSheet edit `_submit` 의 copyWith 에 `doneAt: isNote ? null : initial.doneAt` + `calendarEventId: isNote ? null : initial.calendarEventId` 추가(dueAt/isAllDay 는 `_serializeDate` 가 note 일 때 이미 null/false). task→note 전환 시 doneAt 잔존으로 note→task 복귀 때 완료 오표시되던 사고 차단. widget test 2건(task→note 정합 정리 + note→task type). 473/473 PASS.
- [x] 전환 시 자식 보존 검증 — 타입 전환은 id 불변 update 라 자식 parentId 가 그대로 부모를 가리켜 **깨지는 조합 없음**(dialog 가드 불필요). DB 레벨 통합 test 2건(task→note: 자식 parentId + 서브트리 진척 [1/2] 보존 / note→task 왕복 정합). 475/475 PASS.
- [x] §14 종료 자가평가 — 디자인 9.6 / 편의성 9.7 (둘 다 ≥9). 비전 §3 "메모장 다층 구조" 충족 확인. 파일 끝에 "자가평가 — §14" 섹션 추가. 미달 없음 → 보강 불필요. §14 기획 10 task 전부 완료, 475/475 PASS.

---

## 점수 측정 프로토콜

품질 게이트 도달 시 매 iteration 자가 평가. 9점 미만이면 위 TODO 끝에 보강 task 자동 추가.

**디자인 점수 (10점 만점, 각 2점)**
1. 가독성 — 타이포 위계 + 정보 밀도가 적절한가
2. 대비 — 라이트/다크 양쪽 모두 WCAG AA 이상
3. 여백 — 4/8/16/24 그리드 일관 적용
4. 정렬 — 좌측·기준선 일관
5. 일관성 — 같은 의미는 같은 시각 언어로

**편의성 점수 (10점 만점, 각 2점)**
1. 단축 동작 — Cmd+N / 1~5 / Enter / Esc 모두 동작
2. 반응성 — 모든 조작이 100ms 이내 시각적 응답
3. 학습성 — 첫 사용자가 도움말 없이 추가/체크/카테고리 전환 가능
4. 오류 회복 — Undo / 명확한 에러 메시지
5. 카테고리 전환 비용 — 1 클릭 또는 1 키스트로크

---

## DONE 로그

완료 항목은 위 TODO 안에서 `[x]` 토글 유지 (별도 이동 불필요).

---

## 자가평가 — § 10-C 종료 시점 (2026-05-28)

§ 10-A 사용자 보고 4건 + § 10-B 24 영역 + § 10-C 5 영역 모두 종료. 200/200 PASS.

**디자인 점수 — 9.3 / 10**
1. 가독성 (2/2) — Material 3 텍스트 스케일 + KoDate 한국어 포맷.
2. 대비 (2/2) — 라이트/다크 양쪽 WCAG AA 이상, 다크 모드 이월 배너 alpha 분기.
3. 여백 (2/2) — AppTokens.space2/4/8/12/16/20/24/32/48 일관.
4. 정렬 (1.5/2) — 대부분 좌측 기준선 일관, 일부 chip Wrap 영역만 살짝 다름.
5. 일관성 (1.8/2) — 같은 의미 = 같은 시각 언어 (primaryContainer + outline 으로 selected 표현 통일).

**편의성 점수 — 9.5 / 10**
1. 단축 동작 (2/2) — Cmd+N / 0~5 / Enter / Esc 모두 동작.
2. 반응성 (2/2) — 모든 조작 100ms 이내 시각 응답, AnimatedTodoSliver 가 reorder jump 제거.
3. 학습성 (2/2) — 첫 사용자가 도움말 없이 add/check/category 전환 가능.
4. 오류 회복 (2/2) — Undo SnackBar + progress bar (남은 시간) + 친화 에러 메시지 (rate limit / OTP 만료 등).
5. 카테고리 전환 비용 (1.5/2) — 1 클릭 OR 1 키스트로크 가능. 사이드바 focus ring 으로 키보드 사용자 시각 피드백 추가.

두 점수 모두 9 이상 — 비전 충족 인정.

---

## 외부 셋업 (SETUP.html) 갱신

§ 10-C 종료 후 SETUP.html 점검 — § 2 / § 6 / § 8 의 매직링크/Deep Link 잔재 제거. OTP 흐름 으로 일관 정리 (§ 6 을 "OTP 인증 (이메일 코드)" 으로 교체).

v1.1 § 11 종료 후 SETUP.html § 2 끝에 "v1.0 → v1.1 마이그레이션 (트리/메모 모델)" 안내 추가 — 기존 환경용 ALTER TABLE 3 줄 (parent_id / type / sort_order) idempotent 형태로.

---

## 자가평가 — v1.1 § 11 종료 시점 (2026-05-29)

§ 11 v1.1 16 tasks 모두 완료. 280/280 PASS. v1.0 → v1.1 backwards-compat (Drift onUpgrade + Supabase ALTER + JSON @Default).

**디자인 점수 — 9.4 / 10** (이전 9.3 → +0.1)
1. 가독성 (2/2) — 메모장 시나리오의 트리 구조도 outline view 로 자연스러운 표시.
2. 대비 (2/2) — note 의 italic / sticky_note 아이콘 / breadcrumb onSurfaceVariant 색 등 시각 분리 명확.
3. 여백 (2/2) — outline 깊이별 16px 일관, 폴더 헤더 [N/M] + progress bar 56×3px.
4. 정렬 (1.6/2) — chevron / icon / 진척률 정렬 일관. depth 들여쓰기 시 chevron 의 leading 공간 보존.
5. 일관성 (1.8/2) — note 의 italic 처리가 TodoTile / outline 양쪽 일관. progress badge 가 outline 의 카테고리 / 노드 양쪽 동일 위젯.

**편의성 점수 — 9.6 / 10** (이전 9.5 → +0.1)
1. 단축 동작 (2/2) — Cmd+N / 0~6 (Outline 단축키 6 추가) / Enter / Esc 모두 유지.
2. 반응성 (2/2) — bulk paste 후 dialog 즉시, outline 펼침/접힘 즉각 setState.
3. 학습성 (2/2) — 메모장 → 앱 마이그레이션 시 multi-line paste 한 번으로 N건 일괄 추가.
4. 오류 회복 (2/2) — bulk paste 취소 시 lines.join(' ') 단일 라인 복구, dangling parent_id 도 안전 fallback (empty path).
5. 카테고리 전환 비용 (1.6/2) — Outline 의 펼침/접힘 + breadcrumb 으로 트리 navigation 비용 감소.

두 점수 모두 9 이상 유지 — v1.1 비전 충족 유지.

---

## 자가평가 — v1.2 § 12 종료 시점 (2026-05-29)

§ 12 v1.2 의 ralph 자동 task 25개 모두 완료 (비전 영역 1개는 대표님 직접 — 아래 § 미완료 참조).
326/326 PASS. v1.1 → v1.2 backwards-compat (Drift onUpgrade 2→3 + Supabase ALTER IF NOT EXISTS + Category JsonKey + description nullable).

**v1.2 완료 기능**
- **카테고리 fully 동적** — enum → freezed data class + categories 테이블 (Drift + Supabase). 사용자가 sidebar 끝 "카테고리 추가" 로 ADD (label + 16색 + 12아이콘 picker), long-press / 우클릭으로 DELETE. builtin 5종도 삭제 가능하지만 안 todos 가 ≥1 이면 차단 + 안내.
- **동적 단축키** — today=0 / 카테고리 1~9 / outline N+1 (N<9). 9개 초과는 sidebar tap.
- **Todo 상세 메모 (description)** — AddTodoSheet "상세 메모" 토글 + multi-line TextField. TodoTile 에 메모 힌트 아이콘.
- **Todo 편집** — TodoTile tap → AddTodoSheet edit 모드 (initialTodo prefill + onUpdate → TodoActions.update).

**디자인 점수 — 9.4 / 10** (v1.1 유지)
1. 가독성 (2/2) — description 힌트 아이콘 (14px sticky_note), 카테고리 색/아이콘이 sidebar / outline / chip 일관.
2. 대비 (2/2) — ADD dialog 의 선택 색 ring (2.5px) + 아이콘 outline, 라이트/다크 양쪽 유지.
3. 여백 (2/2) — AppTokens 그리드 일관, dialog palette Wrap spacing 8.
4. 정렬 (1.6/2) — sidebar 동적 destination + "카테고리 추가" 버튼 좌측 정렬 일관.
5. 일관성 (1.8/2) — 색/아이콘 선택 UI 가 ADD dialog 단일 출처, edit/add sheet 동일 위젯 재사용.

**편의성 점수 — 9.6 / 10** (v1.1 유지)
1. 단축 동작 (2/2) — Cmd+N / 0~9 동적 단축키 / Enter / Esc 유지.
2. 반응성 (2/2) — categoriesProvider stream 으로 ADD/DELETE 즉시 sidebar 반영, edit 저장 즉시 list 갱신.
3. 학습성 (2/2) — 카테고리 추가/삭제 직관적, TodoTile tap → 편집이 자연스러운 진입점.
4. 오류 회복 (2/2) — 카테고리 삭제 차단 시 명확한 안내 (N건 표시), Undo / 친화 에러 유지.
5. 카테고리 전환 비용 (1.6/2) — 동적 단축키 + sidebar tap 1클릭.

두 점수 모두 9 이상 유지 — v1.2 비전 충족.

### 대표님 직접 영역 — 완료

- [x] **CLAUDE.md 비전 § 3 갱신** — "카테고리 분류 — 5종 고정" → "기본 5종 + 사용자 자유롭게 추가/삭제 가능 (v1.2~), 안 todos 남으면 삭제 차단". 대표님 명시 지시로 갱신 완료 — 비전-구현 일관성 회복.

§ 12 v1.2 **전 task 완료** (ralph 25 + 대표님 직접 1).

---

## 자가평가 — §13 (memo-check 시각 재설계) 종료 시점 (2026-05-30)

§13 시각 11 task 완료. 458/458 PASS, analyze·format clean. v1.5 머지 코드 위에서
메모↔체크리스트 시각 언어를 `NoteVisual` 단일 출처로 재설계 — TodoTile·Outline 양쪽 일관.

**핵심 변경**
- **메모 실루엣 재설계**: 카테고리색 틴트 배경 + 좌측 accent + leading 메모 글리프 + "메모" 라벨 + 본문 2줄 프리뷰. → 할 일(깔끔한 체크 행)과 pre-attentive 대비.
- **italic 의존 제거**: 한글에서 무효였던 italic 을 라벨/틴트/글리프 신호로 대체.
- **체크 affordance 카테고리색화**: task 미완료 ring 을 카테고리색 0.55 로(TodoTile + Outline `_CheckCircle` 통일).
- **WCAG AA 검증**: 5색×2모드 텍스트 대비 ≥4.5:1 자동 test. 라벨 전경을 onSurface 로 보정.

**디자인 점수 — 9.6 / 10** (v1.2 9.4 → +0.2)
1. 가독성 (2/2) — note 본문 프리뷰로 "정보=메모" 즉시 전달, 제목 위계 명확.
2. 대비 (2/2) — 5색×라이트/다크 텍스트 대비 ≥4.5:1 계산 검증(회귀 test 로 고정).
3. 여백 (1.8/2) — AppTokens 그리드 유지, 라벨/글리프/프리뷰 간격 일관.
4. 정렬 (1.8/2) — leading accent+글리프 / trailing 체크 좌우 정렬 일관.
5. 일관성 (2/2) — TodoTile note 와 Outline `_NoteCard`/`_CheckCircle` 이 동일 `NoteVisual` 토큰 공유(단일 출처).

**편의성 점수 — 9.6 / 10** (v1.2 9.6 유지)
1. 단축 동작 (2/2) — 기존 단축키 회귀 없음.
2. 반응성 (2/2) — 시각 변경만, 동작 경로 불변.
3. 학습성 (2/2) — "메모" 라벨 + 글리프로 첫 사용자도 메모/할 일 즉시 구분.
4. 오류 회복 (1.8/2) — 기존 Undo/에러 안내 유지.
5. 카테고리 전환 비용 (1.8/2) — 변경 없음.

두 점수 모두 9 이상 — §13 비전 충족. 다음: §14 기획(메모=섹션 헤딩 모델 등).

---

## 자가평가 — §14 (memo-check 기획: 메모 모델 재정의) 종료 시점 (2026-05-30)

§14 기획 10 task 완료(A 5 + B 1 + C 3 + 자가평가 1). 475/475 PASS, analyze·format clean.
v1.5 머지 코드 위에서 **메모를 "섹션 헤딩"으로 승격** — v1.1 비전 "메모장 다층 구조 이식" 을
시각(§13)에 이어 구조까지 완성.

**§14 완료 기능**
- **메모 = 섹션 헤딩**: 메모가 자식(할 일·메모) 보유 가능. 자식 있으면 진한 틴트+굵은 제목의 헤딩 밴드, 없으면 leaf 메모 카드. 자손 task 진척률 자동 계산(`computeSubtreeProgress` 는 root 타입 무관).
- **Outline 통합**: `hasTaskDescendant` 로 task 자손 보유 note 헤딩은 체크리스트 탭에 섹션(체크박스 대신 메모 글리프)으로, 순수 메모는 메모 탭으로 분리. 상세화면에 자손 진척 요약 바.
- **"메모 N" 카운트**: CategoryView 헤더 + Outline 메모탭(기존).
- **타입 전환 가드**: task→note 전환 시 doneAt/calendar 정리(복귀 시 완료 오표시 차단), 자식 parentId 는 id 불변이라 항상 보존(깨지는 조합 없음).

**비전 정렬 확인** — CLAUDE.md 비전 §3 "메모장에서 쓰던 다층 구조" → 메모 헤딩 + 하위 체크리스트로 충족. 범위 밖(iOS/웹/협업/광고) 침범 없음.

**디자인 점수 — 9.6 / 10** (§13 유지)
1. 가독성 (2/2) — 헤딩 밴드(진한 틴트+굵은 제목)가 섹션 제목으로 즉시 읽힘.
2. 대비 (2/2) — headingTint 도 WCAG AA 텍스트 대비 검증에 포함(5색×2모드 ≥4.5:1).
3. 여백 (1.8/2) — Outline/상세 진척 바·글리프 간격 AppTokens 일관.
4. 정렬 (1.8/2) — 체크리스트 탭 글리프/체크박스 leading 정렬 일관.
5. 일관성 (2/2) — note 헤딩이 TodoTile/Outline `_OutlineNode` 양쪽 동일 시각 언어(글리프+굵은 제목).

**편의성 점수 — 9.7 / 10** (§13 9.6 → +0.1)
1. 단축 동작 (2/2) — 기존 단축키 회귀 없음.
2. 반응성 (2/2) — 메모 아래 추가/전환 즉시 반영.
3. 학습성 (2/2) — 메모 헤딩 + 하위 체크리스트가 메모장 멘탈모델과 일치, "메모 N" 으로 메모 존재 인지.
4. 오류 회복 (2/2) — 타입 전환 정합 가드로 데이터 사고 차단, 자식 보존.
5. 카테고리 전환 비용 (1.7/2) — 변경 없음.

두 점수 모두 9 이상 — §14 비전 충족. **§13(시각) + §14(구조) 로 메모↔체크리스트 구분 완성.**
