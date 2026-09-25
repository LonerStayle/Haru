# mobile_ralph01 — ralph harness (v3-classic)

이 하네스는 js-ralph factory 의 template 에서 eject 되었다.
이 파일은 **자가완결**이다 — 부모 저장소를 참조하지 않는다.
Claude Code 가 매 세션 자동 로드하므로, ralph 의 매 iteration fresh context 에 항상 포함된다.

--- 

## 🔒 비전 인터뷰 상태 (gating)

```yaml
onboarded: true
onboarded_at: 2026-05-25T23:55:00+09:00
```

> `onboarded: false` 이면 ralph 는 매 iteration 첫 응답을 **비전 인터뷰** (`vision-intake` skill) 로 시작한다.
> 8 질문 답변 + "확정" 발화 후 vision-intake skill 이 위 값을 `true` + ISO 타임스탬프로 갱신하고 아래 "비전 / 사양" 섹션을 채운다.

---

## 비전 / 사양 (대표님 영역 — vision-intake 가 채움)

### 1. 비전
대표님(30대 개발자, 1인 사용)을 위한 **나만의 데스크탑·모바일 통합 Todo 앱**. macOS 데스크탑이 메인, Android 가 보조. UX 가 최강으로 편리하고 UI 가독성·가시성이 최대인 v1.0.0 완성품을 한 번에 만든다.

### 2. 대상 사용자
**30대 개발자 본인 (대표님, 1인 사용자)**. 업무 스타일은 "할 일 체크리스트를 적고 하나씩 처리해가는" 방식. 주 작업기기는 맥북, 보조로 Android 폰. 팀 공유나 협업은 일체 없는 개인 전용 도구.

### 3. 핵심 산출물

기본 동작
- 할 일 **추가 / 체크 / 삭제**
- **카테고리 분류** — 기본 5종 (① 회사 할일 ② 개인개발 할일 ③ 일상 할일 ④ 장기 목표 ⑤ 개인 아이디어) 제공 + **사용자가 자유롭게 추가 / 삭제 가능** (v1.2~). 기본 5종도 삭제 가능하며, 카테고리에 속한 할 일이 남아 있으면 삭제 차단. (※ v1.0~v1.1 은 "5종 고정" 이었으나 v1.2 에서 동적 카테고리로 확장)
- **오늘 할 일 위젯** (메인 화면에 항상 노출)
- **⌘⇧N 글로벌 단축키** — 어디서든 누르면 즉시 할 일 추가 입력창 호출. 하루 창 안에서는 **⌘N** 도 동작. (※ 2026-09-24 대표님 결정: 전역 ⌘N 은 다른 앱의 "새 창/새 파일" ⌘N 을 가로채서 전역만 ⌘⇧N 으로 변경)

이월 / 정리 로직 (핵심)
- 오늘 할 일 중 **체크 안 된 항목** → 다음날로 자동 이월
- **체크된 항목** → 당일 자정 지나면 오늘 화면에서 사라짐 (히스토리 보관)

연동
- **Google Calendar 연동** — 할 일에 날짜/시간 틀만 채워 넣으면 자동으로 캘린더에 등록될 만큼 UX 가 쉬워야 함 (UX 가 강조되는 영역)

### 4. 성공 정의

정성 기준 (최우선)
- **가독성·가시성** 최대치. 정말 편하다고 본인이 느낄 것.
- 매 iteration 자가 측정 두 지표:
  - **디자인 점수** (UI 가독성·가시성, 10점 만점)
  - **편의성 점수** (UX 단축 동작·반응성, 10점 만점)
- **두 점수 모두 9 이상** 도달 시 비전 충족 인정.

정량 기준
- 콜드 스타트 1초 이내 (macOS desktop)
- UI 프레임률 60fps 이상 (스크롤·애니메이션 끊김 없음)
- Supabase 실시간 동기화 — 한쪽에서 변경 시 다른쪽 5초 이내 반영
- 입력→저장 응답 200ms 이내 체감

릴리스 기준
- **v1.0.0 한 번에 완성** (점진 릴리스 없음. 첫 출시가 완성품)

