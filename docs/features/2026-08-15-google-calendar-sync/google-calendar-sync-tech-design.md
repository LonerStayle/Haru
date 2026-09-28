---
depth: 3
depth_reason: 코드 변경 범위가 큼 (DB 스키마 v10, 신규 서비스 4종, 신규 설정 화면, OAuth scope 확대) — 구현계획서 필요
---

# 기술설계: Google Calendar 완전 양방향 동기화

> 상위 문서: `google-calendar-sync-requirements.md` (Socratic 모드)
> 다음 단계: `google-calendar-sync-implementation-plan.md`

---

## 1. 개요

요구사항 D-1~D-12 를 코드 구조로 옮긴다. 핵심 과제는 세 가지다.

1. **모든 mutation 경로를 한 곳에서 잡기** — 편집 시트 진입점만 7곳이고, 이동/정렬/완료 토글/일괄 붙여넣기까지 세면 더 많다. 각 호출부에 캘린더 호출을 흩뿌리면 반드시 누락이 생긴다.
2. **불필요한 API 호출 억제** — `reorderSiblings` 는 형제 전체를 `upsert` 하지만 캘린더와는 무관하다. 순서만 바뀐 10건이 구글 API 10회 호출이 되면 안 된다.
3. **echo 루프 차단** — 앱이 쓴 변경이 되돌아와 다시 앱을 갱신하고 또 캘린더로 나가는 순환.

---

## 2. 아키텍처

### 2-1. 전체 구조

```
[UI 진입점 다수]
  AddTodoController / TodoActionsController / MoveTodoSheet / 정렬 / 완료 토글
        │  (전부 TodoRepository.upsert / deleteById 로 수렴)
        ▼
┌─────────────────────────────────────────────────────────┐
│ CalendarAwareTodoRepository  (신규 · 데코레이터)          │
│  - 기존 repo 에 위임 (Local / Syncing 무관)               │
│  - 변경 전 상태를 읽어 "캘린더에 영향 있는 diff" 판정      │
│  - 영향 있을 때만 CalendarOps 큐에 적재                   │
└─────────────────────────────────────────────────────────┘
        │ 위임                          │ enqueue
        ▼                               ▼
  LocalTodoRepository            ┌──────────────────┐
  또는 SyncingTodoRepository      │ CalendarOps (큐)  │  ← 신규 Drift 테이블
  (Supabase 동기화 — 기존 그대로)  └──────────────────┘
                                          │
                                          ▼
                              ┌────────────────────────┐
                              │ CalendarSyncService     │  ← 신규
                              │  push: 큐 flush         │
                              │  pull: syncToken 증분   │
                              └────────────────────────┘
                                          │
                                          ▼
                              ┌────────────────────────┐
                              │ CalendarGateway (인터페이스) │ ← 신규 (테스트 이음매)
                              │   └ GoogleCalendarGateway   │
                              │       (gcal.CalendarApi)    │
                              └────────────────────────┘
```

### 2-2. 데코레이터를 고른 이유 (D-T1)

요구사항 §8 이 남긴 3안을 비교했다.

| 안 | 장점 | 치명적 단점 | 판정 |
|---|---|---|---|
| **A. 컨트롤러마다 훅** | 얕고 이해하기 쉬움 | 호출부가 7곳 이상. 새 진입점이 생길 때마다 누락. 이미 이 방식으로 실패한 전례(현재 update/delete 미배선) | ❌ |
| **B. `SyncingTodoRepository` 내부에 훅** | mutation 이 한 곳 | **미인증 시 `LocalTodoRepository` 로 빠져 캘린더 동기화가 통째로 사라짐.** 구글 연동은 Supabase 로그인과 독립이어야 함 | ❌ |
| **C. 데코레이터 (채택)** | 인증 여부와 무관하게 모든 mutation 캡처, 계층 위반 없음, 기존 두 repo 를 건드리지 않음, 테스트에서 벗겨내기 쉬움 | provider 조립이 한 겹 늘어남 | ✅ |

`todoRepositoryProvider` 조립만 바꾼다:

