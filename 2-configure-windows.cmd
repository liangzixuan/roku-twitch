@echo off
setlocal
set "PYTHONUTF8=1"
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" goto missing
if not exist "data\settings.json" goto missing_data
echo Keep the existing Client ID by pressing Enter at the first prompt.
echo At the next prompt, enter http://YOUR_WINDOWS_LAN_IP:58787
echo Use the IPv4 address of the home Wi-Fi or Ethernet adapter, not a VPN address.
".venv\Scripts\python.exe" -m server.setup configure
if errorlevel 1 goto failed
echo Roku package created: dist\roku-twitch.zip
echo Start the server and check its health before uploading the ZIP to Roku.
pause
exit /b 0
:missing_data
echo Migration data is missing. Follow WINDOWS.md before configuring.
echo Copy data\settings.json from the old computer after stopping its server.
pause
exit /b 1
:missing
echo Run 1-install-windows.cmd first.
pause
exit /b 1
:failed
echo Configuration failed. Read the error above.
pause
exit /b 1
