---
commit_policy: per-task
depth: 3
---

# 구현계획: Google Calendar 완전 양방향 동기화

> 상위: `google-calendar-sync-requirements.md` → `google-calendar-sync-tech-design.md`
> 검증 명령 (매 task 후 전부 exit 0): `flutter analyze` · `dart format --set-exit-if-changed .` · `flutter test`

---

## 0. 진행 원칙

- **TDD** — 각 task 는 실패하는 테스트부터. 테스트 코드는 이 문서에 싣지 않고 `**검증**` 필드로 목표만 기술한다.
- **커밋 단위** — task 하나당 커밋 하나. 검증 명령 3종이 모두 exit 0 인 것을 **출력으로 확인한 뒤** 커밋한다 (검증과 커밋을 한 배치에 섞지 않는다).
- **연동 OFF 불변식** — 어느 task 를 끝낸 시점에도, 캘린더 연동을 끄면 앱은 이전과 완전히 동일하게 동작해야 한다.
- **한글 문자열 검증** — 릴리스 산출물에서 한글 확인 시 UTF-16LE grep 을 쓴다.

---

## 0-1. 실행 순서 제약 (병렬 실행 시 필수)

병렬로 돌릴 때 **같은 파일을 만지는 task 는 반드시 직렬**이어야 한다.

| 제약 | 대상 | 이유 |
|---|---|---|
| **직렬 (같은 파일)** | D3 → E1 → E4 | 셋 다 `calendar_sync_service.dart` 를 만든다/수정한다 |
| **직렬 (같은 파일)** | A1 → A3 | 도메인 필드가 있어야 매핑을 쓴다 |
| **선행 필수** | A1, A2 → 그 이후 전부 | 스키마·도메인이 기반 |
| **선행 필수** | B2 → C2, D3, E1 | Gateway 인터페이스가 있어야 호출·목록 조회가 가능 |
| **선행 필수** | B3, B4 → E3, G1 | 서명/역매핑이 있어야 병합·왕복 검증 가능 |
| **선행 필수** | C1 → C2, D2, E1 | 설정값을 읽어야 대상 캘린더가 정해짐 |
| **선행 필수** | D1 → D2 | 판정 함수가 있어야 데코레이터가 동작 |
| **마지막** | G1 → G2 → G3 | 통합 검증 후 정리 |

**병렬 가능 묶음**: (A2 ∥ A4), (B1 ∥ B2 ∥ C1), (C2 ∥ C3), (E2 ∥ E5), (F1 ∥ F2 ∥ F3)

---

## 1. Task 목록

### Phase A — 스키마 기반

#### Task A1 — Todo 도메인에 `calendarId` / `calendarOrigin` 추가
- **Files**: `lib/src/domain/todo.dart` (+ freezed/json 재생성)
- **Model**: sonnet
- **내용**: `String? calendarId`, `@Default('app') String calendarOrigin` 2필드 추가. `Todo.create` 에 파라미터 추가(기본 'app'). 주석으로 D-5 삭제 규칙의 근거임을 명시.
- **검증**: 기존 Todo 직렬화 테스트가 전부 통과하고, 신규 필드가 누락된 옛 JSON 을 `fromJson` 했을 때 `calendarOrigin == 'app'` 으로 안전 복원된다.
- **RISK(breaking)**: freezed 재생성 필요 — `dart run build_runner build --delete-conflicting-outputs`

#### Task A2 — Drift v10 (todos 2컬럼 + `CalendarOps` 테이블 + DAO)
- **Files**: `lib/src/data/local/app_database.dart`, `lib/src/data/local/calendar_ops_dao.dart`(신규)
- **Model**: sonnet
- **내용**: `schemaVersion` 9→10. `Todos` 에 `calendarId`(nullable) / `calendarOrigin`(default 'app') 추가. `CalendarOps` 테이블 신규(tech-design §3-2 표). `onUpgrade` 에 `from < 10` 분기를 PRAGMA 가드로 idempotent 작성. `CalendarOpsDao` — `enqueue` / `dueOps(now)` / `bumpAttempt` / `removeById` / `clear` / `watchCount`.
- **검증**: v9 DB 를 v10 으로 올렸을 때 컬럼·테이블이 생기고 기존 row 가 보존된다. 같은 마이그레이션을 두 번 돌려도 실패하지 않는다.
- **RISK(breaking)**: schemaVersion bump 를 빠뜨리면 마이그레이션이 아예 돌지 않는다 (v3 description 누락 전례)

