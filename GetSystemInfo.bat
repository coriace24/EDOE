@echo off
rem ==================================================================
rem GetSystemInfo.bat - displays hardware identity for the current PC.
rem Detection itself lives in DetectHardware.bat (same folder).
rem ==================================================================
setlocal

cls

echo =================================
echo       SYSTEM INFORMATION
echo =================================
echo.

set "BIOSVER="
set "SERIAL="
set "MODEL="
set "MANUFACTURER="

if not exist "%~dp0DetectHardware.bat" (
    echo ERROR: DetectHardware.bat not found next to this script.
    echo Expected: %~dp0DetectHardware.bat
    echo.
    pause
    exit /b 1
)

for /f "usebackq tokens=1,* delims==" %%A in (`call "%~dp0DetectHardware.bat"`) do set "%%A=%%B"

if not defined SERIAL set "SERIAL=Not available"
if not defined MANUFACTURER set "MANUFACTURER=Unknown"
if not defined MODEL set "MODEL=Unknown"
if not defined BIOSVER set "BIOSVER=Unknown"

echo Manufacturer : %MANUFACTURER%
echo Model        : %MODEL%
echo Serial       : %SERIAL%
echo BIOS Version : %BIOSVER%
echo.

if "%SERIAL%"=="Not available" (
    echo The service tag could not be read on this PC.
    echo Add the WinPE-WMI optional component to the boot image, or
    echo confirm the BIOS has a serial number programmed.
    echo.
)

pause
exit /b 0
