# 앱 내 캘린더 화면 — 기술 설계

- 상위 문서: [`앱내캘린더-requirements.md`](./앱내캘린더-requirements.md)
- 작성일: 2026-08-15
- 기준 커밋: `main @ 4ec4ac7`

---

## 0. 조사로 확정된 전제

| # | 사실 | 설계 영향 |
|---|---|---|
| F-1 | 반복은 **하이브리드** — 과거~오늘 회차만 `todos` row, 미래 회차는 DB 에 없음 (`recurrence_materializer.dart:36-43` 에서 `until = min(오늘, recurrenceEndAt)`) | 미래 반복은 **런타임 고스트**로 그리고, 건드리는 순간 실체화 (R-9) |
| F-2 | `TodoActionsController.update()` 는 sortOrder 를 형제 min-1 로 **bump** (`todo_actions_controller.dart:66-85`) | 캘린더 드래그는 순서 조작이 아니므로 **전용 `setDueAt` 신설** |
| F-3 | `AddTodoSheet.show()` 가 `initialDueAt`/`initialAllDay` 를 위젯에 **전달하지 않음** (`add_todo_sheet.dart:88-117`) | `show()` 시그니처 확장이 "날짜 칸 → 그 날짜로 추가"의 유일한 병목 |
| F-4 | `calendar_service.dart` 에 **`events.list` 없음**. 스코프 `calendar.events` 는 읽기 포함 | 신규 파일로 조회만 추가, 재동의 불필요 |
| F-5 | `allTodosProvider` 는 `isSeriesMaster` 를 안 거름. timeline/outline 도 안 거름 (기존 버그) | 캘린더는 **반드시 직접 필터** |
| F-6 | `DragTarget<Todo>` 가 코드베이스에 없음 (`DragTarget<Category>` 만) | 캘린더가 최초 — 패턴은 `app_shell.dart:1650/1679/1511` 을 따름 |
| F-7 | Drift `schemaVersion` = 9 | **스키마 변경 없음** |
| F-8 | riverpod `^3.3.1`, 클래스 기반 `Notifier` 사용 (`sort_mode_controller.dart`) | 새 상태도 같은 스타일 |

---

## 1. 파일 구조

### 신규 — `lib/src/features/calendar_view/` (앱 내 캘린더 화면)
> 기존 `lib/src/features/calendar/` 는 **구글 연동 전용**이라 이름을 분리한다.
> 형제 워크트리 `구글캘린더동기화`와 디렉터리 자체가 달라 충돌 표면이 0 이다.

| 파일 | 책임 |
|---|---|
| `calendar_entry.dart` | 한 칸에 그려지는 항목의 통합 표현 (sealed) |
| `calendar_layout.dart` | **순수 함수** — 월 그리드 날짜 생성, 날짜별 버킷팅, 기간 막대 레인 배치 |
| `calendar_screen.dart` | 화면 셸 — 세그먼트 `[달력]/[목록]`, 데스크탑 좌우 / 모바일 상하 분기, 상태(포커스 달·선택일) 보유 |
| `calendar_month_grid.dart` | 월 그리드 (요일 헤더 + 6주 행), PageView 스와이프 |
| `calendar_week_row.dart` | 한 주 행 — 기간 막대 레인 + 날짜 셀 7개 |
| `calendar_day_cell.dart` | 날짜 셀 — 날짜 숫자, 오늘/선택 강조, 칩(데스크탑)/점(모바일), `DragTarget<Todo>` |
| `calendar_day_panel.dart` | 선택일 목록 + `＋ 이 날짜로 추가` |
| `calendar_undated_drawer.dart` | 하단 "날짜 없음" 서랍 |
| `calendar_drag.dart` | 드래그 페이로드 + 날짜 치환 규칙 (순수 함수) |

### 신규 — `lib/src/features/calendar/google_events_service.dart`
구글 이벤트 **조회 전용**. 기존 2파일은 읽기만 하고 수정하지 않는다.

### 수정 대상 (최소)
| 파일 | 변경 |
|---|---|
| `lib/src/ui/destination.dart` | `DestinationKind.timeline` → `calendar`, 라벨 '타임라인'→'캘린더', `isTimeline`→`isCalendar` |
| `lib/src/ui/app_shell.dart` | `_MainArea` 분기(L1744), `_Sidebar` index 분류(L1194/L1257), 모바일 nav 라벨(L554/L590) — **슬롯 수 불변** |
| `lib/src/features/add_todo/add_todo_sheet.dart` | `show()` 에 `initialDueAt` / `initialAllDay` 추가 (3줄) |
| `lib/src/features/todo_actions/todo_actions_controller.dart` | `setDueAt()` 신설 (sortOrder 보존) |
| `lib/src/domain/recurrence_materializer.dart` | `materializeOne()` 신설 (미래 1회차 실체화) |
| `lib/src/core/date_format.dart` | `KoDate.monthTitle` / `KoDate.dayWithWeekday` 추가 |
| `lib/src/features/timeline/timeline_screen.dart` | 세그먼트 안에 embed 되므로 자체 헤더 숨김 옵션 1개 추가 |

