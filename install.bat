@echo off
setlocal
chcp 65001 >nul 2>nul

rem Amnezia Browser VPN - Windows installer launcher.
rem Runs install.ps1 with the execution policy bypassed for this process only.

set "PS=powershell.exe"
where pwsh.exe >nul 2>nul && set "PS=pwsh.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "INSTALL_RESULT=%ERRORLEVEL%"

echo.
if not "%INSTALL_RESULT%"=="0" (
    echo Installation failed with exit code %INSTALL_RESULT%.
    echo See the message above or %LOCALAPPDATA%\AmneziaBrowserVPN\install.log
) else (
    echo Installation finished successfully.
)

echo.
pause
exit /b %INSTALL_RESULT%