```dart
final todoRepositoryProvider = Provider<TodoRepository>((ref) {
  final base = /* 기존 Local / Syncing 선택 로직 그대로 */;
  final linkEnabled = ref.watch(calendarLinkEnabledProvider);
  if (!linkEnabled) return base;                 // 연동 꺼짐 → 기존과 완전히 동일
  return CalendarAwareTodoRepository(
    inner: base,
    ops: db.calendarOpsDao,
    settings: () => ref.read(calendarSettingsProvider),
  );
});
```

**연동이 꺼져 있으면 데코레이터를 아예 끼우지 않는다** — 수용 기준 12(연동 없이도 모든 기능 정상)를 구조로 보장한다.

### 2-3. "캘린더에 영향 있는 diff" 판정 (핵심)

데코레이터의 `upsert(todo)` 는 다음을 수행한다.

```
prev = inner.getById(todo.id)     // 변경 전 상태
await inner.upsert(todo)          // 로컬·Supabase 는 기존대로 즉시
op  = decideCalendarOp(prev, todo, settings)
if (op != none) ops.enqueue(op)
```

`decideCalendarOp` 의 판정 규칙:

| 조건 | 결과 |
|---|---|
| `prev == null` (신규) + dueAt 있음 + 캘린더 등록 대상 | `create` |
| `calendarEventId != null` + **감시 필드** 중 하나라도 변경 | `update` |
| `calendarEventId != null` + dueAt 이 null 이 됨 | `delete` (+ 링크 해제) |
| `calendarEventId != null` + `type` 이 note 로 전환 | `delete` (+ 링크 해제) |
| `calendarEventId == null` + dueAt 생김 + 토글 ON | `create` |
| 그 외 (sortOrder / parentId / description 만 변경) | **none — 큐에 넣지 않음** |

**감시 필드**: `title`, `dueAt`, `endAt`, `isAllDay`, `timeAnchor`, `doneAt`, `type`, `category`(설명 문자열에 들어감), `recurrenceRule`, `recurrenceEndAt`

이 판정 하나가 요구사항의 과제 2(불필요 호출 억제)를 해결한다. `reorderSiblings` 는 `sortOrder` 만 바꾸므로 전부 `none` 이다.

> ⚠️ RISK(perf): 데코레이터가 `upsert` 마다 `getById` 를 1회 추가한다. Drift 로컬 조회라 수 ms 지만, `reorderSiblings` 처럼 루프에서 N회 `upsert` 하는 경로에서는 N회 늘어난다. 구현 시 `restoreAll` / `reorderSiblings` 같은 다건 경로는 배치 판정으로 우회할지 측정 후 결정한다.

### 2-4. 큐 — 왜 기존 outbox 를 쓰지 않는가 (D-T2)

기존 `OutboxEntries` 재사용도 가능하지만 분리한다.

| 항목 | 기존 outbox (Supabase) | 캘린더 큐 |
|---|---|---|
| 실패 처리 | 하나 실패하면 **break** (순서 보존이 필수 — 같은 row 의 후속 mutation 이 먼저 가면 안 됨) | 항목 간 독립 → **하나 실패해도 다음 진행**, 항목별 재시도 카운트 |
| 실행 조건 | Supabase user 필수 (`userIdGetter() == null` 이면 return) | 구글 연결만 있으면 실행 (Supabase 무관) |
| 재시도 | 즉시 | rate limit(403/429) 대응 지수 백오프 필요 |

성질이 다르므로 **신규 테이블 `CalendarOps`** 를 쓴다. 같은 테이블에 kind 만 늘리면 위 세 가지가 전부 충돌한다.

### 2-5. 두 방향의 흐름

**Push (앱 → 캘린더)**
```
mutation → 데코레이터 diff 판정 → CalendarOps enqueue → flush 시도
  flush: op 하나씩 → Gateway 호출 → 성공 시 큐에서 제거
         create 성공 → todo.calendarEventId / calendarId 기록 (inner.upsert 로 Supabase 에도 전파)
         실패 → 재시도 카운트 +1, 다음 op 진행 (백오프)
```

