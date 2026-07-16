<#
  Claude & Codex Usage Battery (Windows) — 원클릭 업데이트.
  포크 레포에서 최신 파일을 받아 교체하고(.bak 백업) 상주 프로세스를 재시작한다.
  트레이 메뉴의 '🆕 업데이트' 항목이 이 스크립트를 실행한다.
#>
[CmdletBinding()]
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$RepoRaw = 'https://raw.githubusercontent.com/QriusQuokka/claude-codex-battery/main'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$mainPs1 = Join-Path $dir 'claude-codex-battery-win.ps1'

function Read-LocalVersion {
  $vf = Join-Path $dir 'VERSION'
  if (Test-Path $vf) { return ((Get-Content $vf -Raw).Trim()) }
  return '0.0.0'
}
function Compare-Ver { param($A,$B)
  $parse={param($v);$text=if($null -eq $v){''}else{([string]$v).Trim()};$m=[regex]::Match($text,'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?');if(-not $m.Success){return [pscustomobject]@{core=@(0,0,0);pre=''}};[pscustomobject]@{core=@(for($j=1;$j -le 3;$j++){if($m.Groups[$j].Success){[int64]$m.Groups[$j].Value}else{0}});pre=if($m.Groups[4].Success){$m.Groups[4].Value}else{''}}}
  $pa=& $parse $A; $pb=& $parse $B
  for($i=0;$i -lt 3;$i++){ $x=$pa.core[$i]; $y=$pb.core[$i]; if($x -gt $y){return 1}; if($x -lt $y){return -1} }
  if(-not $pa.pre -and $pb.pre){return 1}; if($pa.pre -and -not $pb.pre){return -1}
  if($pa.pre -ne $pb.pre){return [math]::Sign([string]::Compare($pa.pre,$pb.pre,[StringComparison]::OrdinalIgnoreCase))}
  return 0
}

Write-Host "업데이트 확인 중..."
$remoteVer = (Invoke-RestMethod -Uri "$RepoRaw/VERSION" -TimeoutSec 15).ToString().Trim()
$localVer = Read-LocalVersion
Write-Host ("로컬 v{0}  ·  원격 v{1}" -f $localVer, $remoteVer)
if (-not $Force -and (Compare-Ver $remoteVer $localVer) -le 0) {
  Write-Host "이미 최신입니다. (강제로 받으려면 -Force)"
  return
}

# 최신 파일 다운로드 — 하나라도 실패하면 VERSION을 포함해 아무것도 커밋하지 않는다.
# (부분 다운로드로 VERSION만 갱신되면 "이미 최신"으로 오판해 구버전에 영구히 갇히는 문제 방지)
$targets = @('claude-codex-battery-win.ps1', 'launch-hidden.vbs', 'ccb-update.ps1', 'VERSION')
$tmp = Join-Path $env:TEMP ('ccb-upd-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$allOk = $true
foreach ($t in $targets) {
  try { Invoke-WebRequest -Uri "$RepoRaw/$t" -OutFile (Join-Path $tmp $t) -TimeoutSec 20 }
  catch { Write-Host ("⚠ {0} 다운로드 실패" -f $t) -ForegroundColor Yellow; $allOk = $false }
}
if (-not $allOk) {
  Write-Host "⚠ 일부 파일을 받지 못해 업데이트를 중단합니다 (기존 상태는 그대로 유지됨). 나중에 다시 시도해 주세요." -ForegroundColor Yellow
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  return
}

# 받은 PowerShell 스크립트 모두를 실행 전에 파싱한다. 업데이터 자신이 깨진 배포도 설치하지 않아
# 다음 업데이트 경로가 영구히 막히는 일을 방지한다.
foreach ($scriptName in @('claude-codex-battery-win.ps1','ccb-update.ps1')) {
  $newScript = Join-Path $tmp $scriptName
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($newScript, [ref]$null, [ref]$parseErrors) | Out-Null
  if ($parseErrors -and $parseErrors.Count -gt 0) {
    Write-Host ("⚠ 새로 받은 {0} 파일이 파싱되지 않습니다 — 업데이트를 중단합니다 (기존 상태 유지)." -f $scriptName) -ForegroundColor Red
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return
  }
}

# 실행 중인 인스턴스 중지 (명령줄에 이 스크립트 경로 + -Run 포함하는 powershell)
Write-Host "실행 중 인스턴스 중지..."
try {
  $fullMain = [System.IO.Path]::GetFullPath($mainPs1)
  $stopped = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine.IndexOf($fullMain, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.CommandLine -match '(?i)(?:^|\s)-Run(?:\s|$)'
  } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $_.ProcessId })
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  do {
    $alive = @($stopped | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($alive.Count -eq 0) { break }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
} catch {}

# 백업 후 교체 — 도중에 실패하면 지금까지 백업해 둔 .bak으로 롤백한다.
$backedUp = @()
$copyFailed = $false
try {
  foreach ($t in $targets) {
    $new = Join-Path $tmp $t
    if (-not (Test-Path $new)) { continue }
    $cur = Join-Path $dir $t
    if (Test-Path $cur) { Copy-Item -LiteralPath $cur -Destination ($cur + '.bak') -Force; $backedUp += $t }
    Copy-Item -LiteralPath $new -Destination $cur -Force
  }
} catch {
  $copyFailed = $true
  Write-Host ("⚠ 파일 교체 중 오류: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

if ($copyFailed) {
  Write-Host "이전 버전으로 복구 중..." -ForegroundColor Yellow
  foreach ($t in $backedUp) {
    $cur = Join-Path $dir $t
    $bak = $cur + '.bak'
    if (Test-Path $bak) { try { Copy-Item -LiteralPath $bak -Destination $cur -Force } catch {} }
  }
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "⚠ 업데이트 실패 — 이전 버전으로 복구했습니다." -ForegroundColor Yellow
  return
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("✅ v{0} 로 업데이트 (이전본은 .bak 보존)" -f $remoteVer)

# 재시작
$vbs = Join-Path $dir 'launch-hidden.vbs'
if (Test-Path $vbs) { Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $vbs); Write-Host "✅ 재시작됨" }
