<#
  Claude & Codex Usage Battery (Windows) — 설치 스크립트.
  원본 install.sh 의 Windows 대응. 앱 파일을 %LOCALAPPDATA%\claude-codex-battery 에 복사하고,
  시작프로그램에 등록한 뒤 즉시 상주 실행한다.  실행:  powershell -ExecutionPolicy Bypass -File install.ps1
#>
[CmdletBinding()]
param(
  # 자동 시작(시작프로그램) 등록을 건너뜀
  [switch]$NoAutostart,
  # 설치 후 자동 실행을 건너뜀
  [switch]$NoLaunch
)
$ErrorActionPreference = 'Stop'

Write-Host "🔋 Claude & Codex Usage Battery — 설치" -ForegroundColor Cyan
Write-Host "────────────────────────────────────"

$srcDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dstDir = Join-Path $env:LOCALAPPDATA 'claude-codex-battery'
$files = @('claude-codex-battery-win.ps1', 'launch-hidden.vbs', 'ccb-update.ps1', 'VERSION')

# 1) PowerShell 버전 안내 (5.1+ 권장)
Write-Host ("✅ PowerShell {0}" -f $PSVersionTable.PSVersion)

# 2) 앱 파일 복사
if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
foreach ($f in $files) {
  $src = Join-Path $srcDir $f
  if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $dstDir $f) -Force }
  elseif ($f -ne 'VERSION') { Write-Host ("⚠ 원본에 {0} 없음 — 건너뜀" -f $f) -ForegroundColor Yellow }
}
Write-Host ("✅ 앱 배치: {0}" -f $dstDir)

# 3) 시작프로그램 등록 (재부팅/재로그인 후 자동 실행)
if (-not $NoAutostart) {
  try {
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Codex Battery.lnk'
    $vbs = Join-Path $dstDir 'launch-hidden.vbs'
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath = 'wscript.exe'
    $lnk.Arguments = ('"{0}"' -f $vbs)
    $lnk.WorkingDirectory = $dstDir
    $lnk.Description = 'Claude & Codex Usage Battery'
    $lnk.Save()
    Write-Host "✅ 시작프로그램 등록 (재부팅 후 자동 실행)"
  } catch {
    Write-Host ("ⓘ 시작프로그램 등록 실패 — 트레이 메뉴의 '시작 시 자동 실행'으로 켤 수 있습니다: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
  }
}

# 4) 즉시 실행 (기존 인스턴스가 있으면 mutex로 중복 방지됨)
if (-not $NoLaunch) {
  $vbs = Join-Path $dstDir 'launch-hidden.vbs'
  Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $vbs)
  Write-Host "✅ 실행됨 — 몇 초 안에 트레이에 배터리가 나타납니다."
}

Write-Host "────────────────────────────────────"
Write-Host "완료! 참고:"
Write-Host "  • Windows 11은 새 트레이 아이콘을 기본으로 숨깁니다. 작업표시줄의 '^'(숨겨진 아이콘)을 열어"
Write-Host "    배터리 아이콘들을 작업표시줄로 끌어다 놓으면(고정) 상시 보입니다."
Write-Host "  • 갱신 주기: 2분.  좌클릭 = 상세 메뉴, 마우스 오버 = 툴팁."
Write-Host "  • Claude 사용량은 로컬 캐시가 없어 OAuth usage API로 읽습니다(본인 계정, read-only)."
Write-Host "    끄려면 claude-codex-battery-win.ps1 상단의 `$EnableUsageApi 를 `$false 로."