**Pull (캘린더 → 앱)**
```
트리거(앱 시작 / 포그라운드 / 5분 주기 / 수동)
  → 읽기 캘린더마다 events.list(syncToken)
  → 변경분 각각에 대해:
       ① extendedProperties.private['haruRev'] == 로컬 todo.updatedAt  → echo, skip
       ② 링크된 todo 있음 → LWW 병합 (event.updated vs todo.updatedAt)
       ③ 링크 없음 + 유입 필터 통과 → 신규 Todo 생성 (origin='gcal')
       ④ status == 'cancelled' → D-5 삭제 규칙
  → 새 syncToken 저장
```

### 2-6. Echo 차단의 정확한 메커니즘 (D-T3)

앱이 이벤트를 push 할 때 `extendedProperties.private` 에 두 값을 심는다.

```dart
event.extendedProperties = gcal.EventExtendedProperties(
  private: {
    'haruTodoId': todo.id,
    'haruRev'   : todo.updatedAt.toUtc().toIso8601String(),
  },
);
```

pull 시 판정:

- `haruRev` 가 **로컬 todo 의 현재 updatedAt 과 같다** → 이 변경은 우리가 쓴 것 → **무시**
- `haruRev` 가 다르거나 없다 → 사람이 구글 캘린더에서 고친 것 → LWW 병합 대상

이 방식은 **로컬에 별도 리비전 필드를 두지 않아도 되고**, 기기가 둘(macOS/Android)이어도 각자 판정이 성립한다. A 기기가 push 한 변경을 B 기기가 pull 하면 `haruRev` 는 B 의 로컬 `updatedAt` 과 일치한다 — Supabase 동기화로 `updatedAt` 이 이미 전파됐기 때문이다.

`haruTodoId` 는 링크 복구용이다. 로컬 `calendarEventId` 가 유실되어도 이벤트가 어느 할 일 것인지 역추적할 수 있다.

### 2-7. 두 기기 중복 생성 방지 (D-T4)

macOS 와 Android 가 같은 순간 같은 할 일에 대해 `create` 를 던지면 이벤트가 2개 생긴다. 방어는 2겹이다.

1. **선점 확인** — flush 직전 `inner.getById` 로 다시 읽어 `calendarEventId` 가 이미 채워졌으면 `create` 를 `update` 로 강등
2. **중복 정리** — pull 에서 같은 `haruTodoId` 를 가진 이벤트가 2개 이상 발견되면, 로컬 `calendarEventId` 와 일치하지 않는 쪽을 삭제

완전한 분산 락은 백엔드가 없어 불가능하므로, 짧은 경합 구간의 중복은 pull 이 수렴시키는 방식으로 처리한다.

---

## 3. 데이터 모델 / 스키마

### 3-1. `Todo` 도메인 — 필드 2개 추가

```dart
// 이벤트가 들어있는 캘린더 id. null = 미등록 또는 레거시(primary 로 간주).
String? calendarId,
// 출처 — 'app' (앱에서 만듦) | 'gcal' (캘린더에서 유입). 기본 'app'.
@Default('app') String calendarOrigin,
```

- `calendarOrigin` 은 **D-5 삭제 규칙의 유일한 근거**다. 반드시 Supabase 로 전파되어야 두 기기가 같은 판단을 한다.
- `calendarId` 는 나중에 사용자가 쓰기 캘린더를 바꿔도 기존 이벤트를 찾아가기 위해 필요하다 (`'primary'` 하드코딩 제거).
- 기존 `calendarEventId` 는 그대로 쓴다.

### 3-2. Drift — schemaVersion 9 → 10

```
v10:
  - todos.calendar_id       text nullable
  - todos.calendar_origin   text not null default 'app'
  - calendar_ops 테이블 신규
```

`CalendarOps` 테이블:

| 컬럼 | 타입 | 설명 |
|---|---|---|
| id | text PK | uuid |
| kind | text | 'create' \| 'update' \| 'delete' |
| todoId | text | 대상 할 일 |
| eventId | text? | update/delete 시 대상 이벤트 |
| calendarId | text | 대상 캘린더 |
| payload | text? | 스냅샷 JSON (delete 는 null) |
| attempts | int (default 0) | 재시도 횟수 |
| lastError | text? | 마지막 오류 (설정 화면 표시용) |
| nextAttemptAt | dateTime? | 백오프 |
| createdAt | dateTime | FIFO |

