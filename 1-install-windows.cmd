@echo off
setlocal
set "PYTHONUTF8=1"
cd /d "%~dp0"
py -3.14 --version >nul 2>&1
if errorlevel 1 goto missing_python
if exist ".venv\Scripts\python.exe" goto install_packages
if exist ".venv" goto wrong_venv
py -3.14 -m venv .venv
if errorlevel 1 goto failed
:install_packages
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 goto failed
".venv\Scripts\python.exe" -c "import fastapi, uvicorn, httpx, streamlink; print('Python dependencies are ready.')"
if errorlevel 1 goto failed
ffmpeg -version >nul 2>&1
if errorlevel 1 goto missing_ffmpeg
echo Installation complete. Follow WINDOWS.md to transfer data and configure the server.
pause
exit /b 0
:missing_python
echo Install Python 3.14 first. See WINDOWS.md. Then reopen this script.
pause
exit /b 1
:wrong_venv
echo This folder has a virtual environment from another system.
echo Extract the Windows package into a new folder. Do not copy the Mac .venv folder.
pause
exit /b 1
:missing_ffmpeg
echo Python is ready, but FFmpeg is missing from PATH.
echo Install FFmpeg as described in WINDOWS.md, then reopen this script.
pause
exit /b 1
:failed
echo Installation failed. Read the error above before retrying.
pause
exit /b 1
