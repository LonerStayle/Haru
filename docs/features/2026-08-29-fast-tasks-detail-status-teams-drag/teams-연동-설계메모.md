# Teams(Microsoft 365) 캘린더 연동 — 설계 메모

> 이 문서는 **코드를 고칠 사람**을 위한 것입니다.
> 대표님이 직접 하셔야 하는 외부 작업은 `teams-연동-대표님-작업-가이드.md` 에 따로 있습니다.

---

## 1. 무엇을 provider 중립으로 바꿨나

이전에는 `CalendarGateway` 가 `googleapis` 의 `gcal.Event` 를 그대로 주고받았다.
두 번째 서비스를 붙이려면 병합·필터·매핑·큐를 통째로 복제해야 하는 구조였다.

이제 게이트웨이가 주고받는 타입은 **`CalEvent` 하나**다.

```
Todo ──(CalendarService.buildEvent)──▶ CalEvent ──▶ CalendarGateway
                                          ▲              │
                     eventToTodoPatch ────┘              ├─ GoogleCalendarGateway  → gcal.Event
                     mergeEventIntoTodo                  └─ MicrosoftGraphGateway  → Graph JSON
                     judgeImport
```

| 파일 | 역할 |
|---|---|
| `calendar_event.dart` | `CalendarProvider` enum · `CalEvent` / `CalEventTime` / `CalRecurrence` |
| `calendar_gateway.dart` | 서비스 중립 인터페이스 + `CalendarInfo` / `EventPage` / 오류 분류 |
| `calendar_service.dart` | `Todo` → `CalEvent` 매핑 (단일 출처) |
| `event_to_todo.dart` | `CalEvent` → 할 일 값 (`EventDatePatch`) |
| `event_import_filter.dart` | 유입 판정 |
| `calendar_merge.dart` | echo 차단 + LWW 병합 |
| `google_calendar_gateway.dart` | `CalEvent` ↔ `gcal.Event` + 구글 오류 분류 |
| `microsoft_graph_gateway.dart` | `CalEvent` ↔ Graph JSON + 그래프 오류 분류 |
| `calendar_auth.dart` | 서비스·플랫폼 중립 인증 인터페이스 |
| `microsoft_auth_service.dart` | OAuth2 Authorization Code + PKCE (macOS·Android 공통) |

동기화 서비스(`CalendarSyncService`)와 오케스트레이터(`CalendarSyncCoordinator`)는
**서비스 하나당 인스턴스 하나**다. 스케줄러가 둘을 순차로 돌린다 — 동시에 돌리면
두 수신 결과가 같은 할 일을 겹쳐 쓰는 경합이 생기고, 그 경합은 재현이 어렵다.

---

## 2. 어느 할 일이 어느 서비스에 묶였나

- `Todo.calendarProvider` — `'google'` | `'microsoft'` | **null**
- `Todo.calendarOrigin` — `'app'` | `'gcal'` | `'msgraph'`
- `calendar_ops.provider` — 큐 항목의 목적지

**null 과 모르는 값은 전부 구글로 읽는다** (`CalendarProvider.fromWire`).
이 필드가 생기기 전 데이터는 전부 구글 연동이었기 때문이다. 기본값을 `'google'` 로
박지 않고 nullable 로 둔 이유도 같다 — 컬럼이 없는 원격 row 와 있는 row 가 같은
의미로 읽혀야 한다.

삭제 규칙은 `Todo.isFromCalendar`(= `calendarOrigin != 'app'`) 하나로 판정한다.
`== 'gcal'` 비교를 코드 여기저기에 흩뿌리면 서비스가 늘 때마다 빠뜨리는 곳이 생긴다.

---

## 3. Microsoft 쪽에서 다른 점 (알고 고쳐야 할 것)

### 3-1. 증분 수신은 deltaLink 다