---

## 2. 도메인 — `CalendarEntry`

로컬 Todo / 미래 반복 고스트 / 구글 이벤트를 **한 리스트로** 다루기 위한 sealed 계층.
freezed 를 쓰지 않는다 — 순수 UI 뷰모델이라 codegen 비용만 늘고 얻는 게 없다.

```dart
sealed class CalendarEntry {
  DateTime get startDate;      // local date-only
  DateTime get endDate;        // local date-only, 단일이면 startDate 와 동일
  String get title;
  Color get color;
  bool get isDone;
  bool get isDraggable;        // 구글 이벤트 = false
  bool get spansMultipleDays => endDate.isAfter(startDate);
  String get entryKey;         // ValueKey 용 안정 식별자
}

class TodoEntry extends CalendarEntry { final Todo todo; }
class RecurringGhostEntry extends CalendarEntry { final Todo master; final DateTime date; }  // 미래 회차
class GoogleEventEntry extends CalendarEntry { final String id, summary; final DateTime s, e; final bool allDay; }
```

**정렬 규칙** (칸 안, 상한 계산 전) — `compareEntries`:
1. 기간 항목(막대) 먼저
2. **미완료 → 완료** — 칸에 상한(칩 3 / 점 4)이 있어서, 완료가 자리를 먹고 미완료가 `외 N건` 뒤로 밀리면 달력을 보는 이유가 사라진다. 그래서 시각보다 우선한다
3. 종일 → 시각 있는 항목 (시각 오름차순)
4. 같으면 `sortOrder asc → createdAt desc → entryKey asc` (전 앱 규칙, `updatedAt` 배제)

---

## 3. 순수 함수 — `calendar_layout.dart`

```dart
/// 6주 고정 42칸. 일요일 시작. 앞뒤 넘침 날짜 포함.
List<DateTime> monthGridDays(DateTime month);

/// Todo + 반복 고스트 + 구글 이벤트 → 날짜별 버킷.
/// 기간 항목은 걸친 모든 날짜 키에 동일 엔트리가 들어간다.
Map<DateTime, List<CalendarEntry>> bucketByDate({
  required List<CalendarEntry> entries,
  required DateTime rangeStart,
  required DateTime rangeEnd,
});

/// 한 주(7일) 안의 기간 막대를 겹치지 않게 레인에 배치 (greedy).
List<BarSegment> layoutWeekBars(List<CalendarEntry> multiDay, DateTime weekStart);
```

`BarSegment { entry, startCol(0~6), span(1~7), lane, continuesLeft, continuesRight }`
→ 주 경계에서 잘리고 다음 주 첫 칸에서 이어지는 표현(`continuesLeft/Right`)을 화살표로 그린다.

**6주 고정 근거**: 5주/6주가 달마다 바뀌면 스와이프 시 높이가 튄다. 항상 6행이면 PageView 가 안정적이고 R-7 의 "행 높이 균일" 도 자동 충족.

---

## 4. 엔트리 조립 파이프라인

```
allTodosProvider (StreamProvider)
  └─ calendarLocalEntriesProvider : Provider<AsyncValue<List<TodoEntry>>>
       .whenData 로 필터: !isSeriesMaster && dueAt != null
                        && !archivedCategoryIds.contains(category.id)

recurringMastersProvider (home/today_providers.dart:108)
  └─ (화면에서) 보이는 달 범위 × RecurrenceRule.isOccurrenceOn
       → 이미 실체화된 인스턴스 날짜는 제외 → RecurringGhostEntry

googleEventsProvider : FutureProvider.family<List<GoogleEventEntry>, CalendarRange>
  └─ 실패/미인증이면 const [] (화면을 막지 않는다)

  ⇓ 셋을 합쳐 bucketByDate
```

- **무날짜 서랍**: `calendarUndatedTodosProvider` — `dueAt == null && !isSeriesMaster && !archived`
- **자정 롤오버**: `currentDayProvider` 를 watch (`today_providers` 관용구)
- 파생은 전부 `Provider<AsyncValue<T>>` + `.whenData()` — base `StreamProvider` 는 건드리지 않는다 (재구독 → fakeAsync 테스트 붕괴 방지)

---

## 5. 화면 상태

포커스 달 / 선택일 / 세그먼트 / 서랍 펼침은 **`CalendarScreen` 의 State** 에 둔다.
전역 provider 로 빼지 않는 이유: R-1·R-6 이 "세션 내에서만 유지, 영속 저장 없음"이라 provider 수명이 오히려 과하고, 위젯 테스트가 상호작용만으로 전부 검증 가능하다.

