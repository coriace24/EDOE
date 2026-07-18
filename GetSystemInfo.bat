@echo off
setlocal

cls

echo =================================
echo       SYSTEM INFORMATION
echo =================================
echo.

for /f "tokens=2 delims==" %%A in ('wmic bios get SMBIOSBIOSVersion /value ^| find "="') do for /f "delims=" %%B in ("%%A") do set "BIOSVER=%%B"
for /f "tokens=2 delims==" %%A in ('wmic bios get SerialNumber /value ^| find "="') do for /f "delims=" %%B in ("%%A") do set "SERIAL=%%B"
for /f "tokens=2 delims==" %%A in ('wmic computersystem get Model /value ^| find "="') do for /f "delims=" %%B in ("%%A") do set "MODEL=%%B"
for /f "tokens=2 delims==" %%A in ('wmic computersystem get Manufacturer /value ^| find "="') do for /f "delims=" %%B in ("%%A") do set "MANUFACTURER=%%B"

echo Manufacturer : %MANUFACTURER%
echo Model        : %MODEL%
echo Serial       : %SERIAL%
echo BIOS Version : %BIOSVER%
echo.

pause