### 5. 금지 / 범위 밖
- **iOS 버전 X** (macOS desktop + Android 만)
- **웹 버전 X** (Flutter desktop / mobile 만)
- **팀 공유 / 멀티유저 / 협업 기능 X** (개인 전용)
- **광고 / 결제 / 인앱구매 모듈 X**
- **Notion / Jira / Slack / Trello 등 외부 ToDo 도구 연동 X** (Google Calendar 만 예외적으로 허용)

### 6. 외부 의존
- **Supabase** — DB + Auth + Realtime 동기화. 대표님 개인 Supabase 프로젝트 사용. macOS ↔ Android 데이터 동기화의 단일 출처.
- **Google Calendar API** (OAuth2, calendar v3). 날짜/시간 입력 시 매우 쉬운 UX 로 캘린더에 자동 등록.

### 7. 규모·일정·비용 cap
- **ralph 자율 루프 최대 200 iteration**. v1.0.0 모든 비전 항목 완료까지 한 번에 진행.
- 매 iteration 끝에 디자인 점수·편의성 점수 자가 평가 (10점 만점). **두 지표 모두 9 이상** 도달 + 모든 `[x]` 시 `PROJECT_DONE` 출력.
- 그 전이라도 모든 plan 항목 `[x]` 가 되었으나 점수 9 미만이면, 점수 보강 task 를 `IMPLEMENTATION_PLAN.md` 끝에 자동 추가하여 계속 iteration.

### 8. 기술 스택

factory 디폴트 (Python+uv+FastAPI / React Vite / Android Kotlin / Postgres) 는 **전체 override**.

| 영역 | 결정 |
|------|------|
| **단일 코드베이스** | **Flutter (Dart)** — macOS `.app` + Android `.apk` 한 코드로 동시 빌드 |
| 데이터·인증·동기화 | **Supabase** (`supabase_flutter` SDK). 별도 백엔드 서버 없음. |
| 캘린더 연동 | `googleapis` (Calendar v3) + `google_sign_in` |
| macOS 글로벌 단축키 (⌘⇧N, 앱 안 ⌘N) | `hotkey_manager` + Flutter `Shortcuts` |
| 시스템 트레이 / 메뉴바 | `tray_manager` |
| macOS 네이티브 룩 보강 | `macos_ui` (Cupertino 톤) |
| 상태 관리 | `riverpod` |
| 로컬 캐시 (오프라인 대응) | `drift` (SQLite) |
| 로깅·에러 | `logger` |

별도 백엔드 (Python/FastAPI) 사용 안 함. Supabase 가 백엔드.

---

## 공통 — 5 파일 (Geoffrey 정석 4 + Claude Code 자동 로드 1)

| 파일 | 무엇 | 누가 만드나 |
|------|------|------------|
| 이 `CLAUDE.md` | **비전 + 환경 컨텍스트 + 호칭 톤** (Claude Code 자동 로드) | vision-intake skill 이 자동 합성 (위 섹션) |
| `PROMPT.md` | ralph 행동 매뉴얼 (도구 중립) | factory 가 박아둠. 사용자는 `<!-- signs -->` 표지판 한 줄만 누적 |
| `AGENTS.md` | 빌드/검증 명령 (60줄 이하) | 대표님 또는 ralph 첫 iteration |
| `IMPLEMENTATION_PLAN.md` | 현재 TODO 체크리스트 | ralph 99% 자동. 사람은 빈 파일만 시작 |
| `specs/*.md` | (선택) 도메인 추가 사양 — api.md / ui.md / data.md 등 | 대표님 또는 ralph 첫 iteration |

> v2 의 11 phase / 15 페르소나 / 14 skill / gate-verify framework 는 **의도적으로 제거**됨.

---

## 공통 — 4 원칙 (Geoffrey 정석)

| # | 원칙 | 이 하네스에서 구현 |
|---|------|--------------------|
| 1 | 단일 prompt + 자기 재투입 루프 | ralph-loop 플러그인의 Stop hook 이 매 iteration 동일 prompt 를 fresh context 로 재투입 |
| 2 | 사람이 작성한 파일 spec | 이 CLAUDE.md 의 "비전 / 사양" 섹션 (vision-intake 합성 후 동결) + (선택) `specs/*` |
| 3 | fresh context 매 iteration | ralph 는 앞 iteration 을 기억 X. 상태는 git + 4 파일에만 |
| 4 | deterministic backpressure | `AGENTS.md` 의 검증 명령 (lint/typecheck/tests). LLM 채점 없음 |

