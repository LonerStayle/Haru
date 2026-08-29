# Detail-status / Teams / Drag — Fast tasks (3개)

작성일: 2026-08-29 · 요청자: 대표님 · 경로: `/fast-tasks`

---

## Task 1: 편집 시트에 3-상태(□△◯) 표시 + 설정

- **문제**: 항목을 탭하면 뜨는 편집 시트(`add_todo_sheet.dart`)에 상태(미완료/진행중/완료)
  표시가 전혀 없고, 시트 안에서 상태를 바꿀 수도 없다. 도메인에는 이미 3-상태가 있다
  (`startedAt` = 진행중, `doneAt` = 완료, 둘 다 null = 미완료).
- **명세**:
  - 편집 시트에 **`상태` 섹션** 신설. 기존 섹션(위치/카테고리/종류/일정/반복)과 같은
    `_SectionLabel` 톤으로 배치.
  - 기호 매핑 **□ 미완료 / △ 진행중 / ◯ 완료**. 현재 상태는 **채움 + 카테고리색**,
    나머지는 옅은 외곽선.
  - 탭 = **즉시 저장** (시트를 닫지 않아도 목록에 반영). 시트의 "닫힘=저장" 규칙과
    무관하게 즉석 반영한다.
  - `type == note` 는 상태 개념이 없으므로 섹션을 숨긴다.
  - 신규 추가 모드(초안)에서는 저장 대상 Todo 가 아직 없으므로 섹션 미노출 (편집 모드 전용).
  - 상태 전이는 도메인 불변식을 지킨다 — `startedAt` 과 `doneAt` 은 동시 세팅 금지.
- **영향 파일**: `lib/src/features/add_todo/add_todo_sheet.dart`,
  `lib/src/ui/widgets/in_progress_triangle.dart`(재사용),
  `lib/src/features/todo_actions/todo_actions_controller.dart`(기존 toggle 재사용),
  `lib/src/domain/todo.dart`(상태 전이 헬퍼가 없으면 추가)

## Task 2: Microsoft Teams(Microsoft 365) 캘린더 양방향 연동

- **명세**:
  - **양방향** — 구글 캘린더 연동과 동일 수준(등록·수정·삭제 + 증분 수신 + echo 차단 + LWW).
  - 계정: **회사 계정(Microsoft 365 직장/학교)**. Azure 앱 등록 필요.
  - 구글과 **병존** — 설정에 Google / Microsoft 두 섹션. 할 일마다 어느 provider 에
    연결됐는지 구분 가능해야 한다.
  - 이번 범위: **코드 전체 + Azure 앱 등록 가이드 문서**. 클라이언트 ID 입력만으로 동작.
  - 캘린더 계층을 provider 중립으로 정리한 뒤 Microsoft Graph 구현체를 추가한다
    (기존 `CalendarGateway` 는 `googleapis` 의 `gcal.Event` 에 직접 결합되어 있음).
- **영향 파일**: `lib/src/features/calendar/**`(gateway/service/sync/auth),
  `lib/src/features/settings/settings_sheet.dart`,
  `lib/src/features/calendar/calendar_settings_screen.dart`,
  `lib/src/domain/todo.dart`(provider 구분 필드), `supabase/schema.sql`,
  `lib/src/data/**`(로컬 스키마 마이그레이션), `docs/`(등록 가이드), `HANDOFF.md`

## Task 3: 하위 항목 드릴다운의 드래그 재정렬 발견성

- **확인된 현행**: 드릴다운 화면(`todo_drill_list.dart`)에 재정렬 코드는 **있다**.
  다만 ① 핸들 없이 **길게 누르기**로만 시작, ② 정렬이 **일정순**이면 꺼짐,
  ③ 상태별 보기 칩이 '전체'가 아니면 꺼짐 — 그래서 "안 된다"고 느껴진다.
- **명세**:
  - 드래그 시작 방식은 **long-press 유지**. 대신 **시각 힌트를 보강**해 끌 수 있음을 알린다.
  - 정렬이 **일정순**일 때는 현행대로 드래그 불가를 유지하되, **"수동 정렬에서만 순서 변경
    가능"** 안내 문구를 보여준다.
  - 상태별 보기 필터 중일 때도 같은 톤의 안내를 노출한다(같은 이유로 꺼져 있으므로).
  - 실제 재정렬 동작 자체가 형제 범위에서 올바른지 테스트로 고정한다.
- **영향 파일**: `lib/src/ui/widgets/todo_drill_list.dart`,
  `lib/src/features/todo_detail/todo_detail_screen.dart`, 해당 위젯 테스트

---

## 병렬화 계획 (DAG)

- **Independent: 1, 2, 3** — 세 task 의 영향 파일이 겹치지 않는다.
  - Task 1 = 편집 시트 내부 (`add_todo/`)
  - Task 2 = 캘린더 계층 + 설정 (`calendar/`, `settings/`)
  - Task 3 = 드릴 리스트 위젯 (`ui/widgets/todo_drill_list.dart`, `todo_detail/`)
- 접점 주의: Task 1 과 Task 2 가 모두 `lib/src/domain/todo.dart` 를 건드릴 수 있다
  (Task 1 = 상태 전이 헬퍼, Task 2 = provider 구분 필드). 각자 최소 변경으로 좁히고,
  freezed 재생성은 각 에이전트가 자기 변경 직후 수행한다.