#### Task A3 — 로컬/원격 매핑에 신규 2필드 반영
- **Files**: `lib/src/data/local/todos_dao.dart`, `lib/src/data/remote/supabase_todos_api.dart`
- **Model**: sonnet
- **내용**: row→domain / domain→row 양방향에 `calendarId` / `calendarOrigin` 추가. 원격 row 에 필드가 없을 때 `'app'` 폴백 (다른 기기가 아직 구버전일 수 있음).
- **검증**: 신규 필드가 로컬 저장→조회, 원격 toRow→fromRow 왕복에서 보존되고, 필드 없는 원격 row 도 예외 없이 복원된다.

#### Task A4 — Supabase 스키마 ALTER 추가
- **Files**: `supabase/schema.sql`
- **Model**: haiku
- **내용**: `alter table solo_todo.todos add column if not exists calendar_id text;` / `... calendar_origin text not null default 'app';` + `notify pgrst, 'reload schema';` 를 기존 ALTER 블록 관례대로 추가.
- **검증**: SQL 파일에 두 ALTER 와 notify 가 존재한다 (정적 확인).
- **⚠️ 대표님 수동 작업**: Supabase SQL Editor 에서 `schema.sql` **전체 재실행**. 미실행분(`end_at`/`is_all_day`/`time_anchor`/`started_at`)이 함께 적용되어야 PGRST204 를 피한다.

### Phase B — 게이트웨이 · 매핑

#### Task B1 — OAuth scope 확대
- **Files**: `lib/src/features/calendar/google_auth_service.dart`
- **Model**: haiku
- **내용**: `calendarListScope`(`calendar.calendarlist.readonly`) 상수 추가, `_scopes` 에 포함. macOS 는 기존 refresh 실패 → 재동의 경로가 이미 있으므로 코드 변경 불필요함을 주석으로 남긴다.
- **검증**: `_scopes` 가 2개 scope 를 포함한다.
- **RISK(breaking)**: 기존 사용자 재동의 강제

#### Task B2 — `CalendarGateway` 인터페이스 + 구현 2종
- **Files**: `lib/src/features/calendar/calendar_gateway.dart`(신규), `lib/src/features/calendar/google_calendar_gateway.dart`(신규), `test/.../fake_calendar_gateway.dart`(신규)
- **Model**: opus
- **내용**: tech-design §4-2 시그니처대로. `GoogleCalendarGateway` 는 `CalendarAuth` 에서 client 를 받아 `gcal.CalendarApi` 호출 + 오류 매핑(§4-5 표)을 담당. `FakeCalendarGateway` 는 메모리 맵 + syncToken 시뮬레이션 + 주입 가능한 오류.
- **검증**: Fake 게이트웨이로 insert→list→update→delete 왕복이 동작하고, 404/410 이 멱등 성공으로 처리된다.

#### Task B3 — `buildEvent` 확장 (색상 · 서명 · 캘린더 파라미터화)
- **Files**: `lib/src/features/calendar/calendar_service.dart`
- **Model**: sonnet
- **내용**: `colorId = todo.isDone ? '8' : null`. `extendedProperties.private` 에 `haruTodoId` / `haruRev` / `haruDateMode` / `haruAnchor`. `'primary'` 하드코딩 제거 — 호출자가 `calendarId` 를 넘긴다.
- **검증**: 완료/미완료 각각의 colorId, 서명 4키가 실리고, 기존 날짜 모드 5종 매핑 테스트가 그대로 통과한다.
- **RISK(side-effect)**: `buildEvent` 는 기존 테스트 3파일이 의존하는 단일 출처 — 시그니처 변경 시 전부 갱신