```dart
DateTime _focusedMonth;   // 그 달 1일 (local)
DateTime _selectedDay;    // date-only, 기본 = 오늘
_Segment _segment;        // calendar | list
bool _undatedExpanded;    // 기본 false
bool _gridCollapsed;      // 모바일 전용 — 달력 접기
```

레이아웃:
- **데스크탑**: `Row([Expanded(flex:3, 월그리드), VerticalDivider, SizedBox(width:340, 선택일패널)])`, 하단에 무날짜 서랍
- **모바일**: `Column([월그리드(접기 가능), Expanded(선택일패널), 무날짜 서랍])`

---

## 6. 인터랙션 설계

| 요구 | 구현 |
|---|---|
| R-3-a 날짜 탭 | `_DayCell.onTap` → `setState(_selectedDay = d)`. 넘침 날짜 탭 시 `_focusedMonth` 도 함께 이동 |
| R-3-b 그 날짜로 추가 | 셀 **길게 누르기** + 패널의 `＋ 이 날짜로 추가` → `AddTodoSheet.show(..., initialDueAt: d, initialAllDay: true)` |
| R-3-c 드래그 날짜 변경 | 데스크탑 `Draggable<Todo>` / 모바일 `LongPressDraggable<Todo>` → 셀의 `DragTarget<Todo>` |
| R-3-d 월 이동 | 모바일 `PageView` 스와이프, 데스크탑 `←`/`→`, 공통 `‹ ›` 버튼 + `오늘`(T) |

### 날짜 치환 규칙 (`calendar_drag.dart`, 순수 함수)
```dart
Todo applyDateDrop(Todo t, DateTime newDate) {
  // 시각과 isAllDay 는 보존하고 '날짜 부분'만 교체한다.
  // 기간 항목은 기간 길이를 유지한 채 통째로 평행이동 (endAt 도 같은 delta).
}
```
- `isAllDay == true` → `DateTime(y, m, d)` (00:00 이 화면에 절대 안 찍히는 규칙은 `TodoDateLabel` 이 이미 보장)
- `endAt != null` → `endAt + (newDueAt - oldDueAt)`

### 단축키 충돌
`_ShortcutsHost` 가 숫자 0~9 와 `Cmd+F` 만 쓴다. `←`/`→`/`T` 는 캘린더 화면 **로컬 `Shortcuts`** 로 등록하고, `isFocusInEditableText()` 와 동일한 가드를 건다.

### 제스처 충돌 (Q-4)
좌우 스와이프는 `PageView` 가 월 그리드 영역에만 걸리므로, 하단 목록의 세로 스크롤과 축이 달라 충돌하지 않는다.

---

## 7. 미래 반복 실체화 (R-9)

```dart
// recurrence_materializer.dart 에 추가
/// 발생일 하나만 실체화 — 캘린더에서 미래 회차를 건드릴 때.
/// [materializeDue] 와 같은 [_instanceFor] 를 쓰므로 id 가 결정적이고,
/// 나중에 정규 실체화가 돌아도 같은 row 를 덮어쓸 뿐 중복이 생기지 않는다.
static Todo? materializeOne(Todo master, DateTime occLocalDate, DateTime now);
```

고스트 조작 흐름:
```
고스트 탭/체크/드래그
  → materializeOne(master, date, now)
  → repo.upsert(instance)
  → 그 다음 원래 동작(toggle / setDueAt / 편집 시트)을 실체 row 에 적용
```
`instanceId` 가 `seriesId#yyyymmdd` 로 결정적이라 중복이 원천 차단된다 (`recurrence_materializer.dart:59-67`).

**고스트 판정**: 보이는 달의 각 날짜 d 에 대해
`rule.isOccurrenceOn(d, master.dueAt!)` && `d > 오늘` && `recurrenceEndAt` 이내 && 이미 실체화된 날짜 집합에 없음

---

## 8. 구글 이벤트 조회 (R-5)

```dart
// lib/src/features/calendar/google_events_service.dart (신규)
class GoogleEventsService {
  GoogleEventsService(this._auth);
  final CalendarAuth _auth;

  /// [from, to) 범위의 primary 캘린더 이벤트. 실패 시 빈 리스트 (throw 하지 않는다).
  Future<List<GoogleEventEntry>> listRange(DateTime from, DateTime to);
}
final googleEventsServiceProvider = Provider<GoogleEventsService?>(...);   // auth 없으면 null
final googleEventsProvider = FutureProvider.family<List<GoogleEventEntry>, CalendarRange>(...);
```

