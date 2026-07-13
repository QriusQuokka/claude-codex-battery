# 🔋 Claude & Codex Usage Battery — Windows

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6?logo=windows&logoColor=white" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/runtime-PowerShell%205.1-5391FE?logo=powershell&logoColor=white" alt="PowerShell 5.1">
  <img src="https://img.shields.io/badge/dependencies-none-brightgreen.svg" alt="Zero dependencies">
</p>

> Windows **시스템 트레이**에 **Claude Code**와 **Codex**의 남은 사용량 한도를 배터리 아이콘으로 상시 표시합니다 — 더 이상 `/usage`를 열 필요가 없습니다.

이 프로젝트는 macOS SwiftBar 플러그인인 [dennykim123/claude-codex-battery](https://github.com/dennykim123/claude-codex-battery)를 **Windows로 포팅**한 것입니다. macOS에는 SwiftBar 메뉴바가 있지만 Windows에는 대응물이 없어, 동일한 UX를 **상주 PowerShell + 시스템 트레이 아이콘**으로 재구현했습니다.

각 배터리는 한 한도 창(window)의 **남은 %** 를 보여줍니다 — 가득 찬 초록은 여유, 빨강은 거의 소진. 아이콘을 **좌클릭**하면 리셋 시각까지 포함한 상세 게이지가 뜹니다.

- `C5` · `CW` · `CF` = Claude **5시간** · **주간** · **Fable(최상위 모델 주간 캡)**
- `X5` · `XW` = Codex **5시간** · **주간** (프리미엄 플랜은 크레딧 잔액)

**서드파티 의존성 0** — Windows에 기본 탑재된 PowerShell 5.1과 .NET(System.Drawing / WinForms)만 사용합니다. 아이콘은 GDI로 직접 그리며, `npm install`도, bun도, 별도 런타임도 필요 없습니다.

---

## 무엇을 보여주나

| 그룹 | 배터리 | 소스 |
|------|--------|------|
| **`C` Claude** | 5시간 세션 · 주간 · **Fable**(최상위 모델 주간 캡) | Anthropic **OAuth usage API** (`/usage`와 동일 소스) |
| **`X` Codex** | 5시간 · 주간 (프리미엄은 크레딧 잔액) | `~/.codex/sessions/**/*.jsonl` → `rate_limits` |

좌클릭 시 드롭다운(한도별):

```
Claude Code
  5시간 남음 ▕██████████████░░░░░░▏ 70%  (사용 30%)  ·  리셋 3h 18m
  주간 남음  ▕██████▋░░░░░░░░░░░░░▏ 33%  (사용 67%)  ·  리셋 3d 21h
  Fable 남음 ▕████░░░░░░░░░░░░░░░░▏ 26%  (사용 74%)  ·  리셋 3d 21h
```

색은 신호등: 남음 ≥ 50% 초록, < 50% 노랑, ≤ 20% 빨강.

리셋 시각은 지났지만 Codex가 아직 새 한도를 측정하지 못한 경우, 실제 100%로 오해하지 않도록
배터리를 **빈 외곽선 + `?`**로 표시합니다.

> **Windows 트레이 참고:** macOS 메뉴바처럼 넓은 이미지를 걸 수 없어, 한도마다 **개별 정사각 아이콘**으로 나뉩니다. Windows 11은 새 트레이 아이콘을 기본으로 `^`(숨겨진 아이콘) 안에 넣으므로, 처음 한 번 **작업표시줄로 끌어다 고정**해 주세요.

---

## 요구사항

| | 필요? | 비고 |
|---|---|---|
| **Windows 10/11** | ✅ | — |
| **PowerShell 5.1** | ✅ | 모든 Windows 10/11에 기본 탑재 |
| **Claude Code** | `C` 배터리에 필요 | `~/.claude/.credentials.json`(OAuth 토큰)이 있어야 함 — Claude Code 로그인 상태 |
| **Codex CLI** | 선택 | 있으면 `X` 배터리 표시. 없으면 Claude만 |
| **[ccusage](https://github.com/ryoppippi/ccusage)** | 선택 | 드롭다운에 비용/모델별 상세 추가 — **없어도 배터리는 정상** |

> 이 위젯은 *당신의 로컬 사용량*을 읽습니다. Claude Code를 안 쓰면 표시할 데이터가 없습니다.

---

## 설치

```powershell
git clone https://github.com/QriusQuokka/claude-codex-battery.git
cd claude-codex-battery
powershell -ExecutionPolicy Bypass -File install.ps1
```

`install.ps1`은:

1. 앱 파일을 `%LOCALAPPDATA%\claude-codex-battery\`에 복사
2. 시작프로그램에 등록(재부팅 후 자동 실행) — 콘솔 창 없이 뜨는 `launch-hidden.vbs` 런처 사용
3. 즉시 실행

몇 초 안에 트레이에 배터리가 나타납니다. **2분마다** 갱신됩니다. (`-NoAutostart` / `-NoLaunch` 옵션으로 각각 건너뛸 수 있습니다.)

갱신에 실패하면 트레이 툴팁과 메뉴에서 이유를 확인할 수 있습니다. 만료된 Claude 로그인은
`재로그인 필요`, API 제한은 `레이트 리밋 · N분 후 재시도`, 네트워크 장애는 마지막 측정 경과 시간으로 표시됩니다.

수동 실행만 원하면:

```powershell
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File claude-codex-battery-win.ps1 -Run
```

---

## 업데이트

포크 레포의 `VERSION`을 **하루 최대 1회** 확인합니다(백그라운드, 유일한 그 외 네트워크 호출). 새 버전이 있으면 드롭다운에 초록 **🆕 업데이트** 항목이 뜨고, 클릭하면 제자리에서 교체 후 재시작합니다(이전본은 `.bak` 보존).

직접 하려면: `git pull` 후 `install.ps1` 재실행.

완전히 끄려면 `claude-codex-battery-win.ps1` 상단의 `$EnableUpdateCheck = $false`.

---

## 프라이버시 & 보안

- **사용량 데이터는 기기 밖으로 나가지 않습니다.** 값을 읽어 로컬에서 렌더링합니다.
- **네트워크 호출은 딱 둘뿐입니다:**
  1. **Claude usage API** (`https://api.anthropic.com/api/oauth/usage`) — Claude Code 본인과 **동일한** 엔드포인트/토큰으로 당신 계정의 사용률만 read-only 조회. Windows에는 원본 macOS가 읽던 로컬 `usage-cache.json`이 없어 이 API가 유일한 소스입니다.
  2. **업데이트 체크** (GitHub `VERSION`) — 하루 1회.
- **둘 다 끌 수 있습니다:** 상단 상수 `$EnableUsageApi = $false`, `$EnableUpdateCheck = $false`. 둘 다 끄면 네트워크 호출이 **0**입니다.
- **비밀·대화 내용은 보내지 않습니다.** usage API 응답에는 사용률 %와 리셋 시각만 있습니다. Codex 로그에서는 `rate_limits` 숫자만 파싱합니다.
- API 호출은 `.credentials.json`의 OAuth 액세스 토큰을 `Authorization` 헤더로 사용합니다(Anthropic 자사 API로만 전송) — 이는 원본의 "자격증명 안 읽음" 정책에 대한 **명시적 예외**이며, Windows에 로컬 캐시가 없기 때문입니다. 원치 않으면 위처럼 끄십시오.

---

## 동작 방식

단일 PowerShell 스크립트가 타이머(2분)로 상주하며:

- **트레이 아이콘**은 `System.Drawing.Bitmap`에 캡슐/픽셀폰트 숫자를 그려 `GetHicon()`으로 아이콘화합니다. 핸들은 매 갱신마다 `DestroyIcon`으로 해제해 GDI 누수를 막습니다.
- **다크/라이트**는 레지스트리 `SystemUsesLightTheme`로 감지해 매 갱신 반영합니다.
- **Claude 한도**는 usage API 응답에서 옵니다. 응답은 원본이 읽던 `usage-cache.json`의 상위집합이라(`five_hour` / `seven_day` / `limits[]`), 파싱 로직을 거의 그대로 재사용했습니다. API는 공격적 rate-limit이 있어 **최소 5분 간격**으로만 호출하고 결과를 `%LOCALAPPDATA%\claude-codex-battery\usage-cache.json`에 캐시합니다.
- **Codex 한도**는 가장 최근 세션 로그의 `rate_limits`에서 옵니다.
- 데이터 조회는 별도 러너스페이스에서 실행하므로 느린 네트워크나 선택 의존성(`ccusage`)이 트레이 UI를 멈추지 않습니다.
- 사용량 캐시는 임시 파일 작성 후 원자적으로 교체하며, 손상된 업데이트 스크립트는 설치 전에 구문 검사로 차단합니다.

---

## 커스터마이즈 (스크립트 상단 상수)

| 바꾸고 싶은 것 | 위치 |
|---|---|
| Claude usage API on/off | `$EnableUsageApi` |
| 업데이트 체크 on/off | `$EnableUpdateCheck` |
| API 호출 최소 간격 | `$UsageApiThrottleSec` (기본 300초) |
| Codex 소진 시 자동 갱신 | `$CodexAutoRefresh` (기본 off) |
| 갱신 주기 | `Start-ResidentTray`의 `Timer.Interval` (기본 120000ms) |

---

## macOS 사용자

이 저장소는 **Windows 전용**입니다. macOS 메뉴바 버전은 원본 [upstream 프로젝트](https://github.com/dennykim123/claude-codex-battery)를 이용하세요.

## 라이선스

[MIT](LICENSE)
