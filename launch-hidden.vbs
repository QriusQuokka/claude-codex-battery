' Claude & Codex Usage Battery — 콘솔 창 없이 상주 스크립트를 실행하는 런처.
' 시작프로그램/자동실행이 이 vbs를 가리킨다. wscript로 실행되어 콘솔이 전혀 뜨지 않는다.
Option Explicit
Dim fso, sh, scriptDir, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\claude-codex-battery-win.ps1"
cmd = "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps1 & """ -Run"
' 0 = 창 숨김, False = 종료를 기다리지 않음
sh.CurrentDirectory = scriptDir
sh.Run cmd, 0, False
