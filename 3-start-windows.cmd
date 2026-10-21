@echo off
setlocal
set "PYTHONUTF8=1"
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" goto missing
if not exist "roku\config.json" goto unconfigured
ffmpeg -version >nul 2>&1
if errorlevel 1 goto missing_ffmpeg
echo Keep this window open while watching Roku. Press Ctrl+C to stop.
echo Keep this computer awake. The display may be turned off.
".venv\Scripts\python.exe" -m server.run
echo Server exited. Any error appears above.
pause
exit /b 0
:missing
echo Run 1-install-windows.cmd first.
pause
exit /b 1
:unconfigured
echo Run 2-configure-windows.cmd first.
pause
exit /b 1
:missing_ffmpeg
echo FFmpeg is missing from PATH. See WINDOWS.md and reopen this script after installing it.
pause
exit /b 1