기존 마이그레이션 관례대로 `PRAGMA` 가드로 idempotent 하게 작성한다.

### 3-3. Supabase — ALTER 2개

```sql
alter table solo_todo.todos add column if not exists calendar_id     text;
alter table solo_todo.todos add column if not exists calendar_origin text not null default 'app';
notify pgrst, 'reload schema';
```

`calendar_ops` 는 **로컬 전용**이다 — 큐는 기기별 상태이므로 Supabase 에 올리지 않는다.

> ⚠️ **선행 조건**: `HANDOFF.md:151-152` 기준 `end_at` / `is_all_day` / `time_anchor` / `started_at` 마이그레이션이 **아직 미실행**이다. 이번 ALTER 만 실행하고 그것들을 빠뜨리면 PGRST204 로 동기화 전체가 죽는다. `supabase/schema.sql` 전체 재실행이 안전하다.

### 3-4. 설정 저장 — shared_preferences

기존 `sort_mode_controller.dart` 의 `Preference + Notifier` 패턴을 그대로 복제한다 (저장 계층을 새로 만들지 않는다).

| 키 | 타입 | 기본값 |
|---|---|---|
| `gcal.connected` | bool | false |
| `gcal.writeCalendarId` | String | `'primary'` |
| `gcal.readCalendarIds` | JSON list | `['primary']` |
| `gcal.categoryMap` | JSON map (calendarId→categoryId) | `{}` |
| `gcal.defaultCategoryId` | String | 첫 활성 카테고리 |
| `gcal.importInvited` | bool | false |
| `gcal.autoSync` | bool | true |
| `gcal.syncTokens` | JSON map (calendarId→token) | `{}` |
| `gcal.lastSyncedAt` | String (ISO) | 없음 |
| `gcal.defaultAddToCalendar` | bool | false — 편집 시트 토글 기억값 |

---

## 4. 외부 인터페이스 (Google Calendar API)

### 4-1. OAuth scope 확대

```dart
const calendarEventsScope = 'https://www.googleapis.com/auth/calendar.events';
const calendarListScope   = 'https://www.googleapis.com/auth/calendar.calendarlist.readonly'; // 신규
const _scopes = [calendarEventsScope, calendarListScope];
```

- 캘린더 **목록** 조회에는 `calendar.events` 만으로 부족하다. 전체 `calendar` scope 는 과하므로 `calendarlist.readonly` 만 더한다.
- **기존 사용자는 재동의가 필요하다.** macOS 는 저장된 refresh token 이 새 scope 를 포함하지 않아 갱신이 실패하고, 코드가 이미 그 경우 토큰을 지우고 브라우저 동의로 넘어간다(`google_auth_service.dart:152-157`) — 자연스럽게 처리된다. Android 는 `authorizeScopes` 증분 동의가 뜬다.

### 4-2. `CalendarGateway` 인터페이스 도입 (테스트 이음매)

현재 `CalendarService` 는 내부에서 `gcal.CalendarApi(client)` 를 직접 만들어 **API 호출 경로를 테스트할 수 없다** (실제 인증 없이는 한 줄도 못 돈다). 그래서 얇은 인터페이스를 끼운다.

```dart
abstract class CalendarGateway {
  Future<List<CalendarInfo>> listCalendars();
  Future<String?> insertEvent(String calendarId, gcal.Event event);
  Future<void>    updateEvent(String calendarId, String eventId, gcal.Event event);
  Future<void>    deleteEvent(String calendarId, String eventId);
  Future<EventPage> listChanges(String calendarId, {String? syncToken, DateTime? timeMin});
}
```

- `GoogleCalendarGateway` — 실제 구현 (기존 `CalendarService` 의 몸통을 이관)
- `FakeCalendarGateway` — 테스트용. 이벤트를 메모리 맵으로 들고 있으면서 echo/LWW/삭제 규칙을 전부 검증 가능

`CalendarService.buildEvent` 는 **그대로 유지**한다 — 이미 날짜 모드 5종 매핑과 RRULE 이 테스트로 보호되고 있는 자산이다. 여기에 두 가지만 더한다:

