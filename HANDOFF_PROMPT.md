# 인수인계 프롬프트 — 앱 내 캘린더 화면

> 새 Claude Code 세션을 이 워크트리(`.worktrees/앱내캘린더`)에서 열고, 아래 `---` 사이 내용을 그대로 첫 프롬프트로 붙여넣으세요.

---

너는 지금 `haru`(Flutter 할 일 앱, macOS 데스크탑 + Android)의 워크트리 `.worktrees/앱내캘린더`, 브랜치 `앱내캘린더`에서 작업한다. 분기 기준은 `main @ 4ec4ac7`(전역 검색 기능 포함)이다.

## 목표

**앱 안에서 쓰는 캘린더 화면을 새로 만든다.** 지금 이 앱에는 날짜를 "달력 격자"로 보는 화면이 아예 없다. 있는 건 `타임라인`(날짜 지정된 미완료 할 일을 지남/오늘/내일/이번주/이후 버킷으로 나열)뿐이다. 이번 작업은 그걸 대체하거나 보완하는 **진짜 캘린더 뷰**를 만드는 것이다.

대표님(1인 사용자, 30대 개발자)이 "엄청 정교하게, 긴 루프를 돌려서라도 제대로" 만들라고 요구한 영역이다. 대충 월 그리드 하나 그리고 끝내지 마라.

## 먼저 할 일 — 요구사항 확정

코드부터 짜지 마라. 아래 항목들은 **대표님만 결정할 수 있는 것들**이다. `AskUserQuestion` 도구로 물어서 확정한 뒤 시작해라 (산문으로 묻지 말 것 — 알림이 안 울려서 놓친다).

1. **타임라인과의 관계** — 캘린더가 타임라인을 흡수(대체)하는가, 별도 destination으로 나란히 두는가?
2. **뷰 범위** — 월 뷰만? 월+주? 월+주+일? (각각 구현 비용이 크게 다르다)
3. **핵심 인터랙션** — 날짜 탭 → 그날 목록, 드래그로 날짜 변경, 빈 칸 탭 → 그 날짜로 새 할 일 추가 중 무엇이 필수인가?
4. **표시 대상** — 완료 항목도 캘린더에 보이는가? 메모(note)는? 반복 일정은 인스턴스마다 다 찍히는가?
5. **구글 캘린더 이벤트를 캘린더 화면에 같이 그리는가** (읽기 전용으로라도) — 이건 별도 워크트리 `구글캘린더동기화`와 겹치는 영역이라 경계를 분명히 해야 한다.

확정된 답을 `docs/features/YYYY-MM-DD-앱내캘린더/` 아래 요구사항 문서로 남기고, 그걸 `IMPLEMENTATION_PLAN.md`의 bite-sized task로 분해해라.

## 코드베이스 사실 (조사 완료 — 다시 파헤치지 말 것)

### 데이터 모델 — `lib/src/domain/todo.dart`
`Todo`는 freezed. 캘린더에 필요한 날짜 필드는 이미 **전부 있다**:

| 필드 | 의미 |
|---|---|
| `dueAt` (`DateTime?`) | 날짜 앵커. null이면 날짜 미지정 |
| `endAt` (`DateTime?`) | 기간 모드의 종료 시각. 단일 모드면 null |
| `isAllDay` (`bool`, 기본 false) | true면 시간 미표시 (화면 어디에도 `00:00`을 찍지 않는 규칙) |
| `timeAnchor` (`String`, `'start'`/`'end'`) | `dueAt`이 시작인지 마감인지 |
| `doneAt` / `startedAt` | 완료 / 진행중 3-상태. 둘 동시 세팅 금지가 불변식 |
| `seriesId` / `recurrenceRule` / `recurrenceEndAt` / `isSeriesMaster` | 날짜 반복. **`isSeriesMaster == true`는 숨김 템플릿이라 모든 목록에서 제외하는 것이 전 앱 불변 규칙** |
| `type` (`TodoType.task` / `.note`) | note는 체크 개념 없음, `isDone` 항상 false |

**스키마 변경은 아마 필요 없다.** 필요하다고 판단되면 그 자체를 먼저 대표님께 보고해라 (drift `schemaVersion` bump + `supabase/schema.sql`의 `alter table ... add column if not exists` + `notify pgrst` 3종 세트가 세트로 따라오고, 대표님이 SQL Editor에서 수동 실행해야 하는 외부 작업이 생긴다).

### 데이터 접근 — 이 프로젝트의 확립된 방식
- **SQL 필터를 새로 만들지 마라.** DAO 주석에 명시돼 있다: 1인 사용자 데이터(~수백 건)라 전부 **in-memory 필터링**한다.
- 전역 소스는 `allTodosProvider` (`lib/src/features/outline/tree_providers.dart:15`, `StreamProvider<List<Todo>>`).
- **패턴**: base `StreamProvider`는 순수하게 두고, 파생 `Provider<AsyncValue<...>>`에서 `.whenData()`로 필터만 얹는다. base를 직접 건드리면 재구독이 나서 테스트가 불안정해진다 (`today_providers.dart:23-36` 주석 참조).
- 보관 카테고리 제외는 `archivedCategoryIdsProvider` (`features/category/categories_controller.dart:171`) 한 줄이면 된다. 기존 화면 전부 이걸 쓴다.

