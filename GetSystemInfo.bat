@echo off
setlocal

cls

echo =================================
echo       SYSTEM INFORMATION
echo =================================
echo.

for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion"`) do set "BIOSVER=%%A"
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-CimInstance Win32_BIOS).SerialNumber"`) do set "SERIAL=%%A"
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-CimInstance Win32_ComputerSystem).Model"`) do set "MODEL=%%A"
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-CimInstance Win32_ComputerSystem).Manufacturer"`) do set "MANUFACTURER=%%A"

echo Manufacturer : %MANUFACTURER%
echo Model        : %MODEL%
echo Serial       : %SERIAL%
echo BIOS Version : %BIOSVER%
echo.

pause