#### Task B4 — 이벤트 → Todo 역매핑 + RRULE 역파서
- **Files**: `lib/src/features/calendar/event_to_todo.dart`(신규), `lib/src/domain/recurrence.dart`
- **Model**: opus
- **내용**: tech-design §4-6 표대로 `haruDateMode` 우선, 없으면 형태 추론. 종일 `end.date` 의 exclusive 를 되돌린다(−1일). `RecurrenceRule.tryFromRRule` — FREQ/INTERVAL/BYDAY/UNTIL 만 지원, 그 외 null.
- **검증**: 날짜 모드 5종을 `buildEvent` → 역매핑 왕복했을 때 모드·시각이 동일하다. 미지원 RRULE 은 null 을 반환해 단일 할 일로 폴백된다.

### Phase C — 설정

#### Task C1 — `CalendarSettings` (shared_preferences)
- **Files**: `lib/src/features/calendar/calendar_settings.dart`(신규)
- **Model**: sonnet
- **내용**: `sort_mode_controller.dart` 의 Preference+Notifier 패턴을 그대로 복제. tech-design §3-4 키 10종.
- **검증**: 각 키가 저장·복원되고, 최초 실행 시 기본값(쓰기=primary, 읽기=[primary], autoSync=true)이 나온다.

#### Task C2 — 캘린더 설정 화면
- **Files**: `lib/src/features/calendar/calendar_settings_screen.dart`(신규)
- **Model**: sonnet
- **내용**: tech-design §6-1 레이아웃. 미연결 시 `[Google 계정 연결]` 만. `Env` 미설정이면 항목 자체 숨김(`googleCalendarAvailableProvider` 사용). 읽기 캘린더별 카테고리 매핑 드롭다운. 대기 건수·마지막 동기화·`[지금 동기화]`. 모바일은 `AppPlatform.isMobile` 로 밀도 압축.
- **검증**: 연결/미연결/키없음 3상태가 각각 올바른 UI 를 낸다. 캘린더 선택과 매핑 변경이 설정에 저장된다.

#### Task C3 — 설정 시트 진입점
- **Files**: `lib/src/features/settings/settings_sheet.dart`
- **Model**: haiku
- **내용**: "Google Calendar" 항목 추가 → C2 화면으로 이동 (`archive_screen` 진입 패턴 답습).
- **검증**: 설정 시트에서 항목이 보이고 탭하면 화면이 열린다.

### Phase D — Push

#### Task D1 — `decideCalendarOp` 순수 함수
- **Files**: `lib/src/features/calendar/calendar_op_decider.dart`(신규)
- **Model**: opus
- **내용**: tech-design §2-3 판정 표. 감시 필드 10종만 `update` 를 유발. `sortOrder`/`parentId`/`description` 단독 변경은 `none`.
- **검증**: 감시 필드 각각을 바꿨을 때 update, 비감시 필드는 none, dueAt 제거·note 전환은 delete, 신규+dueAt+토글 ON 은 create 가 나온다.
- **RISK(side-effect)**: 이 판정이 느슨하면 `reorderSiblings` 한 번에 구글 API 가 N회 호출된다

#### Task D2 — `CalendarAwareTodoRepository` 데코레이터
- **Files**: `lib/src/data/calendar_aware_todo_repository.dart`(신규)
- **Model**: opus
- **내용**: `TodoRepository` 전 메서드를 inner 에 위임. `upsert`/`deleteById` 만 가로채 `getById`(변경 전) → 위임 → `decideCalendarOp` → 큐 적재. **위임이 먼저**여서 캘린더 실패가 로컬 저장을 막지 않는다.
- **검증**: 읽기 메서드가 그대로 통과되고, 캘린더 무관 변경은 큐에 아무것도 쌓지 않으며, 캘린더 관련 변경만 정확히 1건 쌓인다.
- **RISK(perf)**: `upsert` 당 `getById` 1회 추가. `restoreAll`/`reorderSiblings` 다건 경로에서 체감되면 배치 판정으로 전환