### 화면 등록 — `lib/src/ui/destination.dart`
`enum DestinationKind { today, category, outline, timeline }` + `AppDestination.buildAll()`에서 동적 생성. 단축키는 today=0, outline=1, timeline=2, 카테고리=3~9. 캘린더를 새 destination으로 추가하려면 여기 enum + buildAll + `app_shell.dart`의 `_MainArea` 분기 + 모바일 `NavigationBar`(현재 4슬롯 고정)까지 손대야 한다. **모바일 nav가 이미 4칸이라 자리 문제가 생긴다 — 이게 위 질문 1번이 중요한 이유다.**

### 참고할 기존 화면
- `lib/src/features/timeline/timeline_screen.dart` (373줄) — 날짜 버킷 나열. 필터 조건(`type == task && dueAt != null && !isDone && !archived`)과 편집 시트 호출 방식을 그대로 참고해라.
- `lib/src/ui/widgets/todo_tile.dart` — 재사용 가능한 행 위젯. 옵션 파라미터가 많다 (`breadcrumb`, `snippet`, `drillChildCount`, `hiddenSeriesCount` 등). 캘린더 일정 칩은 이것과 별개로 작은 전용 위젯이 필요할 가능성이 크다.
- `lib/src/core/date_format.dart` — 날짜 라벨 포맷 단일 출처. 새로 만들지 말고 여기에 추가해라.
- `lib/src/domain/recurrence.dart` + `recurrence_materializer.dart` — 반복 규칙과 인스턴스 생성. 캘린더에 반복을 그릴 때 반드시 읽어라.

### 구글 캘린더 (건드릴 때 주의)
`lib/src/features/calendar/`에는 **구글 연동 코드만** 있다 (`calendar_service.dart`, `google_auth_service.dart`). 화면은 없다. 현재 연동은 **단방향·1회성**이다 — 새 할 일에 날짜 넣고 토글 켤 때만 이벤트 생성되고, 이후 수정/삭제는 반영 안 된다(`tryUpdateCalendarEvent`/`tryDeleteCalendarEvent` 헬퍼는 있으나 호출처 미연결).

**별도 워크트리 `구글캘린더동기화`가 바로 이 영역을 담당한다.** 같은 디렉터리를 양쪽에서 고치면 머지 충돌이 난다. 이 워크트리는 **앱 내 캘린더 화면(로컬 Todo 렌더링)** 에 집중하고, `calendar_service.dart` / `google_auth_service.dart`는 가급적 건드리지 마라. 꼭 필요하면 대표님께 먼저 보고해라.

## 지켜야 할 규칙

### 검증 (커밋 전 3종 모두 exit 0 — `AGENTS.md`)
```bash
dart analyze
dart format --output=none --set-exit-if-changed .
flutter test
```
결과 줄을 **눈으로 읽고** 커밋해라. 검증과 커밋을 한 배치에 섞지 마라. 현재 기준선은 715 tests PASS이며, analyze에는 기존 deprecation info 7건이 남아 있다(내가 만든 게 아니면 건드리지 마라).

### 코딩 관례
- 주석은 한국어. "무엇을" 이 아니라 **"왜 이렇게 했는지"** 를 남긴다 (기존 파일들 톤을 그대로 따라해라).
- 위젯 테스트는 `ValueKey` 기반으로 찾는다. 새 위젯에는 의미 있는 key를 붙여라.
- 테스트 디렉터리는 `test/src/...`로 `lib/src/...`를 미러링한다.
- **기능은 데스크탑·모바일 양쪽 parity**. 다만 폭·줄 수·터치 타겟은 `AppPlatform.isMobile`로 분기해 모바일만 압축한다.
- 정렬 키에 `updatedAt`을 넣지 마라 (체크·동기화로 자리가 튄다). Todo 정렬은 `sortOrder asc → createdAt desc → id asc`.
- 편집 시트는 **닫으면 저장**이 규칙이다 (배경 탭/드래그/Esc 전부 자동 저장). 취소 개념을 새로 넣지 마라.

### 실행
```bash
flutter run -d macos --dart-define-from-file=.env.local
```
`.env.local`과 `android/local.properties`는 이 워크트리에 이미 복사돼 있다.

## 작업 방식

대표님이 "엄청 긴 루프"를 언급했다. 요구사항 확정 후 `IMPLEMENTATION_PLAN.md`를 task 단위로 채우고, ralph 자율 루프(`/ralph-loop:ralph-loop`) 또는 task별 순차 실행으로 진행해라. 매 task 끝에 검증 3종을 통과시키고 커밋한다.

**중간 보고 톤**: 대표님이라 호칭하고, 경어체로, 한 일 / 결과 / 다음 방향을 3~5줄로 분리해서 보고해라. 에러 원문을 그대로 노출하지 말고 "이런 결정이 필요합니다"로 프레이밍해라.

---