```dart
// 완료 표시 (D-6) — 완료면 회색(Graphite), 아니면 캘린더 기본색
event.colorId = todo.isDone ? '8' : null;
// echo 차단 서명 (2-6)
event.extendedProperties = ...;
// 캘린더 하드코딩 제거: 'primary' → settings.writeCalendarId
```

### 4-3. 증분 동기화 (`events.list`)

| 항목 | 값 |
|---|---|
| 첫 동기화 | `timeMin` = 오늘 −30일, `timeMax` = 오늘 +365일, `singleEvents: false` (반복은 마스터로 받음) |
| 이후 | 저장된 `syncToken` 만 전달 |
| 토큰 만료 | `410 GONE` → 토큰 폐기 + 전체 재동기화 1회 |
| 페이지네이션 | `nextPageToken` 소진까지 |
| 삭제 감지 | `status == 'cancelled'` |

`singleEvents: false` 를 쓰는 이유 — 반복 일정을 개별 회차로 펼치면 앱에 수백 건이 쏟아진다. 마스터 1건으로 받아 반복 마스터 할 일에 대응시킨다(D-10).

### 4-4. 유입 필터 (D-3)

이벤트를 할 일로 들일지 판정:

```
제외: status == 'cancelled'
제외: 내 응답이 'declined'
제외: importInvited == false 인데 organizer.self != true
제외: eventType == 'birthday' | 'fromGmail'  (생일/공휴일/자동 생성)
제외: extendedProperties.private['haruTodoId'] 가 이미 로컬에 있는 경우(= 앱 원본)
```

### 4-5. 오류 처리

| 상태 | 처리 |
|---|---|
| 401 / invalid_grant | 토큰 폐기 → 설정 화면에 "재연결 필요" 표시. 큐는 보존 |
| 403 rateLimitExceeded / 429 | 지수 백오프 (1m → 5m → 30m), 큐 유지 |
| 404 / 410 (이벤트 없음) | 멱등 성공 처리 + 링크 해제 (기존 `deleteEvent` 규칙과 동일) |
| 그 외 5xx | 재시도, `attempts` 5회 초과 시 큐에서 내리고 `lastError` 보존 |

---

### 4-6. 이벤트 → Todo 역매핑 (`buildEvent` 의 역함수)

`buildEvent` 는 Todo 의 날짜 모드 5종을 이벤트로 내보내지만, **되돌리는 규칙이 없으면 왕복할 때 모드가 변질된다.** 예를 들어 `startTime` 모드는 "그 시각 + 1시간" 블록으로 나가는데, 그대로 되읽으면 `range` 모드가 되어 버린다.

그래서 push 시 서명에 날짜 모드를 함께 심는다.

```dart
private: {
  'haruTodoId'  : todo.id,
  'haruRev'     : todo.updatedAt.toUtc().toIso8601String(),
  'haruDateMode': todo.dateMode.name,      // ← 왕복 안정성의 핵심
  'haruAnchor'  : todo.timeAnchor,
}
```

**역매핑 규칙**

| 이벤트 형태 | `haruDateMode` 있음 (앱이 만든 것) | 없음 (사람이 캘린더에서 만든 것) |
|---|---|---|
| `start.date` (종일), 하루 | 저장된 모드 유지 | `allDay` — dueAt=시작일 00:00, isAllDay=true |
| `start.date`, 이틀 이상 | 저장된 모드 유지 | `range` + isAllDay=true — endAt = `end.date − 1일` (exclusive 되돌림) |
| `start.dateTime` | 저장된 모드 유지 (`startTime`/`endTime` 이면 endAt 은 버린다) | `range` + isAllDay=false — dueAt=start, endAt=end |

시간이 캘린더에서 이동된 경우에도 `haruDateMode` 는 그대로 남으므로 **모드는 보존되고 시각만 갱신**된다.

**반복 이벤트 (RRULE) 역파싱**

앱에는 `toRRule` 만 있고 역파서가 없다. 신규로 `RecurrenceRule.tryFromRRule` 을 만들되 지원 범위를 한정한다.

