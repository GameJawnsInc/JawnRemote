@echo off
REM Start the JawnRemote server. Double-click this file to run.
cd /d "%~dp0"
echo Starting JawnRemote server...
echo (Close this window or press Ctrl+C to stop.)
echo.
py server.py %*
echo.
echo Server stopped.
pause
