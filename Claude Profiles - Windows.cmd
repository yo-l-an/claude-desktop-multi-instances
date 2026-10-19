@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows\claude-profiles.ps1" %*
set "STATUS=%ERRORLEVEL%"
rem Keep the window open when started by double-click.
echo %CMDCMDLINE% | findstr /i /c:"%~nx0" >nul && pause
exit /b %STATUS%
