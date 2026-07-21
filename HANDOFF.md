# HANDOFF — 다음 세션 (fresh context) 진입용

> ralph 자동 루프 + 사람 reader 모두 이 파일 하나로 컨텍스트 복원 가능하게 작성.
> 매 iter 시작 시 CLAUDE.md / PROMPT.md / IMPLEMENTATION_PLAN.md 와 함께 이 파일도 읽는다.
> 마지막 업데이트: **2026-07-18 (진행중 3-상태 — 완료 체크 옆 세모(진행중) 버튼 + 완료율 링 진행중 세그먼트 + 카테고리 미완료/진행중/완료 3칩. drift v8→9 started_at)**

---

## 0. Goal (현재 무엇을 만들고 있나)

**Solo Todo** — 대표님(30대 개발자, 1인 사용) 전용 macOS desktop + Android 통합 Todo 앱.

- **Flutter (Dart)** 단일 코드베이스, **Supabase** 백엔드 (Auth + Postgres + RLS + Realtime), **Google Calendar API** 연동.
- 비전: 메모장 대체. UI 가독성 최강 + UX 단축 동작 강력. v1.0.0 한 번에 완성품.
- 자가평가 기준: 디자인 점수 + 편의성 점수 모두 9/10 이상.

세부 비전은 `CLAUDE.md` 의 "비전 / 사양" 8 섹션 참조.

---

## 1. Current Progress (어디까지 왔나)

### 완료 단계

| 단계 | 상태 | 메모 |
|------|------|------|
| **v1.0.0 — 9 phase / 45 task** | ✅ 종료 (`087c761`) | 첫 PROJECT_DONE |
| **§ 10 — 사용자 실사용 보고 + 코드 재검토 보강 (33 task)** | ✅ 종료 (`e16bd68`) | 디자인 9.3 / 편의성 9.5 |
| **§ 11 — v1.1 폴더/Outline 트리/bulk paste/메모 타입 (16 task)** | ✅ 종료 (`13b895a`) | 디자인 9.4 / 편의성 9.6 |
| **§ 12 — v1.2 카테고리 fully 동적 + Todo description (25 ralph task)** | ✅ 종료 (`6e88d80`) | 디자인 9.4 / 편의성 9.6. CLAUDE.md § 3 갱신까지 완료 (`9694a81`) |
| **v1.2 후속 — 실사용 버그수정 라운드** | ✅ 종료 (`6ffe62f`) | 아래 "후속 수정 내역" 참조. 대표님 실기기(맥+갤S24) 검증 중 발견된 8건 |
| **fast-tasks — 날짜·기간 모델 + 그룹 계층 + Android 캘린더 권한 (5 task)** | ✅ 종료 (`167415d`) | 아래 "fast-tasks 내역" 참조. **DB 스키마 변경됨 → Supabase schema.sql 재실행 필요 + Google Console 설정 필요** |
| **배치2 — 중첩 체크리스트 + 모바일 관리 + 정렬 + 전체보기 탭 + 카테고리 동기화 (`ca27c79`)** | ✅ 종료 | 402/402 PASS. **스키마 변경 없음**. 아래 "배치2 내역" 참조. 카테고리/그룹 cross-device 동기화 버그 수정 포함 |
| **브랜딩 — 앱 이름 '하루' + 볼드 체크 아이콘 + macOS 로그인 자동실행 토글** | ✅ 종료 | 561/561 PASS. **스키마 변경 없음**. 아래 "브랜딩 내역" 참조. 대표님 직접 요청(아이콘·이름·자동실행) |
| **진행중 3-상태 — 완료 체크 옆 세모(진행중) 버튼 (2026-07-18)** | ✅ 종료 | 602/602 PASS. **DB 스키마 변경됨 (drift v8→9 `todos.started_at`) → Supabase schema.sql 재실행 필요.** 아래 "진행중 3-상태 내역" 참조. 대표님 직접 요청 |

### 현 상태 (2026-06-06)

- main branch
- analyze clean / format clean / **flutter test 561/561 PASS** / **macOS 디버그 빌드 성공**
- **데스크탑 ↔ 폰 Supabase 동기화 정상 작동 확인됨** (대표님 실기기에서 검증 완료)
- 갤럭시 S24 (SM S921N) 에 release APK 설치 완료

### 진행중 3-상태 내역 (완료 체크 + 진행중 세모) — 2026-07-18

대표님 직접 요청: "체크리스트에 체크만 있는 게 아니라 진행중 세모 버튼". 미완료 / **진행중** / 완료 3-상태.

