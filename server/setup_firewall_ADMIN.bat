@echo off
REM Opens the Windows Firewall for the JawnRemote server (TCP + UDP port 8770).
REM Double-click; it will request administrator rights automatically.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo Configuring Windows Firewall for JawnRemote (port 8770)...
netsh advfirewall firewall delete rule name="JawnRemote" >nul 2>&1
netsh advfirewall firewall delete rule name="JawnRemote (discovery)" >nul 2>&1
netsh advfirewall firewall add rule name="JawnRemote" dir=in action=allow protocol=TCP localport=8770 profile=any
netsh advfirewall firewall add rule name="JawnRemote (discovery)" dir=in action=allow protocol=UDP localport=8770 profile=any
echo.
echo Done. The server is now reachable from your phone over Wi-Fi (TCP+UDP 8770).
pause
