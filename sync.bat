@echo off
REM ============================================================
REM Sync-Wrapper - umgeht die PowerShell Execution Policy
REM Passe die Pfade unten an deine Umgebung an!
REM ============================================================

REM -- Hier deine Pfade eintragen: --
set "PATHA=C:\Test"
set "PATHB=C:\Users\user\scripts\Test"

REM -- Script ausfuehren (ohne Execution Policy) --
powershell.exe -NoProfile -Command "& { $s = Get-Content -Path '%~dp0sync.ps1' -Raw; $sb = [scriptblock]::Create($s); & $sb -PathA '%PATHA%' -PathB '%PATHB%' }"

echo.
echo Fertig! (Exit Code: %ERRORLEVEL%)
pause