- **상태 모델**: `doneAt` 과 짝이 되는 `Todo.startedAt`(nullable timestamp) 신설. **불변식: startedAt/doneAt 동시 세팅 금지** — 미완료(둘 다 null) / 진행중(startedAt만) / 완료(doneAt). `isDone` 은 그대로 doneAt 기반이라 **이월·오늘노출·완료접기 정책은 무손상**(진행중은 자동으로 "미완료"처럼 이월·표시). `isInProgress` getter + `toggleInProgress()` 신설. **완료 시 startedAt 제거**(완료=진행중 아님), 진행중 토글 시 doneAt 해제.
- **조작 UI**: 완료 체크(원) **왼쪽에 세모(진행중) 버튼** — 탭=진행중 토글. `InProgressTriangle` 위젯(`lib/src/ui/widgets/in_progress_triangle.dart`, CustomPaint 세모). TodoTile / 아웃라인 _OutlineNode / 상세 AppBar / 타임라인 타일 4곳. `onToggleInProgress` 는 **nullable(선택)** 로 배선 — note 및 미지원 화면은 세모 미표시.
- **문구/카운트**: 오늘 상단 링 = **완료만 진하게 채움 + 진행중은 옅은 세그먼트**(대표님 확정) + "남은 N개 · 진행중 M". 타일은 진행중이면 제목 아래 "진행중" 라벨. 카테고리 헤더 = 미완료/진행중/완료 3칩(Wrap). 트레이 "미체크 N" 은 진행중 포함 유지(안 끝남).
- **DB**: drift **schemaVersion 8→9** (`todos.started_at`, PRAGMA 가드 idempotent). Supabase `schema.sql` §21 `add column if not exists started_at`. remote 매핑(`started_at`) + 옛 스키마 null fallback. LWW 는 updatedAt 기반이라 그대로.
- **검증**: analyze 0 / format 0 / **flutter test 602/602 PASS** (신규: todo_test 진행중 그룹 11 + todo_tile_test 세모 6 + category chip 라벨 갱신).
- ⚠️ **대표님 액션**: `make sql` → Supabase SQL Editor 재실행(started_at 컬럼 + notify pgrst). 미실행 시 진행중 상태가 기기 간 동기화에서 PGRST204/누락. + 폰 재빌드(`make build-apk`).

### 브랜딩 내역 (앱 이름 + 아이콘 + 자동실행) — 2026-06-06

- **앱 이름 → '하루'** (대표님 확정, 순우리말): macOS `CFBundleName`/`CFBundleDisplayName` 리터럴 + 창 제목(Swift `self.title`), Android `android:label`, Dart 브랜드 문자열(app/app_shell 사이드바/sign_in/tray/calendar 이벤트 설명). **번들 ID(`com.goldenplanet.soloTodo`)·Android applicationId(`com.goldenplanet.solo_todo`)·Supabase 스키마명(`solo_todo`)은 의도적으로 유지** — OAuth/동기화 연동 키라 변경 금지. macOS PRODUCT_NAME 은 ASCII `haru` (2026-06-06 `solo_todo`→`haru` 변경) → 번들 `haru.app` / 실행파일 `haru` (ASCII 라 코드서명 안전), 사용자 표시명만 한글 '하루'. **PRODUCT_NAME(번들 파일명)은 ASCII 면 자유롭게 바꿔도 안전** — 단 번들 ID·URL 스킴·Supabase 스키마는 절대 유지.
- **아이콘 → 볼드 체크마크**: `assets/branding/app_icon_source.png`(1024, Chrome 헤드리스로 투명 PNG 렌더) 교체 + `dart run flutter_launcher_icons` 재생성(macOS appiconset + Android adaptive). `adaptive_icon_background` `#5B4BE8`→`#7C3AED`.
- **macOS 로그인 시 자동 실행 (기본 꺼짐)**: `SMAppService`(macOS 13+) 메서드 채널 `app.haru/launch_at_login`(네이티브 `macos/Runner/MainFlutterWindow.swift`), Dart `LaunchAtLoginService` + `SettingsSheet`(데스크탑 토글). 진입점: 데스크탑 사이드바 톱니 / 모바일 앱바 톱니. **주의: 로그인 아이템 실제 등록은 정식 서명 빌드(/Applications 설치 권장)에서만 안정적, 디버그 `flutter run`에선 미반영 가능.** 신규 `lib/src/features/settings/`.

### 배치2 내역 (중첩/모바일/정렬/탭/동기화) — `docs/features/2026-05-30-nested-mobile-sort-outline/`