- 지원: `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`, `INTERVAL`, `BYDAY`(요일 목록), `UNTIL`
- 미지원(`BYSETPOS`, `BYMONTHDAY` 복합 등): **반복으로 만들지 않고 첫 회차만 단일 할 일로 유입** + 해당 항목에 "반복 규칙은 캘린더에서만 관리됨" 표시

과도한 RRULE 호환을 v1 에서 추구하지 않는다 — 대표님이 앱에서 만드는 반복은 `toRRule` 이 내보낸 형태이므로 왕복은 항상 성립한다.

**유입 항목의 배치**

| 필드 | 값 |
|---|---|
| `category` | 캘린더별 매핑(D-4), 없으면 `gcal.defaultCategoryId` |
| `parentId` | null (root) |
| `sortOrder` | 해당 카테고리 root 의 min − 1 (맨 위) — 새로 들어온 것을 바로 보이게 |
| `type` | `task` |
| `calendarOrigin` | `'gcal'` |

### 4-7. 연결 해제의 정확한 동작 (D-11)

| 대상 | 처리 |
|---|---|
| OAuth 토큰 | 폐기 (`CalendarAuth.signOut` — 드디어 호출자가 생긴다) |
| `gcal.*` 설정 | `connected=false`, `syncTokens` 비움. 캘린더 선택·매핑은 **보존** (재연결 시 그대로 복원) |
| `CalendarOps` 큐 | 비움 — 연결이 없는데 쌓아둘 이유가 없고, 재연결 시점의 상태로 다시 시작하는 편이 안전 |
| `calendarEventId` / `calendarId` / `calendarOrigin` | **보존** — 재연결하면 기존 링크가 살아난다 |
| 구글 캘린더의 이벤트 | **손대지 않는다** (요구사항 D-11) |

### 4-8. 동기화 트리거 구현 (D-9)

현재 앱에는 `AppLifecycleState` 관찰자가 **한 곳도 없다**(grep 0건). 신규로 `CalendarSyncScheduler` 를 만들어 `AppShell` 이 watch 한다.

| 트리거 | macOS | Android |
|---|---|---|
| 앱 시작 | ✅ 최초 프레임 이후 | ✅ 동일 |
| 포그라운드 복귀 (`resumed`) | ✅ 창 포커스 복귀 시 발생 | ✅ 앱 전환 복귀 시 |
| 주기 (기본 5분) | ✅ `Timer.periodic`, `paused` 상태에서는 정지 | ✅ 동일 |
| 수동 | 설정 화면 `[지금 동기화]` | 동일 |

플랫폼 분기 없이 동일 코드로 동작한다 (수용 기준 13).

---

## 5. 결정 + 대안 비교 요약

| # | 결정 | 채택 | 탈락안과 이유 |
|---|---|---|---|
| D-T1 | mutation 캡처 지점 | **Repository 데코레이터** | 컨트롤러 훅(누락 위험·전례 있음) / Syncing 내부 훅(미인증 시 소실) |
| D-T2 | 큐 저장소 | **신규 `CalendarOps` 테이블** | 기존 outbox 재사용 — 실패 정책·실행 조건·백오프가 전부 상충 |
| D-T3 | echo 차단 | **`extendedProperties.haruRev` vs `updatedAt`** | 별도 리비전 컬럼(스키마 비대) / 시각 비교만(오차로 오판) |
| D-T4 | 중복 생성 | **flush 직전 재확인 + pull 정리** | 분산 락(백엔드 없음) |
| D-T5 | 반복 일정 수신 | **`singleEvents: false`, 마스터 1건** | 펼쳐 받기(수백 건 유입) |
| D-T6 | 완료 표시 | **`colorId='8'` (회색)** | 제목 프리픽스(역방향 파싱 오염) / 이벤트 삭제(히스토리 원칙 위배) |
| D-T7 | scope | **events + calendarlist.readonly** | 전체 `calendar`(과한 권한) |
| D-T8 | 설정 저장 | **shared_preferences (기존 패턴 복제)** | 신규 저장 계층(중복 인프라) |
| D-T9 | 테스트 이음매 | **`CalendarGateway` 인터페이스** | 현행 유지 시 API 경로 테스트 불가 |
| D-T10 | pull 트리거 | **시작·포그라운드·5분·수동** | 웹훅(백엔드 필요) / 상시 폴링(쿼터·배터리) |
| D-T11 | 날짜 모드 왕복 | **`haruDateMode` 서명으로 모드 보존** | 형태만 보고 추론(startTime → range 로 변질) |
| D-T12 | RRULE 역파싱 | **한정 지원 + 미지원은 단일 폴백** | 완전 RRULE 파서(범위 과대) / 반복 유입 포기(D-10 위배) |