#### Task D3 — `CalendarSyncService` push (flush · 백오프 · 중복 방지)
- **Files**: `lib/src/features/calendar/calendar_sync_service.dart`(신규)
- **Model**: opus
- **내용**: 큐를 FIFO 로 처리하되 **항목 실패 시 break 하지 않고 다음으로 진행**. 지수 백오프(1m/5m/30m), `attempts > 5` 면 큐에서 내리고 `lastError` 보존. flush 직전 `getById` 재확인으로 `create`→`update` 강등(§2-7). create 성공 시 `calendarEventId`/`calendarId` 를 inner repo 로 기록.
- **검증**: 403 이 하나 섞여도 나머지 op 가 처리된다. 이미 eventId 가 있으면 create 가 update 로 강등된다. 성공 시 링크가 저장된다.
- **RISK(side-effect)**: 링크 기록이 다시 `upsert` 를 부르므로 데코레이터를 재진입한다 — 링크 필드만 바뀐 변경은 `decideCalendarOp` 가 `none` 이어야 무한 재적재가 없다

#### Task D4 — provider 조립 + 연동 OFF 경로
- **Files**: `lib/src/data/providers.dart`, `lib/src/features/calendar/calendar_providers.dart`(신규)
- **Model**: sonnet
- **내용**: `todoRepositoryProvider` 가 연동 활성 시에만 데코레이터로 감싼다(tech-design §2-2 코드). `calendarOpsCountProvider` 추가.
- **검증**: 연동 OFF 일 때 반환 타입이 기존과 동일하고, ON 일 때만 데코레이터가 끼워진다.

### Phase E — Pull

#### Task E1 — 증분 수신 + syncToken 관리
- **Files**: `lib/src/features/calendar/calendar_sync_service.dart`
- **Model**: opus
- **내용**: 읽기 캘린더별 `events.list`. 최초는 `timeMin=−30d` / `timeMax=+365d` / `singleEvents:false`, 이후 `syncToken`. `nextPageToken` 소진. 410 → 토큰 폐기 후 전체 재동기화 1회.
- **검증**: 토큰이 저장·재사용되고, 410 을 받으면 전체 재동기화로 폴백한 뒤 새 토큰을 저장한다.

#### Task E2 — 유입 필터
- **Files**: `lib/src/features/calendar/event_import_filter.dart`(신규)
- **Model**: sonnet
- **내용**: tech-design §4-4 규칙 5종.
- **검증**: declined / 초대(설정 OFF) / 생일·자동생성 / 이미 링크된 앱 원본이 각각 제외된다. `importInvited` 를 켜면 초대 이벤트가 통과한다.

#### Task E3 — echo 판정 + LWW 병합
- **Files**: `lib/src/features/calendar/calendar_merge.dart`(신규)
- **Model**: opus
- **내용**: `haruRev == todo.updatedAt` → skip. 아니면 `event.updated` vs `todo.updatedAt` 비교, 동률이면 앱 우선. 병합 시 역매핑(B4) 결과를 적용하되 **title/날짜만** 덮고 카테고리·트리 구조는 보존.
- **검증**: echo 는 아무 변경도 만들지 않는다. 캘린더가 최신이면 앱이 갱신되고, 앱이 최신이면 무시된다. 병합이 카테고리·parentId·sortOrder 를 건드리지 않는다.
- **RISK(race)**: echo 판정이 실패하면 push↔pull 무한 루프. Task G1 통합 테스트가 최종 방어선

#### Task E4 — 신규 유입 + 삭제 규칙
- **Files**: `lib/src/features/calendar/calendar_sync_service.dart`
- **Model**: opus
- **내용**: 링크 없는 통과 이벤트 → `Todo.create`(origin='gcal', 카테고리 매핑, sortOrder = root min−1). `status=='cancelled'` → D-5 4경우 분기. 같은 `haruTodoId` 이벤트 2개 이상이면 로컬 링크와 다른 쪽 삭제(§2-7).
- **검증**: 유입 항목이 지정 카테고리 맨 위에 생긴다. 삭제 4경우가 표대로 동작한다(앱 원본은 할 일 유지+링크 해제, gcal 원본은 삭제).

