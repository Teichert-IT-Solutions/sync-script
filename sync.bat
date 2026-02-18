@echo off
REM ============================================================
REM Sync-Wrapper - umgeht die PowerShell Execution Policy
REM Passe die Pfade unten an deine Umgebung an!
REM ============================================================

REM -- Hier deine Pfade eintragen: --
set "PATHA=C:\Test"
set "PATHB=C:\Users\user\scripts\Test"

REM -- Script-Verzeichnis (wo diese .bat liegt) --
set "SCRIPTDIR=%~dp0"

REM -- Script ausfuehren (ohne Execution Policy) --
powershell.exe -NoProfile -Command "Set-Location '%SCRIPTDIR%'; $s = Get-Content -Path '%SCRIPTDIR%sync.ps1' -Raw; $sb = [scriptblock]::Create($s); & $sb -PathA '%PATHA%' -PathB '%PATHB%'"

echo.
echo Fertig! (Exit Code: %ERRORLEVEL%)
pause
