<#
  Claude & Codex Usage Battery — Windows 트레이 위젯
  원본(macOS SwiftBar 플러그인 claude-codex-usage.2m.js, upstream: dennykim123)의 Windows 포팅.
  설계/판정 기준: docs/PORTING-PLAN.md

  이 파일은 단계적으로 완성된다:
    Phase 1 (현재): 데이터 수집 계층 (순수 함수) + -Probe 테스트 하네스
    Phase 2: 트레이 아이콘 렌더링 (System.Drawing + NotifyIcon)
    Phase 3: 상세 메뉴 (ContextMenuStrip)
    Phase 4: 상주 루프 / 설치 / 업데이트

  PowerShell 5.1 전제. 모든 데이터 함수는 어떤 입력에도 예외 없이 $null 또는 정상 객체를 반환한다.
#>

[CmdletBinding()]
param(
  # 테스트/디버그: 특정 데이터 함수의 결과를 JSON으로 덤프하고 종료.
  #   claude | codex | models | blocks | all
  [string]$Probe,
  # Get-ClaudeUsage가 스로틀을 무시하고 즉시 API를 호출하도록 강제.
  [switch]$ForceApi,
  # 렌더 검증: 샘플 배터리 아이콘들을 PNG로 저장 (Phase 2).
  [switch]$RenderTest,
  # 렌더 검증 출력 폴더.
  [string]$RenderOut,
  # 누수 검증: 아이콘 생성/해제를 N회 반복하며 GDI 핸들 수 보고 (Phase 2).
  [int]$LeakTest = 0,
  # 상주 트레이 앱 실행 (Phase 4). 설치본은 이 스위치로 기동.
  [switch]$Run,
  # 비차단 스모크 테스트: 트레이/메뉴 구성에 예외가 없는지 확인하고 종료 (Phase 3/4).
  [switch]$SelfTest
)

# ══════════════════════════════════════════════════════════════════
#  CONFIG — 상단 상수 (사용자가 조정하는 지점)
# ══════════════════════════════════════════════════════════════════
$script:VERSION            = '1.0.0-win'              # 이 Windows 포트의 버전
$script:EnableUsageApi     = $true                    # ★ Claude 사용량 API 호출 on/off (프라이버시 opt-out 지점)
$script:ClaudeUaVersion    = '2.1.206'                # User-Agent: claude-code/<이 값> (형식이 중요, 정확한 값은 무관)
$script:UsageApiThrottleSec = 300                     # API 최소 호출 간격(초). 429 방지 — 렌더보다 훨씬 길게.
$script:UsageApiMaxBackoff  = 3600                    # 429 시 지수 백오프 상한(초)
$script:CodexAutoRefresh   = $false                   # Codex 소진 시 백그라운드 자동 갱신(토큰 소모) — 기본 off
$script:EnableUpdateCheck  = $true                    # 24h 1회 GitHub VERSION 확인 (유일한 그외 네트워크 호출). $false로 완전 비활성

$script:HOME_DIR   = $env:USERPROFILE
$script:CLAUDE_DIR = Join-Path $script:HOME_DIR '.claude'
$script:CRED_FILE  = Join-Path $script:CLAUDE_DIR '.credentials.json'
$script:APP_DATA   = Join-Path $env:LOCALAPPDATA 'claude-codex-battery'
$script:USAGE_CACHE = Join-Path $script:APP_DATA 'usage-cache.json'
$script:USAGE_API_URL = 'https://api.anthropic.com/api/oauth/usage'

# ══════════════════════════════════════════════════════════════════
#  공용 유틸
# ══════════════════════════════════════════════════════════════════
function Get-UnixNow { [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }

function ConvertTo-UnixSeconds {
  param([string]$Iso)
  if ([string]::IsNullOrWhiteSpace($Iso)) { return $null }
  try { return [int64]([DateTimeOffset]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)).ToUnixTimeSeconds() }
  catch { return $null }
}

function Ensure-AppData {
  if (-not (Test-Path $script:APP_DATA)) {
    try { New-Item -ItemType Directory -Path $script:APP_DATA -Force | Out-Null } catch {}
  }
}

# 지속시간 포맷 ("3d 21h" / "3h 18m" / "45m" / "0m") — 원본 fmtDur 이식
function Format-Duration {
  param([double]$Seconds)
  if ($Seconds -le 0) { return '0m' }
  $h = [math]::Floor($Seconds / 3600)
  $m = [math]::Floor(($Seconds % 3600) / 60)
  if ($h -ge 24) { return ('{0}d {1}h' -f [math]::Floor($h / 24), ($h % 24)) }
  if ($h -gt 0)  { return ('{0}h {1}m' -f $h, $m) }
  return ('{0}m' -f $m)
}

# 토큰수 포맷 ("1.2B"/"3.4M"/"56K"/"789") — 원본 fmtTok 이식
function Format-Tokens {
  param([double]$N)
  if ($N -ge 1e9) { return ('{0:0.0}B' -f ($N / 1e9)) }
  if ($N -ge 1e6) { return ('{0:0.0}M' -f ($N / 1e6)) }
  if ($N -ge 1e3) { return ('{0:0}K'  -f ($N / 1e3)) }
  return ('{0}' -f [int]$N)
}

# 바이너리 탐지 (ccusage/codex 선택 의존) — 원본 findBin 이식
function Find-Bin {
  param([string]$Name, [string[]]$Extra = @())
  $cands = @()
  $cands += $Extra
  $cands += (Join-Path $script:HOME_DIR ".bun\bin\$Name.exe")
  $cands += (Join-Path $script:HOME_DIR ".bun\bin\$Name")
  $cands += (Join-Path $env:APPDATA "npm\$Name.cmd")
  $cands += (Join-Path $env:APPDATA "npm\$Name.ps1")
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
  try {
    $g = Get-Command $Name -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
  } catch {}
  return $null   # 없음 — 호출부에서 우아하게 축소
}

# ══════════════════════════════════════════════════════════════════
#  1. Claude 사용량 (OAuth usage API + 로컬 캐시 + 스로틀)
#     Phase 0 결과: 로컬 usage-cache 없음 → API가 주 소스.
#     API 응답은 원본 usage-cache.json의 상위집합 (docs/PORTING-PLAN.md §9.3)
# ══════════════════════════════════════════════════════════════════

