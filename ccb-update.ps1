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
  $pa=($A -replace '[^0-9.]','').Split('.'); $pb=($B -replace '[^0-9.]','').Split('.')
  for($i=0;$i -lt 3;$i++){ $x=if($i -lt $pa.Count -and $pa[$i]){[int]$pa[$i]}else{0}; $y=if($i -lt $pb.Count -and $pb[$i]){[int]$pb[$i]}else{0}; if($x -gt $y){return 1}; if($x -lt $y){return -1} }
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

# 최신 파일 다운로드
$targets = @('claude-codex-battery-win.ps1', 'launch-hidden.vbs', 'ccb-update.ps1', 'VERSION')
$tmp = Join-Path $env:TEMP ('ccb-upd-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
foreach ($t in $targets) {
  try { Invoke-WebRequest -Uri "$RepoRaw/$t" -OutFile (Join-Path $tmp $t) -TimeoutSec 20 } catch { Write-Host ("⚠ {0} 다운로드 실패 — 건너뜀" -f $t) -ForegroundColor Yellow }
}

# 실행 중인 인스턴스 중지 (명령줄에 이 스크립트 경로 + -Run 포함하는 powershell)
Write-Host "실행 중 인스턴스 중지..."
try {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine -like ('*' + [System.IO.Path]::GetFileName($mainPs1) + '*') -and $_.CommandLine -like '*-Run*'
  } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {}
Start-Sleep -Milliseconds 500

# 백업 후 교체
foreach ($t in $targets) {
  $new = Join-Path $tmp $t
  if (-not (Test-Path $new)) { continue }
  $cur = Join-Path $dir $t
  if (Test-Path $cur) { Copy-Item -LiteralPath $cur -Destination ($cur + '.bak') -Force }
  Copy-Item -LiteralPath $new -Destination $cur -Force
}
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("✅ v{0} 로 업데이트 (이전본은 .bak 보존)" -f $remoteVer)

# 재시작
$vbs = Join-Path $dir 'launch-hidden.vbs'
if (Test-Path $vbs) { Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $vbs); Write-Host "✅ 재시작됨" }