#### Task E5 — `CalendarSyncScheduler`
- **Files**: `lib/src/features/calendar/calendar_sync_scheduler.dart`(신규), `lib/src/ui/app_shell.dart`
- **Model**: sonnet
- **내용**: `WidgetsBindingObserver` 로 `resumed` 감지(앱 최초 도입). 시작 1회 + 포그라운드 복귀 + `Timer.periodic(5m)`(`paused` 시 정지) + 수동. `AppShell` 이 watch 해 init.
- **검증**: resumed 전이에서 동기화가 1회 트리거되고, paused 에서 타이머가 멈춘다.

### Phase F — UI · 기존 경로 이관

#### Task F1 — 편집 시트 토글 실동작 + 기억
- **Files**: `lib/src/features/add_todo/add_todo_sheet.dart`
- **Model**: sonnet
- **내용**: `_applyEdit()` 이 `_addToCalendar` 를 반영(켜짐+dueAt → create / 꺼짐+링크있음 → delete). 초기값을 `gcal.defaultAddToCalendar` 에서 읽고 제출 시 저장. `calendarOrigin=='gcal'` 항목에 배지 표시.
- **검증**: edit 모드에서 토글을 켜면 op 가 생기고, 끄면 삭제 op 가 생긴다. 다음 시트 오픈 시 마지막 선택이 유지된다.
- **RISK(side-effect)**: "닫힘=저장" 규칙과 "내용 무변경이면 no-op" 규칙을 동시에 지켜야 한다 — 토글만 바꾼 경우는 변경으로 취급

#### Task F2 — `add_todo_controller` 를 큐 경로로 이관
- **Files**: `lib/src/features/add_todo/add_todo_controller.dart`
- **Model**: sonnet
- **내용**: 직접 `createEventForTodo` 호출 제거 → 데코레이터가 처리. `addAll`(일괄) 도 동일. 실패 안내는 큐의 `lastError` 기반으로 전환하되 기존 `calendarWarning` SnackBar 경로는 유지.
- **검증**: 등록 시 캘린더 직접 호출이 사라지고 큐에 create op 가 쌓인다. 기존 warning 테스트가 새 경로로도 통과한다.

#### Task F3 — `recurrence_materializer` 신규 필드 처리
- **Files**: `lib/src/domain/recurrence_materializer.dart`
- **Model**: sonnet
- **내용**: 인스턴스 생성 시 `calendarEventId`/`calendarId` 를 null 로, `calendarOrigin` 은 마스터 승계.
- **검증**: 생성된 인스턴스에 이벤트 링크가 없다 (인스턴스마다 이벤트가 생기는 사고 방지).
- **RISK(side-effect)**: 누락 시 반복 인스턴스 수만큼 구글 이벤트가 생성됨

### Phase G — 마무리

#### Task G1 — 왕복 통합 테스트 (무한루프 방지)
- **Files**: `test/src/features/calendar/calendar_roundtrip_test.dart`(신규)
- **Model**: opus
- **내용**: Fake 게이트웨이 위에서 push → pull → **추가 push 가 발생하지 않음**을 검증. 날짜 모드 5종 각각. 캘린더 측 수정 → pull → 앱 반영 → 추가 push 없음.
- **검증**: 수용 기준 9. 2회차 pull 이후 큐 길이가 0 을 유지한다.

#### Task G2 — dead code 정리 + 계획서 정정
- **Files**: `lib/src/features/calendar/calendar_service.dart`, `IMPLEMENTATION_PLAN.md`
- **Model**: sonnet
- **내용**: 새 파이프라인으로 대체된 `tryCreate/Update/DeleteCalendarEvent` 등 호출자 없는 헬퍼 제거. `IMPLEMENTATION_PLAN.md §8` 의 사실과 다른 `[x]` 를 실제 상태로 정정.
- **검증**: `flutter analyze` 에 unused 경고가 없고, 제거한 심볼의 참조가 0건이다.

#### Task G3 — HANDOFF.md 갱신
- **Files**: `HANDOFF.md`
- **Model**: sonnet
- **내용**: scope 확대·재동의 절차, Supabase 재실행 필요, Drift v10, 신규 설정 화면 위치, 캘린더 큐 확인 방법을 §외부 환경/함정에 반영.
- **검증**: 문서에 위 5항목이 존재한다.

---

## 2. 위험 코드 지점