- **하위 체크리스트(C)**: 각 task 에 `＋ 하위 추가`(parentId 자식 생성), 오늘/카테고리 목록을 **들여쓰기 중첩 트리(접힘)** 로. 신규 `nested_todo_tree.dart`.
- **정렬(B)**: 기본 **최신순**(`sortOrder asc, updatedAt desc`). 불변식 **작은 sortOrder = 위**. 생성·시트편집 → `min-1`(맨 위), **toggle 은 sortOrder 불변**. 길게 눌러 **형제 드래그** 재정렬(`reorderSiblings`).
- **모바일 관리(A·E·F)**: 상단 ☰ → **ManageDrawer**(그룹/카테고리 추가·삭제·이동). 카테고리 **드래그로 그룹 이동**, 소속 그룹 chip 표시.
- **추가 UX(I·J)**: 카테고리 추가 시 그룹 chip 선택. **`Category.daily` 하드코딩 기본값 제거** → 오늘/전역 추가는 categoriesProvider 첫 항목. AddTodoSheet 카테고리 칩 그룹별 묶음.
- **전체보기(D·G)**: **[체크리스트]/[메모] 탭** 분리. 네비 순서 **오늘 → 전체보기 → 카테고리**(데스크탑·모바일). 단축키 today=0/outline=1/카테고리 2~9.
- **모바일 하단 바**: `[오늘, 전체보기, 카테고리]` 3슬롯 고정. '카테고리' 슬롯 = Drawer open(가상 인덱스 2). Drawer 카테고리 **탭=이동 / long-press=메뉴**.
- **카테고리·그룹 cross-device 동기화(`37febeb`)**: 기존엔 realtime sync 가 todos 만 구독해 카테고리/그룹이 **push-only(다른 기기로 안 내려옴)** 였음 → "카테고리 변경 안 먹힘"의 원인. `SupabaseRealtimeSync` 에 categories/groups 채널 + fetchAll 추가.

### fast-tasks 내역 (날짜·기간 + 그룹 + 캘린더 권한)

Socratic 확정 1A/2A/3A/4B. 명세: `docs/features/2026-05-29-fast-tasks-date-and-grouping/date-and-grouping-tasks.md`. **make check 379/379 PASS.**

1. **날짜·기간 모델** (Task 4·5·1) — Todo 에 `endAt`/`isAllDay`/`timeAnchor` 추가(`dueAt` 앵커 유지). AddTodoSheet 4 모드(하루종일/시작시간/마감시간/기간). **하루종일은 00:00 표시 안 함**(Task 1). 기간은 시작~종료 각각 시간 선택. schemaVersion **4→5**.
2. **캘린더 종류별 매핑** (Q3=A) — 하루종일→Google 종일 이벤트, 시간모드→1시간, 기간→start~end. `calendar_service.dart` buildEvent.
3. **Android Google Calendar 권한** (Task 3) — `google_sign_in` 7.x 는 인증≠인가. 기존 `authenticate()` 만 호출해 calendar scope 가 한 번도 부여 안 됨이 근본 원인. `authorizeScopes` 증분 동의 흐름 추가 + Android 는 initialize 에 clientId 미전달로 분기. (`google_auth_service.dart`)
4. **그룹 계층** (Task 2, Q1=A) — 카테고리 위 '그룹(큰분류)' 신설. 그룹>카테고리>todo 트리. Group freezed + Drift `Groups` 테이블 + `Categories.groupId` + groups_dao/api/repo(outbox `grp-*`)/controller/AddGroupDialog. 사이드바 그룹 헤더(접힘) + '미분류' 섹션 + 카테고리 우클릭 '그룹 이동'. **그룹 삭제 시 속한 카테고리는 미분류로 이동(무손실)**. schemaVersion **5→6**(병합 시 재배치).

**모바일 한계**: 그룹 UI 는 데스크탑 사이드바 전용. Android NavigationBar 는 평면 유지.
**그룹 동기화**: 카테고리와 동일하게 outbox push 단방향(realtime 구독은 todos 만).

### v1.2 후속 — 실사용 버그수정 내역 (직전 라운드)

