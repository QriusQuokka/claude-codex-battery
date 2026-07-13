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
$script:VERSION            = '1.1.0-win'              # 이 Windows 포트의 버전
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

# 로그 파일 append (조용한 실패 진단용) — 절대 throw 안 함, 모달 없음.
function Write-CcbLog {
  param([string]$Message)
  try {
    Ensure-AppData
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path (Join-Path $script:APP_DATA 'ccb.log') -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
  } catch {}
}

# API 응답 필드가 숫자가 아닐 수도 있음("", "N/A", 형식 변경 등) — throw 대신 $null.
function ConvertTo-SafeDouble {
  param($Value)
  if ($null -eq $Value) { return $null }
  try { return [double]$Value } catch { return $null }
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

# Claude usage API 실패를 툴팁/메뉴에서 같은 문구로 표시한다.
function Format-ClaudeFailure {
  param($Failure, $MeasuredAt)
  if (-not $Failure) { return '' }
  $now = Get-UnixNow
  if ($Failure.kind -eq 'auth') { return '⚠ 재로그인 필요 — Claude Code에서 /login' }
  if ($Failure.kind -eq 'rateLimit') {
    $retryAt = 0
    try { $retryAt = [int64]$Failure.retryAt } catch {}
    $mins = if ($retryAt -gt $now) { [math]::Max(1, [int][math]::Ceiling(($retryAt - $now) / 60.0)) } else { 1 }
    return ('⚠ 레이트 리밋 — {0}분 후 재시도' -f $mins)
  }
  if ($MeasuredAt) { return ('⚠ 갱신 실패 — 마지막 측정 {0} 전' -f (Format-Duration ($now - [int64]$MeasuredAt))) }
  return '⚠ 갱신 실패 — 측정 기록 없음'
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

# 외부 프로세스를 타임아웃과 함께 실행하고 표준출력을 반환. 시간 초과 시 프로세스를 죽이고 $null 반환.
# ccusage 같은 선택 의존 바이너리(npm .cmd shim → Node 콜드스타트)가 무한정 걸리는 것을 방지.
function Invoke-ExternalCommand {
  param([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutMs = 10000)
  if (-not $FilePath) { return $null }
  try {
    $quote = { param($s) if ($s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' } else { $s } }
    $argStr = (($ArgumentList | ForEach-Object { & $quote $_ }) -join ' ')
    $ext = [System.IO.Path]::GetExtension($FilePath)
    if ($ext) { $ext = $ext.ToLowerInvariant() }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($ext -eq '.cmd' -or $ext -eq '.bat') {
      # .cmd/.bat shim(npm 글로벌 설치)은 cmd.exe를 통해야 함 — 직접 실행하면 Win32Exception.
      $psi.FileName = (Join-Path $env:SystemRoot 'System32\cmd.exe')
      $psi.Arguments = '/d /c ""{0}" {1}"' -f $FilePath, $argStr
    } elseif ($ext -eq '.ps1') {
      $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
      $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $FilePath, $argStr
    } else {
      $psi.FileName = $FilePath
      $psi.Arguments = $argStr
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    [void]$p.StandardError.ReadToEndAsync()   # 버퍼 적체로 인한 데드락 방지 — 반드시 소비
    if (-not $p.WaitForExit($TimeoutMs)) {
      try { $p.Kill() } catch {}
      try { $p.Dispose() } catch {}
      return $null
    }
    $out = $outTask.GetAwaiter().GetResult()
    try { $p.Dispose() } catch {}
    return $out
  } catch { return $null }
}

# ══════════════════════════════════════════════════════════════════
#  1. Claude 사용량 (OAuth usage API + 로컬 캐시 + 스로틀)
#     Phase 0 결과: 로컬 usage-cache 없음 → API가 주 소스.
#     API 응답은 원본 usage-cache.json의 상위집합 (docs/PORTING-PLAN.md §9.3)
# ══════════════════════════════════════════════════════════════════

# 캐시 파일 구조:
# { fetchedAt:<unix>, backoffUntil:<unix>, backoffInterval:<sec>, raw:<API 응답 그대로>,
#   failure:{ kind:auth|rateLimit|network, statusCode, failedAt, retryAt } }
function Read-UsageCache {
  if (-not (Test-Path $script:USAGE_CACHE)) { return $null }
  try { return (Get-Content $script:USAGE_CACHE -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Write-UsageCache {
  param($Obj)
  Ensure-AppData
  $tmp = $script:USAGE_CACHE + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  $bak = $tmp + '.bak'
  try {
    $json = $Obj | ConvertTo-Json -Depth 12 -Compress
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path $script:USAGE_CACHE) {
      # 같은 볼륨의 File.Replace는 독자가 중간 JSON을 볼 틈 없이 원자적으로 교체한다.
      # .NET Framework(PS 5.1)의 File.Replace는 backupFileName=$null을 허용하지 않는다.
      [System.IO.File]::Replace($tmp, $script:USAGE_CACHE, $bak, $true)
      try { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } catch {}
    } else {
      [System.IO.File]::Move($tmp, $script:USAGE_CACHE)
    }
  } catch {
    try { if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force } } catch {}
    try { if (Test-Path $bak) { Remove-Item -LiteralPath $bak -Force } } catch {}
  }
}

# API 1회 호출 — 항상 { ok, raw, failure } 반환 (절대 throw 안 함).
# failure를 값으로 반환해야 캐시를 거쳐 트레이 UI까지 실패 원인을 보낼 수 있다.
function Invoke-UsageApi {
  if (-not $script:EnableUsageApi) { return [pscustomobject]@{ ok=$false; raw=$null; failure=$null } }
  $now = Get-UnixNow
  $authFailure = { [pscustomobject]@{ kind='auth'; statusCode=401; failedAt=$now; retryAt=0 } }
  if (-not (Test-Path $script:CRED_FILE)) { return [pscustomobject]@{ ok=$false; raw=$null; failure=(& $authFailure) } }
  $tok = $null
  try {
    $cred = Get-Content $script:CRED_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
    $tok = $cred.claudeAiOauth.accessToken
  } catch { return [pscustomobject]@{ ok=$false; raw=$null; failure=(& $authFailure) } }
  if (-not $tok) { return [pscustomobject]@{ ok=$false; raw=$null; failure=(& $authFailure) } }
  $headers = @{
    'Authorization'  = "Bearer $tok"
    'anthropic-beta' = 'oauth-2025-04-20'
    'Content-Type'   = 'application/json'
  }
  try {
    $raw = Invoke-RestMethod -Uri $script:USAGE_API_URL -Headers $headers `
              -UserAgent "claude-code/$script:ClaudeUaVersion" -Method GET -TimeoutSec 15
    return [pscustomobject]@{ ok=$true; raw=$raw; failure=$null }
  } catch {
    $status = 0
    $retryAt = 0
    try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch {}
    if ($status -eq 429) {
      # Retry-After가 초 또는 HTTP 날짜일 수 있다. 읽지 못하면 호출부의 지수 백오프를 사용한다.
      try {
        $retryAfter = $_.Exception.Response.Headers['Retry-After']
        [int64]$retrySec = 0
        if ($retryAfter -and [int64]::TryParse([string]$retryAfter, [ref]$retrySec)) {
          $retryAt = $now + [math]::Max(0, $retrySec)
        } elseif ($retryAfter) {
          $retryDate = [DateTimeOffset]::MinValue
          if ([DateTimeOffset]::TryParse([string]$retryAfter, [ref]$retryDate)) { $retryAt = $retryDate.ToUnixTimeSeconds() }
        }
      } catch {}
    }
    $kind = if ($status -eq 401) { 'auth' } elseif ($status -eq 429) { 'rateLimit' } else { 'network' }
    $failure = [pscustomobject]@{ kind=$kind; statusCode=$status; failedAt=$now; retryAt=$retryAt }
    return [pscustomobject]@{ ok=$false; raw=$null; failure=$failure }
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
    $pct = ConvertTo-SafeDouble $o.utilization
    if ($null -eq $pct) { return $null }   # 형식이 바뀌었으면 이 창은 건너뜀 — throw 대신 축소
    [pscustomobject]@{ pct = $pct; resetsAt = (ConvertTo-UnixSeconds $o.resets_at) }
  }
  # 최상위 모델 주간 캡(weekly_scoped): limits[]에서 group=weekly && scope.model.display_name
  $fable = $null
  if ($Raw.limits) {
    foreach ($l in $Raw.limits) {
      $mdl = $null
      if ($l.scope -and $l.scope.model) { $mdl = $l.scope.model.display_name }
      if ($l.group -eq 'weekly' -and $mdl) {
        $pct = ConvertTo-SafeDouble $l.percent
        if ($null -ne $pct) {
          $fable = [pscustomobject]@{ pct = $pct; resetsAt = (ConvertTo-UnixSeconds $l.resets_at); model = $mdl }
          break
        }
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
    $api = Invoke-UsageApi
    if ($api.ok -and $api.raw) {
      Write-UsageCache ([pscustomobject]@{ fetchedAt = $now; backoffUntil = 0; backoffInterval = 0; raw = $api.raw; failure = $null })
      return (ConvertFrom-UsageRaw -Raw $api.raw -MeasuredAt $now)
    } else {
      # 실패 → 백오프 갱신. 캐시 유무와 무관하게 반드시 기록해야 최초 실행(dead token 등)에서도
      # 재시도가 폭주하지 않는다. 직전 백오프 "간격"(interval, deadline이 아님)을 이어받아야
      # 300→600→1200→…→cap 으로 실제 두 배씩 늘어난다.
      # 이미 기록된 간격이 있으면 그걸 두 배로, 없으면(최초 실패) 기준값에서 시작 — 300→600→1200→…→cap.
      $next = if ($cache -and $cache.backoffInterval -and [int64]$cache.backoffInterval -gt 0) {
        [math]::Min([int64]$cache.backoffInterval * 2, $script:UsageApiMaxBackoff)
      } else {
        $script:UsageApiThrottleSec
      }
      $updated = if ($cache) { $cache } else { [pscustomobject]@{ fetchedAt = $null; raw = $null } }
      if ($api.failure) {
        if (-not $api.failure.retryAt) { $api.failure.retryAt = $now + $next }
        $updated | Add-Member -NotePropertyName failure -NotePropertyValue $api.failure -Force
      }
      # 서버가 Retry-After를 줬다면 로컬 백오프보다 이른 재호출을 하지 않는다.
      $backoffUntil = $now + $next
      if ($api.failure -and [int64]$api.failure.retryAt -gt $backoffUntil) { $backoffUntil = [int64]$api.failure.retryAt }
      $updated | Add-Member -NotePropertyName backoffUntil -NotePropertyValue $backoffUntil -Force
      $updated | Add-Member -NotePropertyName backoffInterval -NotePropertyValue $next -Force
      Write-UsageCache $updated
      $cache = $updated
    }
  }

  # 캐시 폴백 (신선하든 오래됐든 — 오래됨은 measuredAt로 UI가 표시)
  if ($cache -and $cache.raw) {
    $usage = ConvertFrom-UsageRaw -Raw $cache.raw -MeasuredAt ([int64]$cache.fetchedAt)
    if ($usage -and $cache.failure) { $usage | Add-Member -NotePropertyName refreshError -NotePropertyValue $cache.failure -Force }
    return $usage
  }
  # 첫 호출부터 실패한 경우에도 상태 전용 객체를 반환해 메뉴/툴팁이 이유를 표시하게 한다.
  if ($cache -and $cache.failure) {
    return [pscustomobject]@{ measuredAt=$null; fiveHour=$null; weekly=$null; fable=$null; refreshError=$cache.failure }
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

# 파일 꼬리에서 최대 MaxBytes만 읽음 — 세션 로그 전체를 메모리에 올리지 않기 위함(누적 세션 길이에 비례한 비용 방지).
function Read-TailText {
  param([string]$Path, [int64]$MaxBytes = 131072)
  try {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $len = $fs.Length
      $take = [Math]::Min($MaxBytes, $len)
      if ($take -le 0) { return '' }
      $fs.Seek(-$take, [System.IO.SeekOrigin]::End) | Out-Null
      $buf = New-Object byte[] $take
      $readTotal = 0
      while ($readTotal -lt $take) {
        $n = $fs.Read($buf, $readTotal, $take - $readTotal)
        if ($n -le 0) { break }
        $readTotal += $n
      }
      return [System.Text.Encoding]::UTF8.GetString($buf, 0, $readTotal)
    } finally { $fs.Dispose() }
  } catch { return $null }
}

# 파일 하나에서 최신 rate_limits 라인을 찾음. 꼬리부터 점증 탐색(128K→512K→2M) — 전체 파일을 읽지 않음.
function Find-RateLimitsInFile {
  param([string]$Path)
  foreach ($capBytes in 131072, 524288, 2097152) {
    $text = Read-TailText -Path $Path -MaxBytes $capBytes
    if ([string]::IsNullOrEmpty($text)) { return $null }
    $full = ($text.Length -lt $capBytes)   # 파일 전체를 이미 다 읽었으면 더 키워도 무의미
    $text = $text.TrimStart([char]0xFEFF)  # 혹시 남은 UTF-8 BOM 제거
    $lines = @($text -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
      if ($lines[$i] -notmatch 'rate_limits') { continue }
      $obj = $null
      try { $obj = $lines[$i] | ConvertFrom-Json } catch { continue }
      $rl = $null
      if ($obj.payload -and $obj.payload.rate_limits) { $rl = $obj.payload.rate_limits }
      elseif ($obj.rate_limits) { $rl = $obj.rate_limits }
      if ($rl -and ($rl.primary -or $rl.secondary -or $rl.credits)) { return $rl }
    }
    if ($full) { return $null }
  }
  return $null
}

function Get-CodexUsage {
  $dir = Get-CodexSessionsDir
  if (-not (Test-Path $dir)) { return $null }
  $files = @()
  try {
    # Codex는 세션을 <sessions>/YYYY/MM/DD/rollout-*.jsonl 로 날짜 파티션한다.
    # 오늘/어제 폴더만 훑어 매 틱 전체 트리를 재귀 나열하는 비용(전체 세션 이력에 비례)을 피한다.
    $today = Get-Date
    $dayDirs = @()
    foreach ($d in @($today, $today.AddDays(-1))) {
      $p = Join-Path (Join-Path (Join-Path $dir $d.ToString('yyyy')) $d.ToString('MM')) $d.ToString('dd')
      if (Test-Path $p) { $dayDirs += $p }
    }
    if ($dayDirs.Count -gt 0) {
      foreach ($dd in $dayDirs) {
        $files += Get-ChildItem $dd -Filter *.jsonl -File -ErrorAction SilentlyContinue
      }
      $files = $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 8
    } else {
      # 예상 밖 레이아웃 폴백 — 기존처럼 전체 재귀
      $files = Get-ChildItem $dir -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 8
    }
  } catch { return $null }
  foreach ($f in $files) {
    $rl = Find-RateLimitsInFile -Path $f.FullName
    if ($rl) {
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

# Codex 자동 갱신 프로세스는 UI 스레드에서 기다리지 않고 추적만 한다. 5분을 넘기면 다음 틱에 종료해
# 멈춘 codex가 고아 프로세스로 남지 않게 한다.
$script:CodexRefreshProcess = $null
$script:CodexRefreshStartedAt = 0
function Clear-CodexRefreshProcess {
  param([switch]$Force)
  $p = $script:CodexRefreshProcess
  if (-not $p) { return $false }
  $done = $false
  try { $done = $p.HasExited } catch { $done = $true }
  $expired = ($script:CodexRefreshStartedAt -and ((Get-UnixNow) - $script:CodexRefreshStartedAt -ge 300))
  if (-not $done -and -not $Force -and -not $expired) { return $true }
  if (-not $done) {
    # .cmd npm shim 아래의 node 자식까지 함께 종료한다. 부모 cmd만 Kill하면 node가 고아로 남는다.
    try {
      $killer = Join-Path $env:SystemRoot 'System32\taskkill.exe'
      $kp = Start-Process -FilePath $killer -ArgumentList '/PID',([string]$p.Id),'/T','/F' -WindowStyle Hidden -PassThru -Wait
      $kp.Dispose()
    } catch { try { $p.Kill() } catch {} }
  }
  try { $p.Dispose() } catch {}
  $script:CodexRefreshProcess = $null
  $script:CodexRefreshStartedAt = 0
  return $false
}

function Start-CodexRefreshProcess {
  param([string]$FilePath)
  if (-not $FilePath) { return $null }
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if ($ext -eq '.cmd' -or $ext -eq '.bat') {
      $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
      $psi.Arguments = '/d /c ""{0}" exec --sandbox read-only --skip-git-repo-check -"' -f $FilePath
    } elseif ($ext -eq '.ps1') {
      $psi.FileName = Join-Path $PSHOME 'powershell.exe'
      $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" exec --sandbox read-only --skip-git-repo-check -' -f $FilePath
    } else {
      $psi.FileName = $FilePath
      $psi.Arguments = 'exec --sandbox read-only --skip-git-repo-check -'
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    if (-not $p.Start()) { $p.Dispose(); return $null }
    $p.StandardInput.WriteLine('reply ok')
    $p.StandardInput.Close()
    return $p
  } catch { return $null }
}

# 소진 + 오래됨일 때만 백그라운드로 Codex를 굴려 리셋 감지 (원본 maybeAutoRefreshCodex 이식).
# 기본 off($script:CodexAutoRefresh=$false) — 토큰 소모를 원치 않으면 그대로 둠. 6h 스로틀.
function Invoke-CodexAutoRefresh {
  param($Codex)
  try {
    if (Clear-CodexRefreshProcess) { return }
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
    $codexBin = Find-Bin 'codex'
    if (-not $codexBin) { return }
    $p = Start-CodexRefreshProcess -FilePath $codexBin
    if (-not $p) { return }
    $script:CodexRefreshProcess = $p
    $script:CodexRefreshStartedAt = $now
    Ensure-AppData
    Set-Content -Path $tsFile -Value ([string]$now) -Encoding UTF8
  } catch {}
}

# ══════════════════════════════════════════════════════════════════
#  3. ccusage (선택 의존) — 블록 비용 / 오늘 모델별. 없으면 $null.
# ══════════════════════════════════════════════════════════════════
$script:CCUSAGE_BIN = $null
$script:CCUSAGE_BIN_CHECKED_AT = 0
function Get-CcusageBin {
  $now = Get-UnixNow
  $cachedMissing = (-not $script:CCUSAGE_BIN)
  $cachedGone = ($script:CCUSAGE_BIN -and -not (Test-Path $script:CCUSAGE_BIN))
  if ($script:CCUSAGE_BIN_CHECKED_AT -eq 0 -or $cachedGone -or ($cachedMissing -and ($now - $script:CCUSAGE_BIN_CHECKED_AT) -ge 600)) {
    $script:CCUSAGE_BIN = Find-Bin 'ccusage'
    $script:CCUSAGE_BIN_CHECKED_AT = $now
  }
  return $script:CCUSAGE_BIN
}

# 활성 5시간 블록 (비용/토큰/번레이트) — 원본 getClaude 이식
function Get-ClaudeBlocks {
  $bin = Get-CcusageBin
  if (-not $bin) { return $null }
  try {
    $raw = Invoke-ExternalCommand -FilePath $bin -ArgumentList @('blocks', '--active', '--json') -TimeoutMs 10000
    if (-not $raw) { return $null }   # 타임아웃/무응답 — 다음 틱에 재시도, 트레이는 막지 않음
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
    $raw = Invoke-ExternalCommand -FilePath $bin -ArgumentList @('daily', '--breakdown', '--json', '--since', $ymd) -TimeoutMs 10000
    if (-not $raw) { return $null }   # 타임아웃/무응답 — 다음 틱에 재시도, 트레이는 막지 않음
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
  '?'=@('0110','1001','0001','0010','0000','0010')
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
  param([double]$Remain, [string]$Tag, [bool]$Dark, [int]$Size = 32, [bool]$Stale = $false)
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = $null; $ink = $null; $dkInk = $null; $fillBrush = $null
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half

    # stale은 실제 100%가 아니라 리셋 후 미측정 상태다. 양 테마에서 선명한 경고색 외곽선과
    # 빈 배터리 + '?'로 표현해 16px에서도 가득 찬 초록 배터리와 혼동되지 않게 한다.
    $inkColor = if ($Stale) { if ($Dark) { [Drawing.Color]::FromArgb(255,214,10) } else { [Drawing.Color]::FromArgb(190,120,0) } } elseif ($Dark) { [Drawing.Color]::FromArgb(235,235,235) } else { [Drawing.Color]::FromArgb(45,45,45) }
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
    if (-not $Stale -and $fw -gt 0) { $g.FillRectangle($fillBrush, $innerX, $innerY, $fw, $innerH) }
    if ($Stale) { $fw = 0 }
    $fillBoundaryLogical = [int][math]::Floor(($innerX + $fw) / $sc)

    # 잔량 숫자 (캡슐 안, 가운데). 채움 위 픽셀은 어두운 잉크, 빈 배경 위는 ink → 어디서나 대비.
    $numStr = if ($Stale) { '?' } else { [string][int][math]::Round($v) }
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

    return $bmp
  } finally {
    if ($ink) { $ink.Dispose() }
    if ($dkInk) { $dkInk.Dispose() }
    if ($fillBrush) { $fillBrush.Dispose() }
    if ($g) { $g.Dispose() }
  }
}

# Bitmap → [System.Drawing.Icon]. 반환 객체에 .Icon 과 해제용 .Handle 포함.
function New-BatteryIcon {
  param([double]$Remain, [string]$Tag, [bool]$Dark, [int]$Size = 32, [bool]$Stale = $false)
  $bmp = New-BatteryBitmap -Remain $Remain -Tag $Tag -Dark $Dark -Size $Size -Stale $Stale
  $hicon = [IntPtr]::Zero
  $icon = $null
  try {
    $hicon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hicon)
    return [pscustomobject]@{ Icon = $icon; Handle = $hicon }
  } finally {
    $bmp.Dispose()
    # Icon.FromHandle이 GetHicon 이후 실패하면 $icon이 세팅되지 않으므로 여기서 HICON을 직접 해제(누수 방지).
    # 성공한 경우엔 소유권이 반환된 객체로 넘어가므로 여기선 건드리지 않음(나중에 Remove-BatteryIcon이 해제).
    if (-not $icon -and $hicon -ne [IntPtr]::Zero) { try { [CCB.Native]::DestroyIcon($hicon) | Out-Null } catch {} }
  }
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
      $items += [pscustomobject]@{ key='C5'; tag='5'; remain=$r; stale=$false; service='claude'; tip=("Claude 5시간: {0}% 남음{1}" -f [int]$r, (& $resetTip $Usage.fiveHour.resetsAt)) }
    }
    if ($Usage.weekly) {
      $r = [math]::Max(0, 100 - $Usage.weekly.pct)
      $items += [pscustomobject]@{ key='CW'; tag='W'; remain=$r; stale=$false; service='claude'; tip=("Claude 주간: {0}% 남음{1}" -f [int]$r, (& $resetTip $Usage.weekly.resetsAt)) }
    }
    if ($Usage.fable) {
      $r = [math]::Max(0, 100 - $Usage.fable.pct)
      $items += [pscustomobject]@{ key='CF'; tag='F'; remain=$r; stale=$false; service='claude'; tip=("Claude {0}: {1}% 남음{2}" -f $Usage.fable.model, [int]$r, (& $resetTip $Usage.fable.resetsAt)) }
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
        $items += [pscustomobject]@{ key='X5'; tag='5'; remain=$r; stale=[bool]$p.stale; service='codex'; tip=$tip }
      }
      if ($s) {
        $r = [math]::Max(0, 100 - $s.pct)
        $tip = "Codex 주간: {0}% 남음" -f [int]$r
        if ($s.stale) { $tip += ' · 리셋됨' } elseif ($s.resetsIn) { $tip += ' · 리셋 ' + (Format-Duration $s.resetsIn) }
        $items += [pscustomobject]@{ key='XW'; tag='W'; remain=$r; stale=[bool]$s.stale; service='codex'; tip=$tip }
      }
    } elseif ($Codex.credits) {
      $cr = $Codex.credits
      $remain = if ($cr.unlimited) { 100 } elseif ($cr.has_credits -and [double]$cr.balance -gt 0) { 100 } else { 0 }
      $tip = if ($cr.unlimited) { 'Codex 크레딧: 무제한' } elseif ($remain -gt 0) { "Codex 크레딧: 잔액 $($cr.balance)" } else { 'Codex 크레딧: 소진' }
      $items += [pscustomobject]@{ key='X'; tag='X'; remain=$remain; stale=$false; service='codex'; tip=$tip }
    }
  }
  if ($Usage -and $Usage.refreshError) {
    $warning = Format-ClaudeFailure -Failure $Usage.refreshError -MeasuredAt $Usage.measuredAt
    foreach ($it in $items) {
      if ($it.service -eq 'claude') { $it.tip = $warning + ' · ' + $it.tip }
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
    @{ tag='5'; remain=72; stale=$false }, @{ tag='W'; remain=33; stale=$false }, @{ tag='F'; remain=8; stale=$false },
    @{ tag='5'; remain=100; stale=$false }, @{ tag='5'; remain=100; stale=$true },
    @{ tag='X'; remain=54; stale=$false }, @{ tag='W'; remain=19; stale=$false }
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
        $b = New-BatteryBitmap -Remain $sm.remain -Tag $sm.tag -Dark $dark -Size $size -Stale $sm.stale
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
        $b = New-BatteryBitmap -Remain $it.remain -Tag $it.tag -Dark $dark -Size $sz -Stale $it.stale
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
  $parse = {
    param([string]$v)
    $text = if ($null -eq $v) { '' } else { $v.Trim() }
    $m = [regex]::Match($text, '^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?')
    if (-not $m.Success) { return [pscustomobject]@{ core=@(0,0,0); pre='' } }
    return [pscustomobject]@{
      core = @(for ($j=1; $j -le 3; $j++) { if ($m.Groups[$j].Success) { [int64]$m.Groups[$j].Value } else { 0 } })
      pre = if ($m.Groups[4].Success) { $m.Groups[4].Value } else { '' }
    }
  }
  $pa = & $parse $A; $pb = & $parse $B
  for ($i = 0; $i -lt 3; $i++) {
    $x = $pa.core[$i]; $y = $pb.core[$i]
    if ($x -gt $y) { return 1 }; if ($x -lt $y) { return -1 }
  }
  if (-not $pa.pre -and $pb.pre) { return 1 }
  if ($pa.pre -and -not $pb.pre) { return -1 }
  if ($pa.pre -ne $pb.pre) { return [math]::Sign([string]::Compare($pa.pre, $pb.pre, [StringComparison]::OrdinalIgnoreCase)) }
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
  $it.Enabled = $false
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

  $hasClaude = [bool]($Usage -and ($Usage.fiveHour -or $Usage.weekly -or $Usage.fable))
  $claudeFailureText = if ($Usage -and $Usage.refreshError) { Format-ClaudeFailure -Failure $Usage.refreshError -MeasuredAt $Usage.measuredAt } else { '' }
  $hasCodex  = [bool]$Codex

  # 범례
  $legend = @()
  if ($hasClaude) { $legend += 'C5·CW·CF = Claude 5시간·주간·Fable' }
  if ($hasCodex)  { $legend += 'X5·XW = Codex 5시간·주간' }
  if ($legend.Count) { Add-Label $menu ('🔋 남은 %  ·  ' + ($legend -join '  ·  ')) $gray $script:MONO_SM | Out-Null; $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null }

  # Claude 섹션
  if ($hasClaude -or $claudeFailureText) {
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
    if ($Usage.measuredAt) { Add-Label $menu ('측정 {0} 전 (Claude 실시간)' -f (Format-Duration ($now - $Usage.measuredAt))) $gray $script:MONO_SM | Out-Null }
    if ($claudeFailureText) { Add-Label $menu $claudeFailureText ([Drawing.Color]::FromArgb(210,153,34)) $script:MONO_SM | Out-Null }
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
    Add-Label $menu ('측정 {0} 전{1}' -f (Format-Duration $age), $warnTxt) $(if ($staleWarn) { [Drawing.Color]::FromArgb(210,153,34) } else { $gray }) $script:MONO_SM | Out-Null
    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
  }

  if (-not $hasClaude -and -not $hasCodex -and -not $claudeFailureText) {
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
$script:Tray = @{
  NIs = @(); IconObjs = @(); Menu = $null; Timer = $null; PollTimer = $null; Mutex = $null
  Cache = @{ Usage = $null; Codex = $null; Models = $null; Blocks = $null; FetchedAt = 0 }
  Fetch = @{ PS = $null; Runspace = $null; Handle = $null; InFlight = $false }
}

# 네 가지 데이터 조회(Get-ClaudeUsage/Get-CodexUsage/Get-ClaudeModels/Get-ClaudeBlocks)를
# 별도 러너스페이스(스레드)에서 비동기로 시작. UI 스레드는 절대 블로킹하지 않는다.
# 이미 진행 중인 조회가 있으면 새로 시작하지 않음(중첩 방지 — hung ccusage가 있어도 쌓이지 않게).
function Start-DataFetch {
  param([switch]$ForceApi)
  if ($script:Tray.Fetch.InFlight) { return }
  if (-not $script:SELF_PATH) { return }
  try {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
      param($SelfPath, $ForceApi)
      . $SelfPath   # 스위치 없이 dot-source — 함수 정의만 로드되고 -Run 등 부수효과는 실행되지 않음
      [pscustomobject]@{
        Usage  = (Get-ClaudeUsage -Force:$ForceApi)
        Codex  = (Get-CodexUsage)
        Models = (Get-ClaudeModels)
        Blocks = (Get-ClaudeBlocks)
      }
    }).AddArgument($script:SELF_PATH).AddArgument([bool]$ForceApi)
    $handle = $ps.BeginInvoke()
    $script:Tray.Fetch.PS = $ps
    $script:Tray.Fetch.Runspace = $rs
    $script:Tray.Fetch.Handle = $handle
    $script:Tray.Fetch.InFlight = $true
  } catch {
    $script:Tray.Fetch.InFlight = $false   # 시작 실패 — 캐시(플레이스홀더 포함)는 유지, 다음 틱에 재시도
  }
}

# 완료된 백그라운드 조회가 있으면 결과를 캐시로 수확하고 러너스페이스를 정리. 반환값 true=새 데이터 반영됨.
# UI 스레드에서 호출하되, 여기서 하는 일은 상태 확인 + 값 복사뿐이라 블로킹하지 않는다.
function Complete-DataFetch {
  $fx = $script:Tray.Fetch
  if (-not $fx.InFlight -or -not $fx.Handle) { return $false }
  if (-not $fx.Handle.IsCompleted) { return $false }
  $got = $false
  try {
    $result = $fx.PS.EndInvoke($fx.Handle)
    if ($result -and $result.Count -gt 0 -and $result[0]) {
      $r = $result[0]
      $script:Tray.Cache.Usage     = $r.Usage
      $script:Tray.Cache.Codex     = $r.Codex
      $script:Tray.Cache.Models    = $r.Models
      $script:Tray.Cache.Blocks    = $r.Blocks
      $script:Tray.Cache.FetchedAt = Get-UnixNow
      $got = $true
    }
  } catch {
  } finally {
    try { $fx.PS.Dispose() } catch {}
    try { $fx.Runspace.Close(); $fx.Runspace.Dispose() } catch {}
    $script:Tray.Fetch = @{ PS = $null; Runspace = $null; Handle = $null; InFlight = $false }
  }
  return $got
}

function New-PlaceholderBitmap {
  param([bool]$Dark, [int]$Size = 32)
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = $null; $ink = $null
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::Transparent)
    $inkC = if ($Dark) { [Drawing.Color]::FromArgb(150,150,150) } else { [Drawing.Color]::FromArgb(120,120,120) }
    $ink = New-Object System.Drawing.SolidBrush($inkC)
    $bw = [int]($Size*0.82); $bh = [int]($Size*0.5); $bx = [int]($Size*0.05); $by = [int](($Size-$bh)/2)
    $b = [math]::Max(1,[int]($Size/16))
    $g.FillRectangle($ink,$bx,$by,$bw,$b); $g.FillRectangle($ink,$bx,$by+$bh-$b,$bw,$b)
    $g.FillRectangle($ink,$bx,$by,$b,$bh); $g.FillRectangle($ink,$bx+$bw-$b,$by,$b,$bh)
    $g.FillRectangle($ink, $bx+[int]($bw*0.35), $by+[int]($bh/2)-$b, [int]($bw*0.3), 2*$b)  # 대시
    return $bmp
  } finally {
    if ($ink) { $ink.Dispose() }
    if ($g) { $g.Dispose() }
  }
}

# 순수 렌더링만 수행(네트워크/프로세스/파일 조회 없음) — 항상 UI 스레드에서, 항상 캐시된 데이터로 호출.
function Render-Tray {
  param($Usage, $Codex, $Models, $Blocks)
  try {
    $dark = Test-DarkMode
    $size = try { [System.Windows.Forms.SystemInformation]::SmallIconSize.Height } catch { 16 }
    if ($size -lt 16) { $size = 16 }
    $items = @(Get-BatteryItems -Usage $Usage -Codex $Codex)

    # 새 아이콘 준비 (없으면 placeholder 1개)
    $newIcons = @()
    if ($items.Count -eq 0) {
      $bmp = New-PlaceholderBitmap -Dark $dark -Size $size
      $h = $bmp.GetHicon(); $ic = [System.Drawing.Icon]::FromHandle($h); $bmp.Dispose()
      $placeholderTip = if ($Usage -and $Usage.refreshError) { Format-ClaudeFailure -Failure $Usage.refreshError -MeasuredAt $Usage.measuredAt } else { 'Claude Code나 Codex 실행 시 표시' }
      $newIcons += [pscustomobject]@{ Icon = $ic; Handle = $h; Tip = $placeholderTip }
    } else {
      foreach ($it in $items) {
        $io = New-BatteryIcon -Remain $it.remain -Tag $it.tag -Dark $dark -Size $size -Stale $it.stale
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
    $script:Tray.Menu = Build-DetailMenu -Usage $Usage -Codex $Codex -Models $Models -Blocks $Blocks

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

# 메인 타이머(120초) 틱: 완료된 조회를 수확 → 캐시로 즉시 렌더(블로킹 없음) → 다음 조회를 백그라운드로 시작.
# 콜드 스타트에도 첫 렌더는 캐시(비어있으면 placeholder)로 즉시 그려지고, 실제 데이터는 폴 타이머가 반영한다.
function Update-Tray {
  param([switch]$Force)
  [void](Complete-DataFetch)
  if (-not $script:Tray.Fetch.InFlight) { Start-DataFetch -ForceApi:$Force }
  Render-Tray -Usage $script:Tray.Cache.Usage -Codex $script:Tray.Cache.Codex -Models $script:Tray.Cache.Models -Blocks $script:Tray.Cache.Blocks
  Invoke-CodexAutoRefresh $script:Tray.Cache.Codex
  Start-UpdateCheck
}

# 짧은 주기(2초) 폴 타이머 틱: 백그라운드 조회가 끝났는지만 값싸게 확인하고, 끝났을 때만 재렌더.
# 새 조회는 시작하지 않는다(그건 메인 타이머/새로고침 버튼의 몫) — 순수 폴링이라 UI를 절대 막지 않음.
function Poll-TrayFetch {
  if (Complete-DataFetch) {
    Render-Tray -Usage $script:Tray.Cache.Usage -Codex $script:Tray.Cache.Codex -Models $script:Tray.Cache.Models -Blocks $script:Tray.Cache.Blocks
  }
}

function Stop-ResidentTray {
  try { if ($script:Tray.Timer) { $script:Tray.Timer.Stop() } } catch {}
  try { if ($script:Tray.PollTimer) { $script:Tray.PollTimer.Stop() } } catch {}
  foreach ($ni in $script:Tray.NIs) { try { $ni.Visible = $false; $ni.Dispose() } catch {} }
  foreach ($io in $script:Tray.IconObjs) { Remove-BatteryIcon $io }
  try { if ($script:Tray.Menu) { $script:Tray.Menu.Dispose() } } catch {}
  [void](Clear-CodexRefreshProcess -Force)
  # 진행 중인 백그라운드 조회가 있으면 정리 (종료 시 러너스페이스가 남지 않도록)
  try { if ($script:Tray.Fetch.Runspace) { $script:Tray.Fetch.Runspace.Close(); $script:Tray.Fetch.Runspace.Dispose() } } catch {}
  try { if ($script:Tray.Fetch.PS) { $script:Tray.Fetch.PS.Dispose() } } catch {}
  [System.Windows.Forms.Application]::Exit()
}

# 비정상 종료(로그오프/시스템 종료/taskkill) 전용 최소 정리 — 고스트 트레이 아이콘 방지가 유일한 목적.
# ProcessExit 핸들러에서 호출될 수 있어 빠르고 예외 없이 끝나야 함(Application.Exit 등 무거운 호출 금지).
function Hide-TrayIcons {
  foreach ($ni in $script:Tray.NIs) { try { $ni.Visible = $false } catch {} }
}

function Start-ResidentTray {
  try {
    # 단일 인스턴스 (named mutex)
    $created = $false
    $script:Tray.Mutex = New-Object System.Threading.Mutex($true, 'Global\ClaudeCodexBatteryWin', [ref]$created)
    if (-not $created) { return }  # 이미 실행 중 → 조용히 종료
    Ensure-AppData
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # 로그오프/종료 시 정상적으로 트레이를 정리하고, 프로세스가 그냥 죽는 경우(taskkill 등)에도
    # 최소한 아이콘을 숨겨 고스트 트레이 아이콘이 남지 않게 한다.
    try {
      Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName 'SessionEnding' `
        -SourceIdentifier 'CcbSessionEnding' -Action { Stop-ResidentTray } -ErrorAction SilentlyContinue | Out-Null
    } catch {}
    try {
      [AppDomain]::CurrentDomain.add_ProcessExit({ Hide-TrayIcons })
    } catch {}

    $script:Tray.Timer = New-Object System.Windows.Forms.Timer
    $script:Tray.Timer.Interval = 120000   # 2분 — 조회 시작 + 캐시로부터 렌더 (블로킹 없음)
    $script:Tray.Timer.Add_Tick({ Update-Tray })
    $script:Tray.PollTimer = New-Object System.Windows.Forms.Timer
    $script:Tray.PollTimer.Interval = 2000   # 2초 — 백그라운드 조회 완료를 값싸게 확인해 빠르게 반영
    $script:Tray.PollTimer.Add_Tick({ Poll-TrayFetch })
    Update-Tray          # 초기 렌더 — 캐시가 비어도 즉시 placeholder를 보여주고, 조회는 백그라운드로 시작됨
    $script:Tray.Timer.Start()
    $script:Tray.PollTimer.Start()
    [System.Windows.Forms.Application]::Run()
    # 종료 정리
    try { $script:Tray.Mutex.ReleaseMutex() } catch {}
  } catch {
    # 상주 실행이 시작조차 못 하면(뮤텍스/타이머/트레이 초기화 실패 등) 트레이도 없고 콘솔도 없어
    # 사용자에게 아무 신호가 안 갈 수 있다 — 최소한 로그 파일에는 남긴다. 모달은 띄우지 않는다.
    Write-CcbLog ("Start-ResidentTray 실패: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
  }
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
    foreach ($it in $items) { $io = New-BatteryIcon -Remain $it.remain -Tag $it.tag -Dark $dark -Size 32 -Stale $it.stale; Remove-BatteryIcon $io }
    Write-Host "SelfTest: 예외 없음 ✅"
  } catch { $err += $_; Write-Host ("SelfTest 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red; Write-Host $_.ScriptStackTrace }
  return
}

# ══════════════════════════════════════════════════════════════════
#  진입점 — 상주 실행은 -Run 일 때만 (dot-source/테스트 시 기동 안 함)
# ══════════════════════════════════════════════════════════════════
if ($Run) { Start-ResidentTray }