# 캐시 파일 구조: { fetchedAt:<unix>, backoffUntil:<unix>, raw:<API 응답 그대로> }
function Read-UsageCache {
  if (-not (Test-Path $script:USAGE_CACHE)) { return $null }
  try { return (Get-Content $script:USAGE_CACHE -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Write-UsageCache {
  param($Obj)
  Ensure-AppData
  try { ($Obj | ConvertTo-Json -Depth 12 -Compress) | Set-Content -Path $script:USAGE_CACHE -Encoding UTF8 } catch {}
}

# API 1회 호출 — 성공 시 원본 응답 객체, 실패 시 $null (절대 throw 안 함)
function Invoke-UsageApi {
  if (-not $script:EnableUsageApi) { return $null }
  if (-not (Test-Path $script:CRED_FILE)) { return $null }
  $tok = $null
  try {
    $cred = Get-Content $script:CRED_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
    $tok = $cred.claudeAiOauth.accessToken
  } catch { return $null }
  if (-not $tok) { return $null }
  $headers = @{
    'Authorization'  = "Bearer $tok"
    'anthropic-beta' = 'oauth-2025-04-20'
    'Content-Type'   = 'application/json'
  }
  try {
    return (Invoke-RestMethod -Uri $script:USAGE_API_URL -Headers $headers `
              -UserAgent "claude-code/$script:ClaudeUaVersion" -Method GET -TimeoutSec 15)
  } catch {
    return $null   # 429/401/네트워크 — 호출부가 캐시로 폴백
  }
}

# API 원본 응답 → 원본 getClaudeUsage와 동일한 정규화 구조로 변환
#   { measuredAt, fiveHour:{pct,resetsAt}, weekly:{pct,resetsAt}, fable:{pct,resetsAt,model} }
function ConvertFrom-UsageRaw {
  param($Raw, [int64]$MeasuredAt)
  if (-not $Raw) { return $null }
  $win = {
    param($o)
    if ($null -eq $o) { return $null }
    [pscustomobject]@{ pct = [double]$o.utilization; resetsAt = (ConvertTo-UnixSeconds $o.resets_at) }
  }
  # 최상위 모델 주간 캡(weekly_scoped): limits[]에서 group=weekly && scope.model.display_name
  $fable = $null
  if ($Raw.limits) {
    foreach ($l in $Raw.limits) {
      $mdl = $null
      if ($l.scope -and $l.scope.model) { $mdl = $l.scope.model.display_name }
      if ($l.group -eq 'weekly' -and $mdl) {
        $fable = [pscustomobject]@{ pct = [double]$l.percent; resetsAt = (ConvertTo-UnixSeconds $l.resets_at); model = $mdl }
        break
      }
    }
  }
  [pscustomobject]@{
    measuredAt = $MeasuredAt
    fiveHour   = (& $win $Raw.five_hour)
    weekly     = (& $win $Raw.seven_day)
    fable      = $fable
  }
}

function Get-ClaudeUsage {
  [CmdletBinding()]
  param([switch]$Force)
  $now = Get-UnixNow
  $cache = Read-UsageCache
  $cacheAge = if ($cache -and $cache.fetchedAt) { $now - [int64]$cache.fetchedAt } else { [int64]::MaxValue }
  $backoffActive = ($cache -and $cache.backoffUntil -and ($now -lt [int64]$cache.backoffUntil))

  $shouldCall = $script:EnableUsageApi -and ($Force -or ($cacheAge -ge $script:UsageApiThrottleSec)) -and (-not $backoffActive -or $Force)

  if ($shouldCall) {
    $raw = Invoke-UsageApi
    if ($raw) {
      Write-UsageCache ([pscustomobject]@{ fetchedAt = $now; backoffUntil = 0; raw = $raw })
      return (ConvertFrom-UsageRaw -Raw $raw -MeasuredAt $now)
    } else {
      # 실패 → 백오프 갱신(캐시가 있을 때만), 이후 캐시로 폴백
      if ($cache) {
        $prev = if ($cache.backoffUntil -and ([int64]$cache.backoffUntil -gt $now)) { [int64]$cache.backoffUntil - $now } else { $script:UsageApiThrottleSec }
        $next = [math]::Min($prev * 2, $script:UsageApiMaxBackoff)
        $cache.backoffUntil = $now + $next
        Write-UsageCache $cache
      }
    }
  }

  # 캐시 폴백 (신선하든 오래됐든 — 오래됨은 measuredAt로 UI가 표시)
  if ($cache -and $cache.raw) {
    return (ConvertFrom-UsageRaw -Raw $cache.raw -MeasuredAt ([int64]$cache.fetchedAt))
  }
  return $null
}

# ══════════════════════════════════════════════════════════════════
#  2. Codex 사용량 (최신 세션 jsonl의 rate_limits) — 원본 getCodex 이식
# ══════════════════════════════════════════════════════════════════
function Get-CodexSessionsDir {
  if ($env:CODEX_HOME) { return (Join-Path $env:CODEX_HOME 'sessions') }
  return (Join-Path $script:HOME_DIR '.codex\sessions')
}

function Get-CodexUsage {
  $dir = Get-CodexSessionsDir
  if (-not (Test-Path $dir)) { return $null }
  $files = @()
  try {
    $files = Get-ChildItem $dir -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 8
  } catch { return $null }
  foreach ($f in $files) {
    # line-mode Get-Content는 함수 스코프에서 빈 결과를 내는 PS 5.1 기벽이 있어 -Raw로 읽고 직접 분할.
    # 대용량 세션 로그·BOM에도 이 방식이 더 견고하다.
    $content = $null
    try { $content = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop } catch { continue }
    if ([string]::IsNullOrEmpty($content)) { continue }
    $content = $content.TrimStart([char]0xFEFF)   # 혹시 남은 UTF-8 BOM 제거
    $lines = @($content -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
      if ($lines[$i] -notmatch 'rate_limits') { continue }
      $obj = $null
      try { $obj = $lines[$i] | ConvertFrom-Json } catch { continue }
      $rl = $null
      if ($obj.payload -and $obj.payload.rate_limits) { $rl = $obj.payload.rate_limits }
      elseif ($obj.rate_limits) { $rl = $obj.rate_limits }
      if ($rl -and ($rl.primary -or $rl.secondary -or $rl.credits)) {
        return [pscustomobject]@{
          measuredAt = [int64]([DateTimeOffset]::new($f.LastWriteTimeUtc, [TimeSpan]::Zero).ToUnixTimeSeconds())
          limitId    = $rl.limit_id
          plan       = $rl.plan_type
          primary    = $rl.primary
          secondary  = $rl.secondary
          credits    = $rl.credits
        }
      }
    }
  }
  return $null
}

# 창 상태 계산 — 원본 windowState 이식. { pct, resetsIn, stale }
function Get-CodexWindowState {
  param($W)
  if (-not $W) { return $null }
  $now = Get-UnixNow
  $stale = $false
  if ($W.resets_at) { $stale = ([double]$W.resets_at -lt $now) }
  $pct = if ($stale) { 0.0 } else { [double]$W.used_percent }
  $resetsIn = if ($W.resets_at) { [double]$W.resets_at - $now } else { $null }
  [pscustomobject]@{ pct = $pct; resetsIn = $resetsIn; stale = $stale }
}

# 소진 + 오래됨일 때만 백그라운드로 Codex를 굴려 리셋 감지 (원본 maybeAutoRefreshCodex 이식).
# 기본 off($script:CodexAutoRefresh=$false) — 토큰 소모를 원치 않으면 그대로 둠. 6h 스로틀.
function Invoke-CodexAutoRefresh {
  param($Codex)
  try {
    if (-not $script:CodexAutoRefresh) { return }
    if (-not $Codex) { return }
    $now = Get-UnixNow
    $exhausted = $false
    if ($Codex.credits) {
      $cr = $Codex.credits
      $exhausted = (-not $cr.unlimited) -and ((-not $cr.has_credits) -or ([double]$cr.balance -le 0))
    } else {
      $p = Get-CodexWindowState $Codex.primary
      $s = Get-CodexWindowState $Codex.secondary
      $exhausted = (($p -and $p.pct -ge 100) -or ($s -and $s.pct -ge 100))
    }
    if (-not $exhausted) { return }
    if (($now - $Codex.measuredAt) -lt 2*3600) { return }   # 2h+ 오래됐을 때만
    $tsFile = Join-Path $script:APP_DATA '.codex-refresh-ts'
    $last = 0
    if (Test-Path $tsFile) { try { $last = [int64]((Get-Content $tsFile -Raw).Trim()) } catch {} }
    if (($now - $last) -lt 6*3600) { return }               # 6h 스로틀 (하루 최대 4회)
    Ensure-AppData
    Set-Content -Path $tsFile -Value ([string]$now) -Encoding UTF8
    $codexBin = Find-Bin 'codex'
    if (-not $codexBin) { return }
    $cmd = 'echo reply ok | "{0}" exec --sandbox read-only --skip-git-repo-check -' -f $codexBin
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -WindowStyle Hidden
  } catch {}
}

# ══════════════════════════════════════════════════════════════════
#  3. ccusage (선택 의존) — 블록 비용 / 오늘 모델별. 없으면 $null.
# ══════════════════════════════════════════════════════════════════
$script:CCUSAGE_BIN = $null
function Get-CcusageBin {
  if ($null -eq $script:CCUSAGE_BIN) { $script:CCUSAGE_BIN = @(Find-Bin 'ccusage'); if (-not $script:CCUSAGE_BIN[0]) { $script:CCUSAGE_BIN = @('') } }
  if ($script:CCUSAGE_BIN[0]) { return $script:CCUSAGE_BIN[0] } else { return $null }
}

# 활성 5시간 블록 (비용/토큰/번레이트) — 원본 getClaude 이식
function Get-ClaudeBlocks {
  $bin = Get-CcusageBin
  if (-not $bin) { return $null }
  try {
    $raw = & $bin blocks --active --json 2>$null | Out-String
    $data = $raw | ConvertFrom-Json
    $b = $null
    if ($data.blocks) { $b = $data.blocks | Where-Object { $_.isActive } | Select-Object -First 1; if (-not $b) { $b = $data.blocks[0] } }
    if (-not $b) { return $null }
    $now = Get-UnixNow
    $startTs = ConvertTo-UnixSeconds $b.startTime
    $endTs   = ConvertTo-UnixSeconds $b.endTime
    $span = [math]::Max(1, $endTs - $startTs)
    $elapsedPct = [math]::Max(0, [math]::Min(100, (($now - $startTs) / $span) * 100))
    $remainMin = if ($b.projection -and $b.projection.remainingMinutes -ne $null) { $b.projection.remainingMinutes } else { [math]::Max(0, [math]::Floor(($endTs - $now) / 60)) }
    [pscustomobject]@{
      elapsedPct  = $elapsedPct
      remainMin   = $remainMin
      cost        = [double]($b.costUSD)
      tokens      = [double]($b.totalTokens)
      projCost    = if ($b.projection) { $b.projection.totalCost } else { $null }
      costPerHour = if ($b.burnRate) { $b.burnRate.costPerHour } else { $null }
    }
  } catch { return [pscustomobject]@{ error = ($_.Exception.Message -split "`n")[0] } }
}

$script:MODEL_NAMES = @{
  'claude-fable-5' = 'Fable 5'; 'claude-opus-4-8' = 'Opus 4.8'; 'claude-opus-4-7' = 'Opus 4.7'
  'claude-sonnet-5' = 'Sonnet 5'; 'claude-haiku-4-5-20251001' = 'Haiku 4.5'
}
function Get-ShortModel { param([string]$N) if ($script:MODEL_NAMES.ContainsKey($N)) { $script:MODEL_NAMES[$N] } else { ($N -replace '^claude-','') } }

# 오늘 모델별 사용 — 원본 getClaudeModels 이식
function Get-ClaudeModels {
  $bin = Get-CcusageBin
  if (-not $bin) { return $null }
  try {
    $ymd = (Get-Date).ToString('yyyyMMdd')
    $raw = & $bin daily --breakdown --json --since $ymd 2>$null | Out-String
    $day = ($raw | ConvertFrom-Json).daily | Select-Object -Last 1
    if (-not $day) { return $null }
    $models = @()
    foreach ($m in $day.modelBreakdowns) {
      $tokens = [double]$m.inputTokens + [double]$m.outputTokens + [double]$m.cacheCreationTokens + [double]$m.cacheReadTokens
      $models += [pscustomobject]@{ name = $m.modelName; cost = [double]$m.cost; tokens = $tokens }
    }
    $models = $models | Where-Object { $_.cost -gt 0.005 } | Sort-Object cost -Descending
    if (-not $models) { return $null }
    [pscustomobject]@{ models = $models; total = ($models | Measure-Object cost -Sum).Sum }
  } catch { return $null }
}

# ══════════════════════════════════════════════════════════════════
#  TEST 하네스 — -Probe 로 개별 함수 결과를 JSON 덤프하고 종료 (Phase 1 검증용)
# ══════════════════════════════════════════════════════════════════
if ($Probe) {
  $dump = {
    param($name, $val)
    Write-Host "── $name ─────────────────────────" -ForegroundColor Cyan
    if ($null -eq $val) { Write-Host '<null>' -ForegroundColor DarkGray }
    else { $val | ConvertTo-Json -Depth 10 }
    Write-Host ''
  }
  switch ($Probe.ToLower()) {
    'claude' { & $dump 'Get-ClaudeUsage'  (Get-ClaudeUsage -Force:$ForceApi) }
    'codex'  { & $dump 'Get-CodexUsage'   (Get-CodexUsage) }
    'models' { & $dump 'Get-ClaudeModels' (Get-ClaudeModels) }
    'blocks' { & $dump 'Get-ClaudeBlocks' (Get-ClaudeBlocks) }
    'all' {
      & $dump 'Get-ClaudeUsage'  (Get-ClaudeUsage -Force:$ForceApi)
      & $dump 'Get-CodexUsage'   (Get-CodexUsage)
      & $dump 'Get-ClaudeBlocks' (Get-ClaudeBlocks)
      & $dump 'Get-ClaudeModels' (Get-ClaudeModels)
    }
    default { Write-Host "알 수 없는 -Probe: $Probe (claude|codex|models|blocks|all)" -ForegroundColor Yellow }
  }
  return
}

# ══════════════════════════════════════════════════════════════════
#  Phase 2 — 트레이 아이콘 렌더링 (System.Drawing)
# ══════════════════════════════════════════════════════════════════
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

# GetHicon으로 만든 아이콘 핸들은 GDI 자원을 잡으므로 반드시 DestroyIcon으로 해제해야 함(누수 방지).
# GetGuiResources로 프로세스의 GDI 개체 수를 읽어 누수 검증에 사용.
if (-not ([System.Management.Automation.PSTypeName]'CCB.Native').Type) {
  Add-Type -Namespace CCB -Name Native -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
    public static extern bool DestroyIcon(System.IntPtr hIcon);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern uint GetGuiResources(System.IntPtr hProcess, uint uiFlags);
'@ -ErrorAction SilentlyContinue
}
function Get-GdiObjectCount {
  try { return [CCB.Native]::GetGuiResources([System.Diagnostics.Process]::GetCurrentProcess().Handle, 0) } catch { return -1 }
}

# 다크모드 감지 — 트레이는 System 테마를 따름(SystemUsesLightTheme). 값 0 = 다크.
function Test-DarkMode {
  try {
    $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -ErrorAction Stop
    return ($v.SystemUsesLightTheme -eq 0)
  } catch { return $true }  # 못 읽으면 다크 가정(밝은 잉크)
}

# 잔량 % → 실제 macOS 배터리 색 (원본 heatRemain 값 그대로). 반환: System.Drawing.Color
function Get-HeatColor {
  param([double]$Remain, [bool]$Dark)
  if ($Remain -le 20) { if ($Dark) { return [Drawing.Color]::FromArgb(255,69,58) }  else { return [Drawing.Color]::FromArgb(255,59,48) } }
  if ($Remain -lt 50) { if ($Dark) { return [Drawing.Color]::FromArgb(255,214,10) } else { return [Drawing.Color]::FromArgb(255,204,0) } }
  if ($Dark) { return [Drawing.Color]::FromArgb(48,209,88) } else { return [Drawing.Color]::FromArgb(52,199,89) }
}

# 4×6 픽셀 폰트 (원본 5×7 폰트 이식 + 라벨용 W·F 추가). 각 글자는 6행×4열.
$script:GLYPH = @{
  '0'=@('0110','1001','1001','1001','1001','0110'); '1'=@('0010','0110','0010','0010','0010','0111')
  '2'=@('0110','1001','0010','0100','1000','1111'); '3'=@('1110','0001','0110','0001','1001','0110')
  '4'=@('0010','0110','1010','1111','0010','0010'); '5'=@('1111','1000','1110','0001','1001','0110')
  '6'=@('0110','1000','1110','1001','1001','0110'); '7'=@('1111','0001','0010','0100','0100','0100')
  '8'=@('0110','1001','0110','1001','1001','0110'); '9'=@('0110','1001','1001','0111','0001','0110')
  'C'=@('0110','1001','1000','1000','1001','0110'); 'X'=@('1001','1001','0110','0110','1001','1001')
  'W'=@('1001','1001','1001','1011','1111','0110'); 'F'=@('1111','1000','1110','1000','1000','1000')
}
$script:GLYPH_W = 4; $script:GLYPH_H = 6

# 문자열을 픽셀 폰트로 그림. (x,y)=좌상단 논리좌표, sc=배율. boundaryX 지정 시 그 왼쪽은 altBrush(밝은 채움 위 대비).
function Draw-PixelString {
  param($G, [int]$X, [int]$Y, [string]$Str, $Sc, $Brush, $AltBrush, $BoundaryX)
  $cx = $X
  foreach ($ch in $Str.ToCharArray()) {
    $g6 = $script:GLYPH["$ch"]
    if ($g6) {
      for ($r = 0; $r -lt $script:GLYPH_H; $r++) {
        $row = $g6[$r]
        for ($c = 0; $c -lt $script:GLYPH_W; $c++) {
          if ($row[$c] -eq '1') {
            $px = $cx + $c
            $b = $Brush
            if ($AltBrush -and $null -ne $BoundaryX -and $px -lt $BoundaryX) { $b = $AltBrush }
            $G.FillRectangle($b, $px * $Sc, ($Y + $r) * $Sc, $Sc, $Sc)
          }
        }
      }
    }
    $cx += $script:GLYPH_W + 1
  }
  return $cx
}
function Measure-PixelString { param([string]$Str) return ($Str.Length * ($script:GLYPH_W + 1) - 1) }

# 배터리 아이콘 하나를 Bitmap으로 렌더. remain=잔량%, tag=창 식별 글자(5/W/F), dark, size(정사각 px).
#   가로 캡슐(테두리+좌측 채움) + 캡슐 안 잔량 2자리 숫자 + 좌상단 창 태그.
function New-BatteryBitmap {
  param([double]$Remain, [string]$Tag, [bool]$Dark, [int]$Size = 32)
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half

  $inkColor = if ($Dark) { [Drawing.Color]::FromArgb(235,235,235) } else { [Drawing.Color]::FromArgb(45,45,45) }
  $ink   = New-Object System.Drawing.SolidBrush($inkColor)
  $dkInk = New-Object System.Drawing.SolidBrush([Drawing.Color]::FromArgb(30,30,30))
  $fillColor = Get-HeatColor -Remain $Remain -Dark $Dark
  $fillBrush = New-Object System.Drawing.SolidBrush($fillColor)

  # 논리 그리드: 픽셀 폰트 배율 sc. size=32 → sc=2 (숫자 8px 높이). size=16 → sc=1.
  $sc = [math]::Max(1, [math]::Floor($Size / 16))

  # 상단 태그 밴드 + 하단 캡슐로 분리 (겹침 방지). 태그는 size>=24 에서만 표시.
  $showTag = ($Tag -and $Size -ge 24)
  $topPad = if ($showTag) { [int]($Size * 0.30) } else { [int]($Size * 0.14) }
  $botPad = [int]($Size * 0.12)
  $bx = [int]($Size * 0.05); $bw = [int]($Size * 0.82)
  $by = $topPad; $bh = $Size - $topPad - $botPad
  $border = [math]::Max(1, [int]($Size / 16))
  # 테두리 (사각 캡슐)
  $g.FillRectangle($ink, $bx, $by, $bw, $border)                       # 상
  $g.FillRectangle($ink, $bx, $by + $bh - $border, $bw, $border)       # 하
  $g.FillRectangle($ink, $bx, $by, $border, $bh)                       # 좌
  $g.FillRectangle($ink, $bx + $bw - $border, $by, $border, $bh)       # 우
  # 단자(nub)
  $nubH = [int]($bh * 0.4)
  $g.FillRectangle($ink, $bx + $bw, $by + [int](($bh - $nubH)/2), [math]::Max(1,[int]($Size/16)), $nubH)
  # 잔량 채움 (좌측부터)
  $innerX = $bx + $border; $innerY = $by + $border
  $innerW = $bw - 2 * $border; $innerH = $bh - 2 * $border
  $v = [math]::Max(0, [math]::Min(100, $Remain))
  $fw = [int][math]::Round(($v / 100) * $innerW)
  if ($fw -gt 0) { $g.FillRectangle($fillBrush, $innerX, $innerY, $fw, $innerH) }
  $fillBoundaryLogical = [int][math]::Floor(($innerX + $fw) / $sc)

  # 잔량 숫자 (캡슐 안, 가운데). 채움 위 픽셀은 어두운 잉크, 빈 배경 위는 ink → 어디서나 대비.
  $numStr = [string][int][math]::Round($v)
  $numWpx = (Measure-PixelString $numStr) * $sc
  $numXlogical = [int]([math]::Floor(($bx + ($bw - $numWpx)/2) / $sc))
  $numYlogical = [int]([math]::Floor(($by + ($bh - $script:GLYPH_H * $sc)/2) / $sc))
  Draw-PixelString -G $g -X $numXlogical -Y $numYlogical -Str $numStr -Sc $sc -Brush $ink -AltBrush $dkInk -BoundaryX $fillBoundaryLogical | Out-Null

  # 창 태그 (상단 밴드 중앙). 서비스(C/X)는 색/툴팁/순서로 구분.
  if ($showTag) {
    $tagSc = [math]::Max(1, [int]($Size / 20))
    $tagWpx = (Measure-PixelString $Tag) * $tagSc
    $tagXlogical = [int]([math]::Floor(($bx + ($bw - $tagWpx)/2) / $tagSc))
    $tagYlogical = [int]([math]::Floor((($topPad - $script:GLYPH_H * $tagSc)/2) / $tagSc))
    Draw-PixelString -G $g -X $tagXlogical -Y $tagYlogical -Str $Tag -Sc $tagSc -Brush $ink | Out-Null
  }

  $ink.Dispose(); $dkInk.Dispose(); $fillBrush.Dispose(); $g.Dispose()
  return $bmp
}

# Bitmap → [System.Drawing.Icon]. 반환 객체에 .Icon 과 해제용 .Handle 포함.
function New-BatteryIcon {
  param([double]$Remain, [string]$Tag, [bool]$Dark, [int]$Size = 32)
  $bmp = New-BatteryBitmap -Remain $Remain -Tag $Tag -Dark $Dark -Size $Size
  $hicon = $bmp.GetHicon()
  $icon = [System.Drawing.Icon]::FromHandle($hicon)
  $bmp.Dispose()
  return [pscustomobject]@{ Icon = $icon; Handle = $hicon }
}
# 아이콘 핸들 해제 (누수 방지) — 반드시 NotifyIcon에서 떼어낸 뒤 호출.
function Remove-BatteryIcon {
  param($IconObj)
  if (-not $IconObj) { return }
  try { if ($IconObj.Icon) { $IconObj.Icon.Dispose() } } catch {}
  try { if ($IconObj.Handle -ne [IntPtr]::Zero) { [CCB.Native]::DestroyIcon($IconObj.Handle) | Out-Null } } catch {}
}

# 사용량 데이터 → 배터리 아이템 목록. 원본 battItems 로직 이식.
#   각 아이템: key, tag(창 글자), remain, service, tip(툴팁)
function Get-BatteryItems {
  param($Usage, $Codex)
  $now = Get-UnixNow
  $items = @()
  $resetTip = {
    param($resetsAt)
    if (-not $resetsAt) { return '' }
    if ($resetsAt -lt $now) { return ' · 리셋됨' }
    return (' · 리셋 ' + (Format-Duration ($resetsAt - $now)))
  }
  if ($Usage) {
    if ($Usage.fiveHour) {
      $r = [math]::Max(0, 100 - $Usage.fiveHour.pct)
      $items += [pscustomobject]@{ key='C5'; tag='5'; remain=$r; service='claude'; tip=("Claude 5시간: {0}% 남음{1}" -f [int]$r, (& $resetTip $Usage.fiveHour.resetsAt)) }
    }
    if ($Usage.weekly) {
      $r = [math]::Max(0, 100 - $Usage.weekly.pct)
      $items += [pscustomobject]@{ key='CW'; tag='W'; remain=$r; service='claude'; tip=("Claude 주간: {0}% 남음{1}" -f [int]$r, (& $resetTip $Usage.weekly.resetsAt)) }
    }
    if ($Usage.fable) {
      $r = [math]::Max(0, 100 - $Usage.fable.pct)
      $items += [pscustomobject]@{ key='CF'; tag='F'; remain=$r; service='claude'; tip=("Claude {0}: {1}% 남음{2}" -f $Usage.fable.model, [int]$r, (& $resetTip $Usage.fable.resetsAt)) }
    }
  }
  if ($Codex) {
    $p = Get-CodexWindowState $Codex.primary
    $s = Get-CodexWindowState $Codex.secondary
    if ($p -or $s) {
      if ($p) {
        $r = [math]::Max(0, 100 - $p.pct)
        $tip = "Codex 5시간: {0}% 남음" -f [int]$r
        if ($p.stale) { $tip += ' · 리셋됨' } elseif ($p.resetsIn) { $tip += ' · 리셋 ' + (Format-Duration $p.resetsIn) }
        $items += [pscustomobject]@{ key='X5'; tag='5'; remain=$r; service='codex'; tip=$tip }
      }
      if ($s) {
        $r = [math]::Max(0, 100 - $s.pct)
        $tip = "Codex 주간: {0}% 남음" -f [int]$r
        if ($s.stale) { $tip += ' · 리셋됨' } elseif ($s.resetsIn) { $tip += ' · 리셋 ' + (Format-Duration $s.resetsIn) }
        $items += [pscustomobject]@{ key='XW'; tag='W'; remain=$r; service='codex'; tip=$tip }
      }
    } elseif ($Codex.credits) {
      $cr = $Codex.credits
      $remain = if ($cr.unlimited) { 100 } elseif ($cr.has_credits -and [double]$cr.balance -gt 0) { 100 } else { 0 }
      $tip = if ($cr.unlimited) { 'Codex 크레딧: 무제한' } elseif ($remain -gt 0) { "Codex 크레딧: 잔액 $($cr.balance)" } else { 'Codex 크레딧: 소진' }
      $items += [pscustomobject]@{ key='X'; tag='X'; remain=$remain; service='codex'; tip=$tip }
    }
  }
  # 콤마(,$items) 없이 반환 — 소비 측은 항상 @(...)로 감싸 배열 보장. 콤마는 다중 항목을 중첩시킴.
  return $items
}

# ══════════════════════════════════════════════════════════════════
#  TEST 하네스
# ══════════════════════════════════════════════════════════════════
if ($RenderTest) {
  $outDir = if ($RenderOut) { $RenderOut } else { Join-Path $env:TEMP 'ccb-render' }
  if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
  $samples = @(
    @{ tag='5'; remain=72 }, @{ tag='W'; remain=33 }, @{ tag='F'; remain=8 },
    @{ tag='5'; remain=100 }, @{ tag='X'; remain=54 }, @{ tag='W'; remain=19 }
  )
  # 크기별로 6개 샘플을 한 줄 스트립으로 (작업표시줄 유사 배경 위) — 현실적 가독성 판단용
  foreach ($dark in @($true,$false)) {
    foreach ($size in @(16,24,32,48)) {
      $gap = [math]::Max(2, [int]($size * 0.18))
      $w = $samples.Count * $size + ($samples.Count - 1) * $gap
      $strip = New-Object System.Drawing.Bitmap($w, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      $sg = [System.Drawing.Graphics]::FromImage($strip)
      $bg = if ($dark) { [Drawing.Color]::FromArgb(32,32,32) } else { [Drawing.Color]::FromArgb(235,235,235) }
      $sg.Clear($bg)
      $x = 0
      foreach ($sm in $samples) {
        $b = New-BatteryBitmap -Remain $sm.remain -Tag $sm.tag -Dark $dark -Size $size
        $sg.DrawImage($b, $x, 0); $b.Dispose(); $x += $size + $gap
      }
      $sg.Dispose()
      $theme = if ($dark) { 'dark' } else { 'light' }
      $strip.Save((Join-Path $outDir ("samples_{0}_{1}px.png" -f $theme, $size)), [System.Drawing.Imaging.ImageFormat]::Png)
      $strip.Dispose()
    }
  }
  # 실제 데이터로 한 줄(스트립) 합성 이미지도 생성 — 트레이에 나란히 뜰 모습 미리보기
  $usage = Get-ClaudeUsage
  $codex = Get-CodexUsage
  $items = Get-BatteryItems -Usage $usage -Codex $codex
  if ($items.Count -gt 0) {
    foreach ($dark in @($true,$false)) {
      $sz = 32; $gap = 6
      $strip = New-Object System.Drawing.Bitmap(($items.Count * $sz + ($items.Count-1)*$gap), $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      $sg = [System.Drawing.Graphics]::FromImage($strip)
      $bg = if ($dark) { [Drawing.Color]::FromArgb(30,30,30) } else { [Drawing.Color]::FromArgb(220,220,220) }
      $sg.Clear($bg)
      $x = 0
      foreach ($it in $items) {
        $b = New-BatteryBitmap -Remain $it.remain -Tag $it.tag -Dark $dark -Size $sz
        $sg.DrawImage($b, $x, 0); $b.Dispose(); $x += $sz + $gap
      }
      $sg.Dispose()
      $theme = if ($dark) { 'dark' } else { 'light' }
      $strip.Save((Join-Path $outDir ("strip_$theme.png")), [System.Drawing.Imaging.ImageFormat]::Png)
      $strip.Dispose()
    }
    Write-Host "실데이터 배터리: $(( $items | ForEach-Object { $_.key + '=' + [int]$_.remain } ) -join '  ')"
    Write-Host "툴팁 예시:"; $items | ForEach-Object { Write-Host ("  [{0}] {1}" -f $_.key, $_.tip) }
  }
  Write-Host "렌더 출력: $outDir"
  return
}

if ($LeakTest -gt 0) {
  # 워밍업: 어셈블리/GDI 초기화 1회성 오버헤드를 'before' 측정 전에 소진
  for ($i = 0; $i -lt 5; $i++) { $w = New-BatteryIcon -Remain 50 -Tag '5' -Dark $true -Size 32; Remove-BatteryIcon $w }
  [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
  $before = Get-GdiObjectCount
  for ($i = 0; $i -lt $LeakTest; $i++) {
    $ico = New-BatteryIcon -Remain (Get-Random -Min 0 -Max 100) -Tag '5' -Dark $true -Size 32
    Remove-BatteryIcon $ico
  }
  [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
  $after = Get-GdiObjectCount
  Write-Host ("GDI 개체 수  전: {0}  후: {1}  증가: {2}  (반복 {3}회)" -f $before, $after, ($after - $before), $LeakTest)
  return
}

# ══════════════════════════════════════════════════════════════════
#  Phase 3 — 상세 메뉴용 유니코드 게이지 + 색
# ══════════════════════════════════════════════════════════════════
$script:BAR_FULL = [char]0x2588            # █
$script:BAR_EMPTY = [char]0x2591           # ░
$script:BAR_PART = @('', [char]0x258F, [char]0x258E, [char]0x258D, [char]0x258C, [char]0x258B, [char]0x258A, [char]0x2589)

# 잔량 % → 부분블록 게이지 문자열 (원본 bar 이식)
function Get-Bar {
  param([double]$Pct, [int]$W)
  $Pct = [math]::Max(0, [math]::Min(100, $Pct))
  $filled = ($Pct / 100) * $W
  $fb = [math]::Floor($filled)
  $idx = [int][math]::Round(($filled - $fb) * 8)
  if ($idx -eq 8) { $fb++; $idx = 0 }
  $fb = [math]::Min($fb, $W)
  $s = ([string]$script:BAR_FULL) * $fb
  $used = $fb
  if ($idx -gt 0 -and $fb -lt $W) { $s += $script:BAR_PART[$idx]; $used++ }
  $s += ([string]$script:BAR_EMPTY) * [math]::Max(0, $W - $used)
  return $s
}

# 잔량 % → 메뉴 텍스트 색 (원본 heatRemainHex → Color). 다크 기준 신호색.
function Get-HeatRemainColor {
  param([double]$Remain)
  if ($Remain -le 20) { return [Drawing.Color]::FromArgb(255,69,58) }
  if ($Remain -lt 50) { return [Drawing.Color]::FromArgb(255,214,10) }
  return [Drawing.Color]::FromArgb(48,209,88)
}

# ══════════════════════════════════════════════════════════════════
#  Phase 4 — 자동 시작(시작프로그램 바로가기) 토글
# ══════════════════════════════════════════════════════════════════
$script:SELF_PATH = $MyInvocation.MyCommand.Path
$script:SELF_DIR  = if ($script:SELF_PATH) { Split-Path -Parent $script:SELF_PATH } else { $PWD.Path }
$script:STARTUP_LNK = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Codex Battery.lnk'

function Test-Autostart { return (Test-Path $script:STARTUP_LNK) }
function Set-Autostart {
  param([bool]$On)
  try {
    if ($On) {
      $vbs = Join-Path $script:SELF_DIR 'launch-hidden.vbs'
      $ws = New-Object -ComObject WScript.Shell
      $lnk = $ws.CreateShortcut($script:STARTUP_LNK)
      if (Test-Path $vbs) {
        $lnk.TargetPath = 'wscript.exe'
        $lnk.Arguments = ('"{0}"' -f $vbs)
      } else {
        # vbs 없으면 powershell 숨김 실행으로 폴백
        $lnk.TargetPath = (Join-Path $PSHOME 'powershell.exe')
        $lnk.Arguments = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Run' -f $script:SELF_PATH)
      }
      $lnk.WorkingDirectory = $script:SELF_DIR
      $lnk.Description = 'Claude & Codex Usage Battery'
      $lnk.Save()
    } else {
      if (Test-Path $script:STARTUP_LNK) { Remove-Item -LiteralPath $script:STARTUP_LNK -Force }
    }
    return $true
  } catch { return $false }
}

# ══════════════════════════════════════════════════════════════════
#  Phase 4 — 업데이트 체크 (24h 스로틀, 포크 레포 VERSION)
# ══════════════════════════════════════════════════════════════════
$script:UPDATE_CACHE = Join-Path $script:APP_DATA '.update-check.json'
$script:REPO_RAW = 'https://raw.githubusercontent.com/QriusQuokka/claude-codex-battery/main'
function Compare-Version {
  param([string]$A, [string]$B)
  $pa = ($A -replace '[^0-9.]','').Split('.'); $pb = ($B -replace '[^0-9.]','').Split('.')
  for ($i = 0; $i -lt 3; $i++) {
    $x = if ($i -lt $pa.Count -and $pa[$i]) { [int]$pa[$i] } else { 0 }
    $y = if ($i -lt $pb.Count -and $pb[$i]) { [int]$pb[$i] } else { 0 }
    if ($x -gt $y) { return 1 }; if ($x -lt $y) { return -1 }
  }
  return 0
}
# 캐시만 읽어 업데이트 여부 반환 (네트워크 없음 — UI 스레드에서 매번 호출해도 안전)
function Get-UpdateInfo {
  $cache = $null
  if (Test-Path $script:UPDATE_CACHE) { try { $cache = Get-Content $script:UPDATE_CACHE -Raw | ConvertFrom-Json } catch {} }
  $latest = if ($cache) { $cache.latest } else { $null }
  $has = ($latest -and (Compare-Version $latest $script:VERSION) -gt 0)
  return [pscustomobject]@{ latest = $latest; hasUpdate = $has }
}
# 24h 스로틀 백그라운드 버전 확인. 이전 잡을 정리해 누적 방지. 상주 타이머가 매 틱 호출(자기 스로틀).
function Start-UpdateCheck {
  if (-not $script:EnableUpdateCheck) { return }
  $cache = $null
  if (Test-Path $script:UPDATE_CACHE) { try { $cache = Get-Content $script:UPDATE_CACHE -Raw | ConvertFrom-Json } catch {} }
  $age = if ($cache -and $cache.checkedAt) { (Get-UnixNow) - [int64]$cache.checkedAt } else { [int64]::MaxValue }
  if ($age -le 24*3600) { return }
  try { Get-Job -Name 'ccbUpdateCheck' -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue } catch {}
  try {
    Start-Job -Name 'ccbUpdateCheck' -ScriptBlock {
      param($url, $cacheFile, $now)
      try {
        $latest = (Invoke-RestMethod -Uri "$url/VERSION" -TimeoutSec 8).ToString().Trim()
        if ($latest) { ([pscustomobject]@{ checkedAt = $now; latest = $latest } | ConvertTo-Json -Compress) | Set-Content -Path $cacheFile -Encoding UTF8 }
      } catch {}
    } -ArgumentList $script:REPO_RAW, $script:UPDATE_CACHE, (Get-UnixNow) | Out-Null
  } catch {}
}

# ══════════════════════════════════════════════════════════════════
#  Phase 3 — 상세 메뉴(ContextMenuStrip) 구성
# ══════════════════════════════════════════════════════════════════
$script:MONO = New-Object System.Drawing.Font('Consolas', 9)
$script:MONO_SM = New-Object System.Drawing.Font('Consolas', 8)

function Add-Label {
  param($Menu, [string]$Text, $Color, $Font)
  $it = New-Object System.Windows.Forms.ToolStripMenuItem
  $it.Text = $Text
  if ($Color) { $it.ForeColor = $Color }
  $it.Font = if ($Font) { $Font } else { $script:MONO }
  $Menu.Items.Add($it) | Out-Null
  return $it
}

# 사용량 → ContextMenuStrip (원본 드롭다운 레이아웃 이식)
function Build-DetailMenu {
  param($Usage, $Codex, $Models, $Blocks)
  $now = Get-UnixNow
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $menu.ShowImageMargin = $false
  $gray = [Drawing.Color]::FromArgb(139,148,158)

  $hasClaude = [bool]$Usage
  $hasCodex  = [bool]$Codex

  # 범례
  $legend = @()
  if ($hasClaude) { $legend += 'C5·CW·CF = Claude 5시간·주간·Fable' }
  if ($hasCodex)  { $legend += 'X5·XW = Codex 5시간·주간' }
  if ($legend.Count) { Add-Label $menu ('🔋 남은 %  ·  ' + ($legend -join '  ·  ')) $gray $script:MONO_SM | Out-Null; $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null }

  # Claude 섹션
  if ($hasClaude) {
    Add-Label $menu 'Claude Code' $gray $script:MONO | Out-Null
    $winRow = {
      param($label, $w)
      if (-not $w) { return }
      $r = [math]::Max(0, 100 - $w.pct)
      $reset = ''
      if ($w.resetsAt) { $reset = if ($w.resetsAt -lt $now) { '  ·  리셋됨' } else { '  ·  리셋 ' + (Format-Duration ($w.resetsAt - $now)) } }
      $txt = ('{0} ▕{1}▏ {2}%  (사용 {3}%){4}' -f $label, (Get-Bar $r 20), [int]$r, [int]$w.pct, $reset)
      Add-Label $menu $txt (Get-HeatRemainColor $r) $script:MONO | Out-Null
    }
    & $winRow '5시간 남음' $Usage.fiveHour
    & $winRow '주간 남음 ' $Usage.weekly
    if ($Usage.fable) { & $winRow ('{0} 남음' -f $Usage.fable.model) $Usage.fable }
    Add-Label $menu ('측정 {0} 전 (Claude 실시간)' -f (Format-Duration ($now - $Usage.measuredAt))) $gray $script:MONO_SM | Out-Null
    if ($Blocks -and -not $Blocks.error) {
      Add-Label $menu ('블록 비용  ${0:0.00}  ·  {1} 토큰' -f $Blocks.cost, (Format-Tokens $Blocks.tokens)) $gray $script:MONO_SM | Out-Null
    }
    if ($Models -and $Models.models.Count) {
      Add-Label $menu ('오늘 모델별  ·  합 ${0:0}' -f $Models.total) $gray $script:MONO_SM | Out-Null
      $maxCost = [math]::Max($Models.models[0].cost, 0.01)
      foreach ($m in $Models.models) {
        $g = Get-Bar (($m.cost / $maxCost) * 100) 12
        Add-Label $menu ('{0,-9}▕{1}▏ ${2:0.0}  {3}' -f (Get-ShortModel $m.name), $g, $m.cost, (Format-Tokens $m.tokens)) $null $script:MONO | Out-Null
      }
    }
    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
  }

  # Codex 섹션
  if ($hasCodex) {
    $planStr = if ($Codex.plan) { ' · ' + $Codex.plan } elseif ($Codex.limitId) { ' · ' + $Codex.limitId } else { '' }
    Add-Label $menu ('Codex' + $planStr) $gray $script:MONO | Out-Null
    $p = Get-CodexWindowState $Codex.primary
    $s = Get-CodexWindowState $Codex.secondary
    if (-not $p -and -not $s -and $Codex.credits) {
      $cr = $Codex.credits
      if ($cr.unlimited) { Add-Label $menu '크레딧  무제한' (Get-HeatRemainColor 100) $script:MONO | Out-Null }
      elseif (-not $cr.has_credits -or [double]$cr.balance -le 0) { Add-Label $menu '크레딧  소진 · 한도 초과 (0)' (Get-HeatRemainColor 0) $script:MONO | Out-Null }
      else { Add-Label $menu ("크레딧  잔액 {0}" -f $cr.balance) (Get-HeatRemainColor 100) $script:MONO | Out-Null }
    }
    $cxRow = {
      param($label, $st)
      if (-not $st) { return }
      $r = [math]::Max(0, 100 - $st.pct)
      $reset = if ($st.stale) { '  ·  리셋됨' } elseif ($st.resetsIn) { '  ·  리셋 ' + (Format-Duration $st.resetsIn) } else { '' }
      Add-Label $menu ('{0} ▕{1}▏ {2}%  (사용 {3}%){4}' -f $label, (Get-Bar $r 20), [int]$r, [int]$st.pct, $reset) (Get-HeatRemainColor $r) $script:MONO | Out-Null
    }
    & $cxRow '5시간 남음' $p
    & $cxRow '주간 남음 ' $s
    $age = $now - $Codex.measuredAt
    $staleWarn = $age -gt 3*3600
    $warnTxt = if ($staleWarn) { '  ·  ⚠ 리셋됐을 수 있음, Codex 쓰면 갱신' } else { ' (Codex 세션 기준)' }
    Add-Label $menu ('측정 {0} 전{1}' -f (Format-Duration $age), $warnTxt) (if ($staleWarn) { [Drawing.Color]::FromArgb(210,153,34) } else { $gray }) $script:MONO_SM | Out-Null
    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
  }

  if (-not $hasClaude -and -not $hasCodex) {
    Add-Label $menu 'Claude Code나 Codex를 실행하면 사용량이 표시됩니다' $gray $script:MONO_SM | Out-Null
    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
  }

  # 업데이트 (있을 때만)
  $upd = Get-UpdateInfo
  if ($upd.hasUpdate) {
    $u = New-Object System.Windows.Forms.ToolStripMenuItem
    $u.Text = ('🆕 v{0} 업데이트 (현재 v{1})' -f $upd.latest, $script:VERSION)
    $u.ForeColor = [Drawing.Color]::FromArgb(40,150,63)
    $u.Add_Click({ try { Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:SELF_DIR 'ccb-update.ps1')) } catch {} })
    $menu.Items.Add($u) | Out-Null
  }

  # 액션 항목
  $refresh = New-Object System.Windows.Forms.ToolStripMenuItem; $refresh.Text = '🔄 지금 새로고침'
  $refresh.Add_Click({ Update-Tray -Force }); $menu.Items.Add($refresh) | Out-Null

  $auto = New-Object System.Windows.Forms.ToolStripMenuItem; $auto.Text = '시작 시 자동 실행'
  $auto.Checked = (Test-Autostart); $auto.CheckOnClick = $true
  $auto.Add_Click({ Set-Autostart -On ($this.Checked) | Out-Null }); $menu.Items.Add($auto) | Out-Null

  $quit = New-Object System.Windows.Forms.ToolStripMenuItem; $quit.Text = '종료'
  $quit.Add_Click({ Stop-ResidentTray }); $menu.Items.Add($quit) | Out-Null

  $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
  Add-Label $menu ('v{0}  ·  Claude & Codex Usage Battery' -f $script:VERSION) $gray $script:MONO_SM | Out-Null

  return $menu
}

# ══════════════════════════════════════════════════════════════════
#  Phase 4 — 상주 트레이 관리
# ══════════════════════════════════════════════════════════════════
$script:Tray = @{ NIs = @(); IconObjs = @(); Menu = $null; Timer = $null; Mutex = $null }

function New-PlaceholderBitmap {
  param([bool]$Dark, [int]$Size = 32)
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::Transparent)
  $inkC = if ($Dark) { [Drawing.Color]::FromArgb(150,150,150) } else { [Drawing.Color]::FromArgb(120,120,120) }
  $ink = New-Object System.Drawing.SolidBrush($inkC)
  $bw = [int]($Size*0.82); $bh = [int]($Size*0.5); $bx = [int]($Size*0.05); $by = [int](($Size-$bh)/2)
  $b = [math]::Max(1,[int]($Size/16))
  $g.FillRectangle($ink,$bx,$by,$bw,$b); $g.FillRectangle($ink,$bx,$by+$bh-$b,$bw,$b)
  $g.FillRectangle($ink,$bx,$by,$b,$bh); $g.FillRectangle($ink,$bx+$bw-$b,$by,$b,$bh)
  $g.FillRectangle($ink, $bx+[int]($bw*0.35), $by+[int]($bh/2)-$b, [int]($bw*0.3), 2*$b)  # 대시
  $ink.Dispose(); $g.Dispose(); return $bmp
}

function Update-Tray {
  param([switch]$Force)
  try {
    $usage = Get-ClaudeUsage -Force:$Force
    $codex = Get-CodexUsage
    $models = Get-ClaudeModels
    $blocks = Get-ClaudeBlocks
    Invoke-CodexAutoRefresh $codex
    Start-UpdateCheck
    $dark = Test-DarkMode
    $size = try { [System.Windows.Forms.SystemInformation]::SmallIconSize.Height } catch { 16 }
    if ($size -lt 16) { $size = 16 }
    $items = @(Get-BatteryItems -Usage $usage -Codex $codex)

    # 새 아이콘 준비 (없으면 placeholder 1개)
    $newIcons = @()
    if ($items.Count -eq 0) {
      $bmp = New-PlaceholderBitmap -Dark $dark -Size $size
      $h = $bmp.GetHicon(); $ic = [System.Drawing.Icon]::FromHandle($h); $bmp.Dispose()
      $newIcons += [pscustomobject]@{ Icon = $ic; Handle = $h; Tip = 'Claude Code나 Codex 실행 시 표시' }
    } else {
      foreach ($it in $items) {
        $io = New-BatteryIcon -Remain $it.remain -Tag $it.tag -Dark $dark -Size $size
        $io | Add-Member -NotePropertyName Tip -NotePropertyValue $it.tip -Force
        $newIcons += $io
      }
    }

    # NotifyIcon 개수 조정
    while ($script:Tray.NIs.Count -lt $newIcons.Count) {
      $ni = New-Object System.Windows.Forms.NotifyIcon
      $ni.Add_MouseUp({ param($sender,$e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { if ($script:Tray.Menu) { $script:Tray.Menu.Show([System.Windows.Forms.Cursor]::Position) } } })
      $script:Tray.NIs += $ni
    }
    while ($script:Tray.NIs.Count -gt $newIcons.Count) {
      $ni = $script:Tray.NIs[-1]; $ni.Visible = $false; $ni.Dispose()
      $script:Tray.NIs = $script:Tray.NIs[0..($script:Tray.NIs.Count-2)]
    }

    # 메뉴 재구성 (이전 것 정리)
    $oldMenu = $script:Tray.Menu
    $script:Tray.Menu = Build-DetailMenu -Usage $usage -Codex $codex -Models $models -Blocks $blocks

    # 아이콘/툴팁 적용 + 이전 아이콘 핸들 해제
    for ($i = 0; $i -lt $newIcons.Count; $i++) {
      $ni = $script:Tray.NIs[$i]
      $ni.Icon = $newIcons[$i].Icon
      $tip = [string]$newIcons[$i].Tip; if ($tip.Length -gt 63) { $tip = $tip.Substring(0,63) }
      $ni.Text = $tip
      $ni.ContextMenuStrip = $script:Tray.Menu
      $ni.Visible = $true
    }
    foreach ($old in $script:Tray.IconObjs) { Remove-BatteryIcon $old }
    $script:Tray.IconObjs = $newIcons
    if ($oldMenu) { try { $oldMenu.Dispose() } catch {} }
  } catch {
    # 렌더 실패는 조용히 — 다음 틱에 재시도 (원본의 우아한 축소)
  }
}

function Stop-ResidentTray {
  try { if ($script:Tray.Timer) { $script:Tray.Timer.Stop() } } catch {}
  foreach ($ni in $script:Tray.NIs) { try { $ni.Visible = $false; $ni.Dispose() } catch {} }
  foreach ($io in $script:Tray.IconObjs) { Remove-BatteryIcon $io }
  try { if ($script:Tray.Menu) { $script:Tray.Menu.Dispose() } } catch {}
  [System.Windows.Forms.Application]::Exit()
}

function Start-ResidentTray {
  # 단일 인스턴스 (named mutex)
  $created = $false
  $script:Tray.Mutex = New-Object System.Threading.Mutex($true, 'Global\ClaudeCodexBatteryWin', [ref]$created)
  if (-not $created) { return }  # 이미 실행 중 → 조용히 종료
  Ensure-AppData
  [System.Windows.Forms.Application]::EnableVisualStyles()
  $script:Tray.Timer = New-Object System.Windows.Forms.Timer
  $script:Tray.Timer.Interval = 120000   # 2분
  $script:Tray.Timer.Add_Tick({ Update-Tray })
  Update-Tray          # 초기 렌더
  $script:Tray.Timer.Start()
  [System.Windows.Forms.Application]::Run()
  # 종료 정리
  try { $script:Tray.Mutex.ReleaseMutex() } catch {}
}

# ══════════════════════════════════════════════════════════════════
#  스모크 테스트 (-SelfTest): 트레이/메뉴 구성 예외 없음 확인 후 종료 (비차단)
# ══════════════════════════════════════════════════════════════════
if ($SelfTest) {
  $err = @()
  try {
    Ensure-AppData
    $usage = Get-ClaudeUsage; $codex = Get-CodexUsage
    $items = @(Get-BatteryItems -Usage $usage -Codex $codex)
    Write-Host ("배터리 아이템 수: {0}  ({1})" -f $items.Count, (($items | ForEach-Object { $_.key }) -join ','))
    $menu = Build-DetailMenu -Usage $usage -Codex $codex -Models (Get-ClaudeModels) -Blocks (Get-ClaudeBlocks)
    Write-Host ("메뉴 항목 수: {0}" -f $menu.Items.Count)
    Write-Host "── 메뉴 텍스트 미리보기 ──"
    foreach ($it in $menu.Items) { if ($it -is [System.Windows.Forms.ToolStripSeparator]) { Write-Host '  ----------' } else { Write-Host ('  ' + $it.Text) } }
    $menu.Dispose()
    # NotifyIcon 생성/표시 없이 아이콘 객체만 검증
    $dark = Test-DarkMode
    foreach ($it in $items) { $io = New-BatteryIcon -Remain $it.remain -Tag $it.tag -Dark $dark -Size 32; Remove-BatteryIcon $io }
    Write-Host "SelfTest: 예외 없음 ✅"
  } catch { $err += $_; Write-Host ("SelfTest 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red; Write-Host $_.ScriptStackTrace }
  return
}

# ══════════════════════════════════════════════════════════════════
#  진입점 — 상주 실행은 -Run 일 때만 (dot-source/테스트 시 기동 안 함)
# ══════════════════════════════════════════════════════════════════
if ($Run) { Start-ResidentTray }