1. `35dc658` AddTodoSheet 상세 메모 펼침 시 bottom overflow → SingleChildScrollView 로 감쌈
2. `166bfcb` 앱 아이콘 (체크리스트 squircle) macOS + Android — `flutter_launcher_icons`, 소스 `assets/branding/app_icon_source.png`
3. `f757c8a` AddTodoSheet 카테고리 칩이 동적 목록 미반영 + 선택 표시 안 됨 → categoriesProvider watch + **id 기준** 비교 + post-frame 자동 보정
4. `26ad27d` 사용자 추가 카테고리(`cat-...`) todo 읽기 크래시 (`Unknown category id`) → **TodosDao 가 categories 와 left-join** 해서 복원, 미지 id 는 placeholder
5. `121995a` schemaVersion 3→4 — v3 마이그레이션에 description 을 넣으며 버전을 안 올려 "description 없는 v3 DB" 발생 → PRAGMA 가드로 보강
6. `5af9228` `--no-tree-shake-icons` — 동적 카테고리 IconData(codepoint) 가 non-const 라 release 빌드 실패 → Makefile 전체 반영
7. `b246b64` **schema.sql 의 parent_id/type/sort_order ALTER 활성화** — `create table if not exists` 가 기존 테이블이면 스킵 → 컬럼 미추가 → PGRST204 무한 재시도의 진짜 원인. ALTER 주석 해제 + `notify pgrst 'reload schema'` 추가
8. `6ffe62f` 모바일 FAB 가 하단 네비 가림 (endContained) → **endFloat + 원형 FAB** / Outline 하위 트리 **체크 토글** 활성화

### ⚠️ 이번 라운드 사고 기록 (반드시 읽을 것)