---

## 6. UI 설계

### 6-1. 설정 → Google Calendar (신규 화면)

`settings_sheet.dart` 에 항목 추가 → `calendar_settings_screen.dart` (기존 `archive_screen.dart` 패턴 답습).

```
┌ Google Calendar ──────────────────────────┐
│ ● 연결됨 — dlwlstjq410@gmail.com          │
│                            [연결 해제]     │
├───────────────────────────────────────────┤
│ 할 일을 등록할 캘린더                       │
│   [ 기본 캘린더 (dlwlstjq410@…)      ▾ ]   │
├───────────────────────────────────────────┤
│ 가져올 캘린더                               │
│   ☑ 기본 캘린더        → [회사 할일   ▾]   │
│   ☐ 가족                → [일상 할일   ▾]   │
│   ☐ 대한민국 공휴일      (가져오기 불가)     │
├───────────────────────────────────────────┤
│ ☐ 초대받은 일정도 가져오기                  │
│ ☑ 자동 동기화 (5분)                        │
├───────────────────────────────────────────┤
│ 마지막 동기화 14:20 · 대기 0건              │
│                          [지금 동기화]     │
└───────────────────────────────────────────┘
```

미연결 상태에서는 `[Google 계정 연결]` 버튼 하나만 노출한다. `Env` 키가 없으면 항목 자체를 숨긴다(현행 `googleCalendarAvailableProvider` 를 드디어 사용).

### 6-2. 편집 시트 변경

- `_CalendarToggle` 이 **edit 모드에서 실제 동작** — `_applyEdit()` 이 `addToCalendar` 를 읽어 `create` / `delete` 를 유발 (수용 기준 14)
- 토글 기본값을 `gcal.defaultAddToCalendar` 에서 읽어 **마지막 선택을 기억**
- 유입 항목(`calendarOrigin == 'gcal'`)에는 캘린더 아이콘 배지 + "구글 캘린더에서 가져옴" 안내
- 모바일 밀도 규칙 유지 — 신규 UI도 `AppPlatform.isMobile` 분기로 폭·줄수를 압축

### 6-3. 동기화 상태 노출

`outboxCountProvider` 와 같은 방식으로 `calendarOpsCountProvider` 를 만들어, 대기 건수가 0보다 크면 설정 화면에 표시한다. 앱 전면에 상시 배지를 띄우지는 않는다(대표님 화면 밀도 우선).

---

## 7. 테스트 전략

현재 캘린더 테스트는 `buildEvent` 매핑과 RRULE 부착만 덮고 있고, **인증·update·delete·pull 경로는 0건**이다. 신규 테스트는 `FakeCalendarGateway` 위에서 돈다.

| 층 | 대상 | 핵심 케이스 |
|---|---|---|
| 단위 | `decideCalendarOp` | 감시 필드 각각이 update 를 유발 / sortOrder·parentId·description 은 none / dueAt 제거 → delete / note 전환 → delete |
| 단위 | `buildEvent` 확장 | 완료 시 colorId='8', 미완료 시 null, extendedProperties 서명 |
| 단위 | echo 판정 | haruRev == updatedAt → skip, 다르면 병합 |
| 단위 | LWW 병합 | event.updated 가 최신이면 앱 갱신 / todo 가 최신이면 무시 / 동률이면 앱 우선 |
| 단위 | 삭제 규칙 (D-5) | 4가지 경우 전부 |
| 단위 | 유입 필터 | declined / 초대 / 생일 캘린더 제외 |
| 단위 | **날짜 모드 왕복** | 5종 각각 push → pull 후 모드·시각이 그대로 (D-T11) |
| 단위 | `tryFromRRule` | 지원 규칙 파싱 / 미지원 규칙은 null → 단일 폴백 |
| 단위 | 큐 백오프 | 403 → attempts 증가·다음 op 진행, 5회 초과 → 큐에서 내림 |
| 통합 | 왕복 무한루프 방지 | push → pull → 추가 push 가 발생하지 않음 (수용 기준 9) |
| 위젯 | 설정 화면 | 연결/해제, 캘린더 선택, 매핑 |
| 위젯 | 편집 시트 토글 | edit 모드에서 토글이 실제 op 를 만든다 |
| 마이그레이션 | v9 → v10 | 기존 DB 에서 컬럼·테이블 추가 idempotent |