`EventPage.nextSyncToken` 자리에 그래프의 **deltaLink URL 전체**가 들어간다.
다음 회차에는 그 URL 을 그대로 다시 부른다. 호출자에게는 구글의 `syncToken` 과
똑같이 불투명한 문자열이므로 저장·복원 코드는 공유된다.
만료는 `410` + `resyncRequired` → `CalendarErrorKind.syncTokenExpired` 로 번역되어
기존 "전체 재수집 폴백" 경로를 그대로 탄다.

### 3-2. 앱 서명이 안 돌아올 수 있다

구글은 `extendedProperties.private` 를 증분 응답에 그대로 실어 준다.
그래프는 `singleValueExtendedProperties` 를 `$expand` 로 요청해야 하는데,
delta 에서의 `$expand` 지원이 문서상 분명하지 않다.

그래서 게이트웨이는 **확장 속성을 요청해 보고, 400 이면 확장 없이 한 번 더 부른다**
(`_expandSupported` 플래그, 세션 단위). 확장이 안 되는 환경에서도 동기화가
성립하도록 두 가지 안전장치를 병합 쪽에 두었다:

1. **내용이 같으면 echo** — `mergeEventIntoTodo` 가 시각·서명보다 먼저 내용을 본다.
   서명이 없어도 되받은 내용을 되쏘는 루프가 끊긴다.
2. **연결된 할 일의 날짜 모드를 형태 힌트로** — `eventToTodoPatch(shapeHint:)`.
   서명이 없으면 "시작시간" 으로 올린 1시간 블록이 되읽을 때 `range` 로 변질된다.
   단 **형태와 어긋나는 힌트는 무시**한다 (`_compatible`) — 사람이 종일 일정을
   시간 일정으로 바꿨는데 힌트를 따르면 그 변경을 영영 못 받는다.

### 3-3. 시각 파싱

그래프는 소수점 이하 **7자리**(`2026-08-29T10:00:00.0000000`)로 내려주는데
Dart 의 `DateTime.parse` 는 6자리까지만 받는다. 자르지 않으면 **모든 일정이
조용히 파싱 실패로 사라진다.** `_parseGraphInstant` 가 잘라 준다.
요청에는 항상 `Prefer: outlook.timezone="UTC"` 를 붙여 파싱 규칙을 하나로 유지한다.

### 3-4. 반복

그래프는 RRULE 을 받지 않고 `patternedRecurrence` 객체를 쓴다.
우리 규칙(daily / weekly+요일 / monthly / yearly + 간격 + 종료일)은 전부 절대
패턴으로 표현된다. `relativeMonthly`("매월 셋째 화요일") 처럼 표현할 수 없는
패턴은 **근사하지 않고** `rule == null` 인 `CalRecurrence` 로 돌려 단일 할 일로
폴백시킨다 — 근사하면 앱이 계산한 발생일이 캘린더와 조용히 어긋난 채 굴러간다.

PATCH 본문에는 반복이 없어도 `"recurrence": null` 을 **명시**한다. 생략하면
기존 반복이 그대로 남는다.

### 3-5. 완료 표시는 반영하지 않는다

구글은 `colorId = 8`(회색)로 표시한다. Outlook 은 일정 단위 색 지정이 마스터 범주
등록을 요구하고, `categories` 를 덮어쓰면 사용자가 직접 붙인 범주를 지우게 된다.
`CalEvent.markDone` 은 그래프 쪽에서 **의도적으로 무시**한다.

### 3-6. 인증

MSAL 플러그인을 쓰지 않았다. 구글에서 겪은 것과 같은 이유 — 네이티브 SDK 는
키체인 액세스 그룹(macOS)과 서명 해시 등록(Android)을 요구해 1인 개발자의 로컬
서명 빌드에서 조용히 실패한다. Authorization Code + PKCE 는 client secret 없이
성립하므로 순수 Dart 로 구현했고, 플랫폼 분기는 "브라우저를 어떻게 여는가"
한 줄(`_defaultOpenUrl`)로 줄었다.