**로컬 DB 삭제로 미동기화 데이터 1회 유실.** 동기화가 깨진 상태(아래 § 2 참조)에서 데스크탑 todo 가 로컬에만 있었는데, "오늘 화면 못 불러옴" 버그(#5) 수정 과정에서 `solo_todo.sqlite` 를 **백업 없이 삭제**해 유실. 이후 재입력분은 `~/solo_todo_db_backup/` 에 백업 후 schema.sql 수정(#7)으로 동기화 복구함.
→ **교훈: DB 파일/데이터를 건드릴 땐 반드시 먼저 `cp` 백업.** (§ 6 함정에 추가)

### v1.2 완료 기능 (참고)

- **카테고리 fully 동적**: enum → freezed data class + Drift/Supabase categories 테이블. sidebar "카테고리 추가" (label+16색+12아이콘) / long-press·우클릭 삭제. builtin 도 삭제 가능 (안 todos ≥1 이면 차단).
- **동적 단축키**: today=0 / 카테고리 1~9 / outline N+1 (N<9). 9 초과는 tap.
- **Todo description**: AddTodoSheet "상세 메모" 토글 + multi-line. TodoTile 힌트 아이콘.
- **Todo 편집**: TodoTile tap → AddTodoSheet edit 모드 (initialTodo prefill + onUpdate → TodoActions.update). HomeScreen / CategoryView 연결.
- **Outline 체크**: 하위 트리(자식) 노드까지 체크 토글 (`6ffe62f`).

### v1.2 완료 기능 (참고)

- **카테고리 fully 동적**: enum → freezed data class + Drift/Supabase categories 테이블. sidebar "카테고리 추가" (label+16색+12아이콘) / long-press·우클릭 삭제. builtin 도 삭제 가능 (안 todos ≥1 이면 차단).
- **동적 단축키**: today=0 / 카테고리 1~9 / outline N+1 (N<9). 9 초과는 tap.
- **Todo description**: AddTodoSheet "상세 메모" 토글 + multi-line. TodoTile 힌트 아이콘.
- **Todo 편집**: TodoTile tap → AddTodoSheet edit 모드 (initialTodo prefill + onUpdate → TodoActions.update). HomeScreen / CategoryView 연결 (OutlineScreen tap-edit 은 v1.3).

### v1.1 완료 기능 (참고)

- **트리 구조**: todo 에 parent_id 추가, 무한 깊이 자식 가능 (메모장 사례 → 앱 그대로 매핑)
- **메모(note) 타입**: type='task' / 'note'. note 는 체크 X, today 화면 제외, 진척률 분모 제외
- **Outline view**: 단축키 6. 5 카테고리 root + 자식 트리 펼침/접힘 + [N/M] progress bar
- **Bulk paste**: AddTodoSheet 의 multi-line paste → N개 todos 일괄 추가 (confirm dialog)
- **Today breadcrumb**: today list 의 각 todo 옆에 "JS슈퍼 / 울트라 모드" 식 path

---

## 2. 외부 환경 상태 (대표님이 이미 셋업한 것)

| 항목 | 상태 |
|------|------|
| macOS Xcode 풀 설치 + `xcode-select --switch` + `xcodebuild -runFirstLaunch` | ❌ 2026-07-13 확인: Xcode 제거됨 (`xcode-select -p` 가 CommandLineTools). macOS 재빌드 전 Xcodes.app 으로 재설치 필요 |
| 하루 앱 `/Applications/haru.app` 설치 | ✅ 2026-07-14 GitHub Actions 클라우드 빌드로 재설치·실행 확인 |
| **macOS 클라우드 빌드 파이프라인** (`.github/workflows/build-macos.yml`, 브랜치 `ci/macos-cloud-build`) | ✅ 로컬 Xcode·Apple ID 불필요. 재빌드: 해당 브랜치에 push (또는 main 병합 후 `gh workflow run build-macos`) → artifact `haru-macos` 다운로드 → `ditto -x -k` 해제 → `xattr -cr haru.app` (격리 해제 필수) → `/Applications` 복사. Supabase 키는 repo secret `ENV_LOCAL_B64` (base64 된 .env.local) |
| CocoaPods (`brew install cocoapods`) | ✅ |
| `make setup` (pub get + pod install) | ✅ |
| Supabase 프로젝트 + schema `solo_todo` + `todos` 테이블 + RLS + index + publication | ✅ SQL 실행 완료 |
| Supabase **Exposed schemas** 에 `solo_todo` 추가 | ✅ |
| Supabase Email Templates (`Confirm signup` + `Magic Link`) 가 `{{ .Token }}` 표시 | ✅ |
| `.env.local` (SUPABASE_URL / ANON / GOOGLE OAuth desktop + Android) | ✅ |
| Android debug SHA-1 | `F8:EC:9C:48:5D:79:DB:8B:D3:41:42:4C:65:33:14:EB:71:35:AE:DC` |
| Supabase OTP length | 8자리 (앱은 6~10 가변 허용) |
| **Supabase v1.1+v1.2 마이그레이션 (parent_id/type/sort_order/description + categories)** | ✅ 완료 — schema.sql 실행 + 동기화 검증됨 (`b246b64` 수정본 기준) |
| **Supabase fast-tasks 마이그레이션 (todos.end_at/is_all_day/time_anchor + groups + categories.group_id)** | ⚠️ **대표님 액션 필요** — `make sql` → Supabase SQL Editor 에 schema.sql 재실행. 전체 idempotent. 미실행 시 신규 필드 동기화에서 PGRST204. |
| **Supabase 진행중 3-상태 마이그레이션 (todos.started_at)** | ⚠️ **대표님 액션 필요 (2026-07-18)** — `make sql` → schema.sql 재실행(§21 started_at + notify pgrst). idempotent. 미실행 시 진행중 상태가 기기 간 동기화 안 됨. |
| **Google Cloud Console — Android OAuth client + calendar scope + 테스트 사용자** | ⚠️ **대표님 액션 필요** (Task 3). 아래 § 3 참조. 미설정 시 갤S24 캘린더 동의 차단. |
| `.env.local` 의 `GOOGLE_OAUTH_CLIENT_ID_ANDROID` | ⚠️ Android OAuth client id 채워야 Calendar provider 활성 (실제 매칭은 SHA-1). |
| 갤럭시 S24 (SM S921N) release APK 설치 | ✅ (단 fast-tasks 변경분은 재빌드·재설치 필요) |
| 로컬 DB 백업 | `~/solo_todo_db_backup/solo_todo_*.sqlite` (1회성, 이제 클라우드 동기화되므로 불필요시 삭제 가능) |

---

## 3. Next Steps — v1.2 종료, v1.3 후보

**v1.2 + 후속 버그수정 + fast-tasks(날짜·기간/그룹/캘린더권한) 전부 완료.** 단 아래 외부 액션이 선행돼야 fast-tasks 기능이 실기기에서 동작한다.

### ⚠️ 대표님 즉시 액션 (fast-tasks 활성화)

1. **Supabase schema.sql 재실행** — `make sql` 로 클립보드 복사 → Supabase SQL Editor 붙여넣고 실행. todos 날짜컬럼 3개 + groups 테이블 + categories.group_id 추가, 끝에서 `notify pgrst` 캐시 갱신. (idempotent, 안전)
2. **Google Cloud Console (Android 캘린더 권한, Task 3)**:
   - 사용자 인증 정보 → OAuth 클라이언트 ID 만들기 → 유형 **Android**, 패키지명 `com.goldenplanet.solo_todo`, **SHA-1** 등록 (`keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android` 의 SHA1).
   - OAuth **동의 화면 → 범위 추가**: `https://www.googleapis.com/auth/calendar.events`.
   - 앱이 "테스트" 상태면 **테스트 사용자**에 `dlwlstjq410@gmail.com` 추가.
   - 만든 Android client id 를 `.env.local` 의 `GOOGLE_OAUTH_CLIENT_ID_ANDROID` 에 기입.
3. **갤S24 재빌드·재설치** — fast-tasks 변경분 반영. `make build-apk` 후 `flutter install` (또는 `make run-android`).
   - 첫 캘린더 등록 시 **계정 동의 팝업이 떠야 정상**. 팝업 없이 거부되면 위 2번 콘솔 설정 누락.

### 미해결 / v1.3 후보 (대표님 결정 필요)

- **카테고리 추가/삭제 진입점이 데스크탑 사이드바에만 있음** — Android(NavigationBar)에는 카테고리 ADD/DELETE UI 가 없다. 모바일 진입점 추가 필요 (대표님이 "hover ⋯ / 전용 관리화면 / 모바일 진입점" 중 미결정).
- **카테고리 삭제 발견성** — 현재 사이드바 long-press / 우클릭만. 힌트 없음.
- **카테고리 편집** (label/color/icon 변경) — v1.2 는 ADD+DELETE 만. 편집은 v1.3 후보.
- **카테고리 reassign** — 삭제 차단된 카테고리의 todos 를 다른 카테고리로 옮기는 기능 없음 (지금은 차단만).
- **OutlineScreen tap-edit** — outline 노드 tap → edit sheet 진입은 아직 (체크 토글만 됨). HomeScreen/CategoryView 는 됨.
- **bulk paste 들여쓰기 → 자동 트리화** — 현재 평탄. 들여쓰기 인식은 미구현.

### ralph-loop 재개하려면

새 요구를 `/expand-plan` 으로 IMPLEMENTATION_PLAN 에 분해 추가 후:
```bash
/ralph-loop:ralph-loop "Read PROMPT.md and follow it." --completion-promise "PROJECT_DONE" --max-iterations <N>
```

---

## 4. What Worked (반복할 만한 접근)

- **bite-sized commit** — 한 iteration = 한 task = 1~3 파일 수정 + 단위 테스트. 분해가 곱고 의존성 순서 (DB → Domain → UI → 테스트) 일관.
- **backwards-compat 패턴** — Drift onUpgrade case 별 ALTER + Supabase `ALTER TABLE ADD COLUMN IF NOT EXISTS` 안내 주석 + JSON `@Default` 로 옛 payload 안전 복원.
- **stream provider override 로 widget test** — Drift in-memory DB 는 timer leak 위험. `StreamProvider.overrideWith((_) => Stream.value([]))` 패턴 (`HANDOFF.md § 6` 함정).
- **pure 함수 분리** — `splitBulkLines`, `computeTodoPath`, `computeSubtreeProgress` 처럼 도메인 로직을 `@visibleForTesting` static 으로 노출. unit test 가 widget mount 없이 직접 검증.
- **fake_async + clock + nowProvider** — 자정 trigger, debounce 등 시간 의존 로직을 결정적으로 검증.
- **race 가드 패턴** — `_submitted` flag / mutex (`_flushing` + `_rerunRequested`) / Timer cancel 후 재설정 (debounce).

---

## 5. What Didn't Work (반복하지 말 것)

- **Widget test 에서 Drift stream 직접 사용** — pending timer leak 으로 `binding._verifyInvariants` 위반. 반드시 stream provider override 패턴.
- **AppShell widget mount 통합 테스트** — hotkey_manager / tray / Timer 의 dispose 가 까다로워 hang. controller + DB 레벨 통합으로 검증 (`app_shell_flow_test.dart` 참고).
- **LWW 동률 stomp** — `>=` 동일 시각 → self-overwrite. `>` strict (§ 10-A 4건 통합 fix 의 핵심 원인).
- **TextField maxLines: 1 + paste 감지** — `\n` 자동 제거되어 multi-line paste 감지 불가. `maxLines: 5 + keyboardType.multiline + onChanged \n 감지` 패턴.
- **Riverpod 3 의 valueOrNull** — 일부 버전에서 미존재. `.asData?.value` 사용.

---

## 6. 함정 / 주의사항

- **cwd**: Bash 호출이 종종 옛 폴더로 reset. **항상 절대경로** `/Users/seobi/jinsup_ralph_mobile/haru` 사용.
- **Drift DateTime**: `storeDateTimeAsText: true` — ISO 8601 text 로 저장. SQL 비교 시 string 사전순.
- **Supabase schema**: `solo_todo.todos` (public 아님). 코드는 `client.schema('solo_todo').from('todos')`. SQL 도 `solo_todo.*`.
- **LWW**: 동률 stomp 회피 위해 `>` strict (>=) X.
- **인증**: 매직링크 X / OTP 6~10 자리 (Site URL 공유 불가 제약). `AuthService.sendEmailOtp` + `verifyEmailOtp(type: OtpType.email)`.
- **Widget test ↔ Drift stream**: provider override 필수.
- **fake_async**: `nowProvider.overrideWithValue(() => clock.now())` 패턴.
- **NavigationBar 6 destinations**: Android 폰 좁은 화면 빡빡. **v1.2 에서 N 동적이 되면 더 빡빡** — UI 보강 필요할 수도.
- **macOS desktop bottomNavigationBar**: null 분기 의도.
- **TestWidgets timer 누수**: AnimationController 가 vsync, 화면 unmount 시 정상 dispose.
- **Riverpod 3**: `valueOrNull` → `.asData?.value`.
- **Widget mount viewport**: AddTodoSheet 가 길어져 `setSurfaceSize(400, 1400)` 필요. `_Actions row` 가 viewport 밖이면 tap 무시 — `onPressed` 직접 호출 패턴이 안전.

### ⭐ 배치2 함정

- **카테고리·그룹은 todos 와 별도로 동기화해야 함** — realtime sync 는 원래 todos 채널만 구독했다. categories/groups 도 `SupabaseRealtimeSync` 가 채널 구독 + fetchAll 해야 cross-device 반영. **Supabase Realtime publication 에 `solo_todo.categories`/`groups` 가 켜져 있어야** 실제 동작(schema.sql 의 publication do-block 포함, 단 대시보드 Replication 확인 권장).
- **realtime self-loop 방지** — local-apply 는 반드시 **outbox 우회**(`LocalCategoriesRepository`/`LocalGroupsRepository`). Syncing\* 주입 시 self-broadcast → 무한 루프.
- **sortOrder 의미 = 작은 값이 위** — 정렬 키 `sortOrder asc, updatedAt desc`. 생성·시트편집은 `min-1` bump, **toggle 은 sortOrder 변경 금지**(체크 시 자리 이동 버그 방지).
- **AddTodoSheet 기본 카테고리 하드코딩 금지** — `Category.daily` 기본값이 "추가하면 다 일상으로" 버그를 냈다. 컨텍스트 카테고리 or categoriesProvider 첫 항목 사용.
- **모바일 NavigationBar 는 스크롤 불가** — destination 무제한 나열 금지. 오늘/전체보기/카테고리(슬롯) 3개 고정 + 카테고리는 Drawer.

### ⭐ 이번 라운드에서 추가된 핵심 함정 (v1.2 후속)

- **DB 파일/데이터 삭제 전 반드시 백업** — `cp solo_todo.sqlite ~/backup/`. 동기화가 깨진 상태면 로컬 데이터가 유일본일 수 있다. (1회 유실 사고 발생 — § 1 사고 기록)
- **schema.sql `create table if not exists` 는 기존 테이블이면 통째 스킵** — 신규 컬럼은 create 문이 아니라 **반드시 별도 `alter table ... add column if not exists` 로 추가**해야 기존 환경에 반영된다. (parent_id 누락 → PGRST204 무한 루프의 원인)
- **PGRST204 "Could not find column in the schema cache"** — 컬럼 추가 후 `notify pgrst, 'reload schema';` 안 하면 PostgREST 캐시가 옛 스키마를 본다. schema.sql 끝에 포함시킴.
- **Drift schemaVersion 은 컬럼/테이블 추가 시 반드시 bump** — onUpgrade case 에 ALTER 를 넣어도 version 을 안 올리면 이미 그 version 인 DB 는 재마이그레이션 안 돼 컬럼 누락. (description 누락 v3 사고)
- **동적 IconData(codepoint) → release 빌드 시 `--no-tree-shake-icons` 필수** — 카테고리 아이콘이 non-const 라 tree-shaking 실패. Makefile 의 build-apk/build-macos/run-android 에 반영됨.
- **Todo.category 는 todos 테이블에 id 만 저장** — label/color/icon 은 categories 테이블에 있으므로 **TodosDao 가 categories 와 join** 해서 복원. `Category.fromId` 는 builtin 만 알아 사용자 카테고리에 throw → join + placeholder fallback 으로 해소. SupabaseTodosApi._fromRow 도 tryFromId+placeholder (로컬 저장은 id 만 쓰므로 안전).
- **AddTodoSheet 는 ConsumerStatefulWidget** — categoriesProvider watch. 카테고리 선택 비교는 **id 기준** (freezed 전체 동등은 DB 인스턴스↔const 차이로 어긋남).
- **모바일 FAB 는 endFloat** — endContained 는 NavigationBar 에 도킹돼 destination 을 덮음. endFloat 가 바 위로 띄운다.

---

## 7. 핵심 파일 위치 (v1.1 종료 시점)

```
CLAUDE.md                              비전 / 환경 (자동 로드) — § 3 갱신 필요!
PROMPT.md                              ralph 절차 (§1 매 iter 흐름)
IMPLEMENTATION_PLAN.md                 task 체크리스트 (§ 12 v1.2 진입 직전)
AGENTS.md                              검증 명령 (dart analyze + format + flutter test)
Makefile                               make help / run / build / check / sql

lib/src/
├── app/                               SoloTodoApp + _AuthGate + Env
├── core/                              theme / platform / perf / date_format
├── domain/
│   ├── category.dart                  ⚠️ v1.2 에서 enum → freezed data class
│   ├── todo.dart                      Todo + TodoType (task/note) + parentId/sortOrder
│   └── policies/
│       ├── carryover_policy.dart      note 분리 적용됨
│       └── visibility_policy.dart     note 분리 적용됨
├── data/
│   ├── local/                         AppDatabase (schemaVersion 2) + TodosDao + OutboxDao + LocalTodoRepository
│   ├── remote/                        SupabaseTodosApi / Realtime / LWW / supabase_provider
│   ├── day_boundary_provider.dart     자정 Timer
│   ├── providers.dart                 appDatabase / todoRepository / nowProvider / outboxCountProvider
│   ├── syncing_todo_repository.dart   local + outbox + remote push 합성
│   └── todo_repository.dart           abstract interface
├── features/
│   ├── add_todo/                      AddTodoSheet (task/note + bulk paste) + AddTodoController
│   ├── auth/                          AuthService (OTP + 300ms debounce) + SignInScreen + providers
│   ├── calendar/                      GoogleAuthService + CalendarService
│   ├── category/                      CategoryView + providers
│   ├── home/                          HomeScreen (breadcrumb) + today_providers
│   ├── outline/                       ⭐ v1.1 신규 — OutlineScreen + tree_providers (allTodos / childrenOf / rootsOfCategory / SubtreeProgress / computeTodoPath)
│   ├── system/                        TrayService
│   └── todo_actions/                  toggle / delete / restore controller (v1.2 에 update 추가 예정)
└── ui/
    ├── app_shell.dart                 폼팩터 분기 + FAB + Cmd+N + 0~6 단축키 (SidebarItem public)
    ├── destination.dart               DestinationKind enum (today/category/outline)
    └── widgets/
        ├── animated_todo_list.dart    AnimatedTodoSliver (SliverAnimatedList + id-diff + breadcrumbBuilder)
        ├── dismissible_todo_tile.dart Dismissible + TodoTile (threshold 0.6)
        ├── todo_tile.dart             note → sticky_note 아이콘 + italic
        ├── empty_state.dart
        ├── skeleton.dart              TodoListSkeleton
        └── undo_snackbar.dart         _UndoContent + progress bar

supabase/
├── schema.sql                         v1.1 ALTER 안내 포함 (parent_id/type/sort_order)
└── migrate.sql                        옛 public 테이블 정리

assets/tray_icon.png                   22/44/66 PNG 멀티 해상도
SETUP.html                             사용자용 가이드 (v1.0 + v1.1 마이그레이션)
docs/audit/                            /audit-risk 1회성 산출물 (gitignored)
```

---

## 8. 빌드 / 검증 (Makefile)

```bash
make check        # analyze + format-check + test (커밋 직전)
make run          # macOS 데스크탑 실행
make run-android  # Android 첫 device 자동 선택
make build-apk    # release .apk
make codegen      # freezed / json / drift codegen
make sql          # schema.sql 클립보드 (Supabase SQL Editor 붙여넣기용)
```

`.env.local` 자동 감지 — 있으면 `--dart-define-from-file` 자동 주입.

---

## 9. 이 HANDOFF 갱신 규칙

- task 진행 / 외부 환경 변경 시 § 1 / § 2 동기화
- 새 함정 발견 시 § 6 추가
- v1.x 종료 시 § 1 의 단계 표 + § 7 핵심 파일 위치 갱신

ralph 가 v1.2 진행 중 매 commit 마다 이 파일도 함께 갱신.