Drift stream 을 위젯 테스트에서 직접 쓰지 않고 provider override 로 주입하는 기존 관례를 따른다.

---

## 8. 마이그레이션 / 운영

### 8-1. 순서 (반드시 이 순서)

1. **Supabase `schema.sql` 전체 재실행** — 미실행분(end_at/is_all_day/time_anchor/started_at) + 신규 2개 컬럼 + `notify pgrst`
2. Drift v10 마이그레이션 (앱 실행 시 자동)
3. 앱 배포 후 **첫 실행 시 구글 재동의** (scope 확대)
4. 설정 화면에서 캘린더 선택 → 첫 동기화

### 8-2. 기존 데이터 취급

- `calendarEventId` 가 이미 있는 할 일 → `calendarId = 'primary'`, `calendarOrigin = 'app'` 로 간주 (기본값이 그렇게 떨어짐). 재등록하지 않는다.
- 첫 pull 에서 그 이벤트들은 `haruTodoId` 서명이 없으므로 "캘린더에서 고친 것"으로 보일 수 있다 → **첫 동기화 시 링크된 이벤트는 서명만 주입하는 1회 update** 를 수행해 기준선을 맞춘다.

### 8-2-1. 반복 인스턴스 생성기와의 접점

`recurrence_materializer.dart` 가 반복 마스터로부터 인스턴스를 만들 때 `calendarEventId` 를 다룬다. 인스턴스는 이벤트를 갖지 않는다는 기존 설계(마스터가 RRULE 이벤트 1개 소유)를 유지하되, 신규 필드도 함께 비워야 한다 — 인스턴스는 `calendarId = null`, `calendarOrigin` 은 마스터를 승계한다. 여기를 빠뜨리면 인스턴스마다 이벤트가 생성되는 사고가 난다.

### 8-3. 롤백

연동을 끄면 데코레이터가 빠지고 앱은 이전과 동일하게 동작한다. 스키마는 nullable / default 라 되돌릴 필요가 없다.

### 8-4. 빌드 주의

- 릴리스 빌드 전 `flutter clean` (병합 후 증분 빌드가 옛 캐시로 컴파일되어 기능이 조용히 누락된 전례)
- `--no-tree-shake-icons` 유지
- 번들 ID / applicationId / Supabase 스키마명은 OAuth 연동 키이므로 **변경 금지**

---

## 변경이력
<!-- change-history skill auto-appends entries here, oldest first -->

### [2026-08-15 14:41] [개발방향-수정]
- **id**: CH-20260815-002
- **이유**: 요구사항 D-1~D-12 를 코드 구조로 전개 (auto-flow tech-design 단계). 조사에서 드러난 dead code·미배선·테스트 이음매 부재를 설계로 해소
- **무엇이**: google-calendar-sync-tech-design.md 전체 (§1 개요 / §2 아키텍처 / §3 스키마 / §4 외부 인터페이스 / §5 결정 D-T1~D-T12 / §6 UI / §7 테스트 / §8 마이그레이션)
- **영향범위**: verifying-spec 결과 갭 3건을 본 문서에서 자체 보강 — §4-6 이벤트→Todo 역매핑 + RRULE 역파싱(D-10 이행에 필수였으나 누락), §4-7 연결 해제 동작(D-11 미명세), §4-8 동기화 트리거 구현(AppLifecycle 관찰자 앱 내 0건). §8-2-1 로 `recurrence_materializer` 접점 추가
- **연관 항목**: CH-20260815-001