- `events.list(calendarId: 'primary', timeMin:, timeMax:, singleEvents: true, orderBy: 'startTime', maxResults: 2500)`
  - `singleEvents: true` 로 반복 이벤트가 서버에서 이미 인스턴스로 펼쳐진다 → 클라이언트 반복 로직 불필요
- **client 는 반드시 `close()`** (`google_auth_service.dart:32` 계약)
- 실패는 전부 삼키고 `const []` — 미인증/네트워크/토큰만료가 캘린더 화면을 못 쓰게 만들면 안 된다 (R-5)
- Q-1 결정: **현재 달 ± 1개월**을 한 번에 받고 `family` 키로 캐시. 월 이동 시 캐시 미스만 재조회
- 화면 우상단 토글로 표시 on/off. 기본값 = `googleCalendarAvailableProvider` (현재 dead code 인 것을 여기서 처음 쓴다)

---

## 9. destination 교체 (R-1)

```dart
enum DestinationKind { today, category, outline, calendar }   // timeline → calendar
// buildAll: label '캘린더', icon Icons.calendar_month_outlined, digit 2 (그대로)
// 카테고리 digit 규칙 i < 7 ? i + 3 : -1 도 그대로 — 슬롯 수가 안 늘어난다
```
`app_shell.dart` 는 `isTimeline` → `isCalendar` 치환 + `_MainArea` 가 `CalendarScreen()` 을 반환하도록 1줄.
`TimelineScreen` 은 삭제하지 않고 세그먼트 `[목록]` 의 body 로 재사용한다.

---

## 10. 테스트 전략

| 대상 | 파일 | 검증 |
|---|---|---|
| 그리드 기하 | `test/src/features/calendar_view/calendar_layout_test.dart` | 42칸, 일요일 시작, 넘침 날짜, 월말 경계 |
| 버킷팅 | 〃 | 기간 항목이 걸친 날 전부에 들어감, seriesMaster 제외, 보관 제외, 정렬 순서 |
| 막대 레인 | 〃 | 겹침 시 레인 분리, 주 경계 `continuesLeft/Right` |
| 날짜 치환 | `calendar_drag_test.dart` | 시각 보존, allDay 보존, 기간 평행이동 |
| 고스트 실체화 | `test/src/domain/recurrence_materializer_test.dart` (기존 파일에 추가) | `materializeOne` id 결정성, 정규 실체화와 충돌 없음 |
| sortOrder 보존 | `test/src/features/todo_actions/..._test.dart` | `setDueAt` 후 sortOrder 불변, `update` 는 기존대로 bump |
| 화면 | `calendar_screen_test.dart` | 날짜 탭→패널 갱신, 세그먼트 전환, 서랍 펼침, 오늘/선택 강조 |
| 날짜 포맷 | `test/src/core/date_format_test.dart` (기존) | `monthTitle`, `dayWithWeekday` |
| destination | 기존 테스트 갱신 | timeline→calendar 이름/라벨 |

**key 규약** (`<화면>-<역할>-<id>`):
`calendar-cell-yyyyMMdd` / `calendar-chip-<entryKey>` / `calendar-dot-<entryKey>` /
`calendar-bar-<entryKey>` / `calendar-panel-tile-<id>` / `calendar-undated-tile-<id>` /
`calendar-segment-grid` / `calendar-segment-list` / `calendar-prev-month` / `calendar-next-month` /
`calendar-today-button` / `calendar-undated-header` / `calendar-add-on-day`

**구글 이벤트 테스트**: `googleEventsProvider` 를 override 해서 순수 렌더링만 검증. 네트워크는 타지 않는다.

---

## 11. 위험 / 완화

| 위험 | 완화 |
|---|---|
| destination rename 이 기존 테스트를 깨뜨림 | 첫 task 에서 rename 만 단독 커밋하고 전체 테스트로 확인 |
| 기간 막대 레이아웃이 복잡 | 레인 배치를 **순수 함수로 분리**해 위젯 없이 단위 테스트 |
| 미래 고스트 실체화가 동기화에 미치는 영향 | 기존 `materializeDue` 와 동일한 `_instanceFor`/`instanceId` 재사용 → 새로운 경로 없음 |
| 구글 조회가 UI 를 블로킹 | `FutureProvider` + 실패 시 빈 리스트. 로딩 중에도 로컬 항목은 즉시 렌더 |
| 모바일 셀 터치 타겟 | 셀 최소 높이를 `AppPlatform.isMobile` 로 분기 (48dp 이상) |
| `timeline_screen` 을 embed 할 때 헤더 중복 | `TimelineScreen({bool showHeader = true})` 파라미터 1개 추가 |

---

## 변경이력

| CH-id | 일시 | 종류 | 내용 |
|---|---|---|---|
| CH-001 | 2026-08-15 | 신규 | 조사 3건(구글연동/UI/데이터) 기반 최초 작성. F-1~F-8 전제 확정 |