| R | 위치 | 위험 | 완화 |
|---|---|---|---|
| R-1 | `calendar_aware_todo_repository.dart` (신규, D2) | side-effect — **모든** todo mutation 이 이 데코레이터를 통과. 버그 시 앱 전체 저장이 영향 | 위임을 먼저 수행해 캘린더 실패가 저장을 막지 않음. 연동 OFF 면 미장착 |
| R-2 | `calendar_op_decider.dart` (신규, D1) | side-effect — 판정이 느슨하면 정렬 한 번에 API N회 | 감시 필드 화이트리스트 + 필드별 단위 테스트 |
| R-3 | `calendar_sync_service.dart` (신규, D3/E3) | race — echo 차단 실패 시 push↔pull 무한 루프 | `haruRev` 서명 + G1 왕복 통합 테스트 |
| R-4 | `calendar_sync_service.dart` (D3, 링크 기록) | side-effect — 링크 저장이 데코레이터를 재진입해 무한 재적재 | 링크 필드만 바뀐 변경은 `decideCalendarOp` = none |
| R-5 | `app_database.dart:138` schemaVersion (A2) | breaking — bump 누락 시 마이그레이션 미실행 (v3 전례) | 9→10 명시 + 마이그레이션 테스트 |
| R-6 | `supabase/schema.sql` (A4) | breaking — 미실행 시 PGRST204 로 동기화 전체 정지 | 전체 재실행 안내 + `notify pgrst` 동반 |
| R-7 | `google_auth_service.dart:17` scope (B1) | breaking — 기존 토큰 무효화, 재동의 필요 | macOS 는 기존 재동의 폴백 경로 활용, Android 는 증분 동의 |
| R-8 | `calendar_service.dart:79` `buildEvent` (B3) | side-effect — 테스트 3파일이 의존하는 단일 출처 | 시그니처 변경 시 의존 테스트 동시 갱신 |
| R-9 | `recurrence_materializer.dart` (F3) | side-effect — 인스턴스에 링크가 남으면 회차마다 이벤트 생성 | 인스턴스 링크 강제 null + 테스트 |
| R-10 | `add_todo_sheet.dart` `_applyEdit` (F1) | side-effect — "닫힘=저장" + "무변경 no-op" 두 규칙과 충돌 가능 | 토글 변경을 내용 변경으로 취급하도록 `_isUnchanged` 대상에 포함 |
| R-11 | `providers.dart:30` `todoRepositoryProvider` (D4) | breaking — 8곳이 watch. 조립 실수 시 앱 전역 저장 경로 손상 | 연동 OFF 시 기존 인스턴스를 그대로 반환하는 경로를 테스트로 고정 |

---

## 3. 대표님 수동 작업 (코드로 대체 불가)

1. **Supabase SQL Editor 에서 `supabase/schema.sql` 전체 재실행** (Task A4 이후) — 미실행 마이그레이션까지 함께 적용
2. **구글 재동의** — 새 빌드 첫 실행 시 동의 화면 1회 통과 (scope 확대)
3. 확인용: 설정 → Google Calendar → 캘린더 선택

---

## 변경이력
<!-- change-history skill auto-appends entries here, oldest first -->

### [2026-08-15 14:47] [구현계획서-수정]
- **id**: CH-20260815-003
- **이유**: tech-design D-T1~D-T12 를 TDD bite-sized task 로 분해 (auto-flow write-plan 단계)
- **무엇이**: google-calendar-sync-implementation-plan.md 전체 — §0 진행 원칙 / §0-1 실행 순서 제약 / §1 Task A1~G3 (7 Phase, 22 task) / §2 위험 코드 지점 R-1~R-11 / §3 대표님 수동 작업
- **영향범위**: verifying-spec 결과 D-T1~D-T12 전부 task 매핑 확인, 수용 기준 14항 전부 추적 가능. 자체 보강 1건 — 병렬 실행 시 `calendar_sync_service.dart` 를 D3/E1/E4 가 공유하므로 §0-1 직렬 제약 표 추가 (충돌 방지). `plan_byte_check` 는 Flutter 프로젝트라 helper 부재 + `**원본**` 코드 블록 미사용으로 해당 없음
- **연관 항목**: CH-20260815-002