리다이렉트는 양 플랫폼 모두 **loopback**(`http://localhost:<임의포트>`). Azure 가
"모바일 및 데스크톱 애플리케이션" 의 `http://localhost` 를 포트 무시로 매칭해 주므로,
커스텀 스킴을 위한 매니페스트 편집과 딥링크 수신 플러그인이 필요 없다.

refresh token 은 구글 데스크톱 플로우와 **같은 계층**(`getApplicationSupportDirectory()`)
에 `microsoft_calendar_token.json` 으로 저장하고, 발급받은 scope 목록도 함께 남긴다
(refresh grant 는 scope 부족을 스스로 알려주지 않는다 — `scopesCoverRequired`).

---

## 4. 새로 추가한 의존성

| 패키지 | 왜 |
|---|---|
| `crypto` | PKCE `code_challenge`(SHA-256). dart.dev 공식. 이미 transitive 였던 것을 직접 의존으로 승격 |
| `url_launcher` | Android 에서 동의 화면을 기본 브라우저로 연다 (macOS 는 `open`). flutter.dev 공식. 역시 transitive 승격 |

Android 매니페스트에 `<queries>` 의 `VIEW`/`https` 선언을 추가했다 — Android 11+ 는
이 선언이 없으면 브라우저를 찾지 못한다.

---

## 5. 건드릴 때 주의 (기존 함정에 더해)

1. **큐는 provider 로 갈린다.** `CalendarOpsDao.dueOps(now, provider:)` 를 빼먹으면
   구글 이벤트 id 가 그래프로 날아가 404 만 반복한다.
2. **수신의 링크 조회도 provider 로 거른다.** `CalendarSyncService.pull` 의
   `byEventId` 가 자기 서비스 것만 담는다. 거르지 않으면 한쪽 수신이 다른 쪽 링크를
   덮어쓴다.
3. **코디네이터의 토큰 저장은 자기 칸만.** `_persist` 가 `viewFor(provider)` 로
   좁혀 쓴다. 전체를 덮으면 다른 서비스가 다음 회차에 전체 재수집으로 떨어진다.
4. **연결 해제는 `clearProvider`.** `clear()` 를 부르면 다른 서비스의 대기열까지 날린다.
5. **Microsoft 의 기본 읽기 캘린더는 비어 있다.** 그래프의 캘린더 id 는 계정마다
   다른 긴 문자열이라 `'primary'` 같은 가짜 기본값을 넣을 수 없다. 연결 직후
   설정 화면이 목록을 한 번 받아 기본 캘린더를 채워 준다(`_seedDefaultCalendar`).
6. `CalendarSettings` 는 **구글만 평평하다.** 저장 키(`gcal.*`)와 호출부를 지키려고
   일부러 남긴 비대칭이다. provider 중립 코드는 `viewFor` / `withConnection` 만 쓴다.

---

## 6. 검증 범위

실제 Microsoft 계정 호출은 검증할 수 없어 전부 fake 위에서 덮었다.

| 파일 | 무엇 |
|---|---|
| `microsoft_graph_gateway_test.dart` | 경로 · JSON 왕복 · delta 페이지네이션 · `$expand` 폴백 · 오류 매핑 (MockClient) |
| `microsoft_auth_service_test.dart` | PKCE · 동의 URL · 토큰 파싱 · state 검증 · scope 대조 |
| `calendar_two_providers_test.dart` | 두 서비스 병존 불변식 (라우팅 · 링크 격리 · 큐 분리) |
| `google_event_mapping_test.dart` | 구글 변환 왕복 (회귀 방지) |
| `migration_v10_to_v11_test.dart` | provider 컬럼이 null 로 추가되고 옛 데이터가 구글로 읽히는지 |

**검증되지 않은 것**: 실제 Graph 응답 형태, delta 의 `$expand` 지원 여부,
Azure 등록 화면의 실제 동작. 첫 연결 때 대표님이 확인해 주셔야 한다.