---

## 공통 — 매 iteration 흐름

`/ralph-loop:ralph-loop` 시작 후 매 iteration ralph 가 자동 진행:

```
이 CLAUDE.md (자동 로드) + PROMPT.md (Read) → §1 절차 따라:
  specs/ 읽기 → AGENTS.md 읽기 → IMPLEMENTATION_PLAN.md 읽기
  → 첫 [ ] task 선택 (없으면 비전 기반 plan 보강)
  → 구현
  → AGENTS.md 검증 명령 (모두 exit 0)
  → PASS 면 commit + [ ]→[x]
  → 종료 → Stop hook 재투입
```

종료 조건:
- 모든 비전 항목이 plan 에 반영되고 전부 `[x]` → `PROJECT_DONE` 출력
- `--max-iterations` 도달
- 대표님 명시 정지

---

## 공통 — 인수인계서 (HANDOFF.md)

v1.0.0 후속 (§ 10 보강) 단계 진입. 매 iter 시작 시 **`HANDOFF.md` 도 함께 Read** 한다.
외부 환경 상태 (Supabase / Xcode / env), 우선순위, 함정, 빌드 명령이 거기 있다.
§ 10 task 진행 / 외부 환경 변경 시 HANDOFF.md 도 동기화한다.

---

## 공통 — 사용자 호칭 / 톤

`PROMPT.md` 는 도구 중립이라 "사용자" 라고만 표기한다.
**이 CLAUDE.md 에서 "사용자 = 대표님" 으로 자동 치환**한다.

### 호칭
- 사용자 = **대표님 (방향 결정자)**
- 모든 응답·보고·커밋 메시지에 호칭은 "대표님" 으로 통일

### 톤
- 어투: 경어, 일관된 격식체. 반말 혼용 금지
- 길이: 응답·보고 3~5줄. 불필요한 수식어 제거
- 구조: 한 일 / 결과 / 다음 방향 분리
- 에러 메시지 그대로 노출 금지. "이런 결정이 필요합니다" 로 프레이밍
- 보고 첫 줄에 `대표님께:` prefix 권장 (필수 아님)

### 대표님 개입 시점 (2회)
1. **시작**: vision-intake 8 질문 답변 → 위 "비전 / 사양" 자동 합성 → "확정" 발화로 동결
2. **끝**: ralph 가 `PROJECT_DONE` 출력 후 결과물 검토

---

## 공통 — 기본 기술 스택 (factory 디폴트)

위 "8. 기술 스택" 에 override 명시 안 했으면 이 조합으로 진행한다.

| 영역 | 기본 |
|------|------|
| Backend | Python + uv + FastAPI + SQLAlchemy |
| Web Frontend | React (Vite + TypeScript) |
| Mobile App | Android (Kotlin, Android Studio). iOS / Flutter 의도적 포기 |
| Database | Postgres |
| 그 외 (인프라/CI/캐시) | 합리적 기본값 |

---

## 공통 — 신규 시작 체크리스트

- [ ] (1회) Claude Code 에 **ralph-loop 플러그인** 설치 — `/plugin install ralph-loop`
- [ ] `claude` 세션 열기 — ralph 가 vision-intake skill 자동 호출 (위 `onboarded: false` 트리거)
- [ ] 8 질문 답변 후 "확정" 발화 → 이 CLAUDE.md 의 "비전 / 사양" 자동 합성 + `onboarded: true`
- [ ] `AGENTS.md` 의 검증 명령 채우고 로컬에서 1회 exit 0 확인
- [ ] ralph-loop 시작:
  ```
  /ralph-loop:ralph-loop "Read PROMPT.md and follow it." --completion-promise "PROJECT_DONE" --max-iterations 150
  ```
- [ ] 첫 iteration 끝나고 `IMPLEMENTATION_PLAN.md` 에 `[ ]` 가 누적되는지 확인

---

## 공통 — 표지판

ralph 가 같은 실수를 반복하면 `PROMPT.md` 의 `<!-- signs -->` 섹션 아래에 한 줄 추가.
