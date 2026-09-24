# UX 개선 인수인계 — Phase 0 완료 → Phase 1 시작 (2026-09-25)

> 다음 세션은 이 파일 하나로 이어서 작업한다. 전체 개선안: `docs/ux-review/2026-09-24-UX-전면-개선안.md`.

## 1. 현재 상태

- 작업 위치: 워크트리 `.worktrees/UX개선-phase0`, 브랜치 `UX개선-phase0` (분기점 main `42a1605`). **main 미머지.**
- 커밋 (위가 최신):
  - `7a9068a` fix(desktop): 흔들린 클릭이 무시되던 문제 (데스크탑 Dismissible 제거 + ClickTolerantDraggable)
  - `ace85aa` feat(shortcut): 전역 ⌘⇧N, 앱 안 ⌘N (대표님 결정)
  - `6bedea9` feat(ux): Phase 0 — 버그 10건 + 빠른 개선
- 검증: `dart analyze` exit 0 (info 7건 = main 과 동일한 deprecated) · `dart format` 통과 · `flutter test` **1333/1333**.
- 대표님은 이 워크트리에서 `flutter run -d macos` 로 확인 중. Dart 만 바꿨으면 `R`(hot restart), 단축키·트레이는 앱 재시작 필요.
- main 체크아웃에는 대표님의 미커밋 변경(.claude/settings.json, HANDOFF.md, macos/*)이 있다 — 건드리지 말 것.

## 2. Phase 0 에서 바뀐 것 (요약)

- FAB/⌘N/⌘⇧N/트레이 → 곧바로 새 할 일 시트. 저장은 `showNewTodoSheet`(add_todo_controller.dart) 한 곳.
- 카테고리·그룹 추가 = 사이드바 하단 / 관리 Drawer 하단 `AddEntityButtons`.
- 카테고리 수정(이름·색·아이콘·그룹) = `AddCategoryDialog.showEdit`, 삭제 차단 시 "대신 보관".
- 편집 시트 왼쪽 버튼 "닫기"(닫힘=저장), 이동 버튼은 편집 저장 await 후 이동.
- 일괄 붙여넣기 반복 유지(addAll 포함), 취소 시 직전 입력 복원.
- 캘린더 Google 오버레이는 `googleCalendarConnectedProvider` 일 때만 + `SilentCalendarAuth`(로그인 창 없음).
- 모바일 달력 기간 일정 = 5px 색 띠. 오늘 화면 섹션 간 드래그에 되돌리기.
- `ErrorState`(다시 시도) / `EmptyState(action:)` / 설정 계정·로그아웃 / 모바일 본문 큰 제목 제거 / labelSmall 12sp.
- 데스크탑: 할 일 카드 스와이프 삭제 없음(⋮ 메뉴로 삭제), 캘린더 패널 드래그는 6px 임계.

## 3. Phase 1 — 대표님 확정 결정 (2026-09-25)

| 항목 | 결정 |
|---|---|
| 할 일 한 줄 | **체크 하나 + 나머지 숨김.** 왼쪽 체크 하나(○ 미완료 / ◐ 진행중 반채움 / ● 완료). 탭 = 완료 토글. 진행중·하위추가·메뉴는 데스크탑 **마우스 올림(hover) + 우클릭 메뉴**, 폰은 **오른쪽 스와이프 = 완료, 길게 누르기 = 메뉴(진행중/이동/복사/삭제)** |
| 추가/편집 시트 | **2단: 빠른 입력 + 더보기.** 1단 = 제목 + 날짜 칩(오늘 / 내일(요일) / 다음주 월 / 📅) + ⏰ 시간 + 카테고리 드롭다운(헤더 우측) + 메모 전환. 더보기 = 설명·기간·반복·캘린더 등록·상태. 날짜 모드 칩(하루종일/시작/마감/기간) 제거 → 날짜 → 시간 → (선택) 종료 순. ⌘Enter 저장, 데스크탑 시간은 텍스트 입력 |
| 오늘 화면 완료 | **섹션 아래 "완료 N개" 접기.** 당일 완료는 오늘 화면에 남되 각 카테고리 섹션 맨 아래 접기 행 안으로 |

## 4. Phase 1 작업 목록 (권장 순서)

1. **TodoTile 재설계** (`lib/src/ui/widgets/todo_tile.dart` 619줄)
   - 체크 컴포넌트 신설: `TodoStatusCheck`(○/◐/●). `InProgressTriangle` 는 hover 버튼·메뉴로만.
   - 데스크탑: `MouseRegion` hover 시 △ ↳ ⋮ 표시, `onSecondaryTap` 우클릭 = 컨텍스트 메뉴(커서 위치 `showMenu`).
   - 모바일: 오른쪽 스와이프 = 완료(Dismissible startToEnd 는 confirmDismiss 에서 toggle 후 false 반환), 왼쪽 = 삭제(기존), 길게 누르기 = 바텀시트 메뉴.
     ⚠ 오늘 화면·드릴 리스트는 길게 누르기가 **순서 변경 드래그**(ReorderableDelayedDragStartListener)다. 충돌 해결 필요 — 예: 모바일 메뉴는 짧은 탭 후 편집 시트 안 ⋮ 로, 또는 드래그는 핸들로. 대표님께 확인 권장.
   - 메타 한 줄(시간 · 하위 N · 이월 · 반복), 제목 데스크탑 2줄 제한, 컬러바 3px, 완료 행은 전체 탈색.
   - 설명 있음 아이콘 ↔ 메모 타입 아이콘 이중 의미 분리.
   - 체크 시 Undo 스낵바.
   - 전체보기 `_OutlineNode`·타임라인 `_TimelineTile`·캘린더 패널 타일도 같은 체크 컴포넌트로 통일(가능하면 TodoTile compact 로 교체).
2. **추가/편집 시트 2단** (`lib/src/features/add_todo/add_todo_sheet.dart` 2700줄 — 큰 작업)
   - 데이터 모델(`_serializeDate`, dueAt/endAt/isAllDay/timeAnchor)은 유지하고 UI 만 재구성.
   - 편집 모드에서 반복 추가·수정은 Phase 1 범위 밖이면 표시만.
3. **오늘 화면** (`home_screen.dart`, `todo_category_sections.dart`)
   - 섹션별 "완료 N개" 접기 행 — ⚠ 오늘 화면은 **헤더+항목 단일 SliverReorderableList** 여야 섹션 간 드래그가 산다(메모리 today-screen-single-reorderable-list). 접기 행도 그 리스트 안의 비드래그 항목으로.
   - 진척 카드 → 한 줄 텍스트 + 얇은 바. 이월 배너에 행동(이월 항목 보기 / 닫기).
4. 매 항목 후 `dart analyze && dart format --set-exit-if-changed . && flutter test` 전부 확인 후 커밋.
5. 끝나면 전후 캡처(§6) → 대표님 확인 → `/merge-back-worktree` 는 대표님 지시 시에만.

## 5. 지켜야 할 기존 결정 (메모리)

- 순서는 명시적 조작으로만 — 정렬 키에 updatedAt 금지, 체크·진행중은 sortOrder 불변, 무변경 저장은 no-op.
- 편집 시트 닫힘 = 저장. 한 row 에 동시 writer 금지.
- 기능은 데스크탑·모바일 parity, 밀도(폭·줄수·터치타겟)만 `AppPlatform.isMobile` 분기. M3 IconButton 축소는 `tapTargetSize.shrinkWrap` 필요.
- 데스크탑 클릭 함정: 마우스 드래그 판정 1px — 카드에 Dismissible·즉시 Draggable 금지(`ClickTolerantDraggable` 사용). hover 버튼 추가 시에도 동일 원칙.
- 모바일 뒤로가기 = app_shell PopScope 계단.
- 설정 저장은 shared_preferences 패턴(SortModePreference) 복제.
- 반복 materializer 는 오늘/캘린더 화면 watch 에 묶여 있음(개선안 §4-2 #8, 아직 미처리).

## 6. 화면 캡처 방법

- 스크립트: `docs/ux-review/tools/ux_snapshot_test.dart` → `test/_ux_snapshot_test.dart` 로 복사(커밋 금지, 끝나면 삭제).
- 실행: `UX_SHOTS_OUT=<폴더> flutter test test/_ux_snapshot_test.dart --plain-name "desktop light"` ("mobile light", "empty states").
- ⚠ 테스트 종료 단계에서 플러그인 정리로 **멈춘다**. SHOT 개수(데스크탑 9, 모바일 10, 빈화면 1)가 다 찍히면 프로세스를 죽이는 watchdog 로 돌릴 것.
- 전후 비교 보관: `docs/ux-review/2026-09-24-shots/`(Phase 0 전), `...-shots-after/`(Phase 0 후). Phase 1 후는 `...-shots-phase1/`.
