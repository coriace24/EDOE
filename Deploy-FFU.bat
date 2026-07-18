@echo off
setlocal EnableDelayedExpansion

cls

set "DEPLOYROOT=\\EDOE-MDT\ftproot\FFU"

echo =================================
echo      ES^&S TS FFU DEPLOYMENT
echo =================================
echo.

rem Hardware detection

for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-CimInstance Win32_BIOS).SerialNumber"`) do set "SERIAL=%%A"
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-CimInstance Win32_ComputerSystem).Model"`) do set "MODEL=%%A"
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-CimInstance Win32_ComputerSystem).Manufacturer"`) do set "MANUFACTURER=%%A"

echo Manufacturer : %MANUFACTURER%
echo Model        : %MODEL%
echo Serial       : %SERIAL%
echo.

rem Detect disk (largest NVMe/SATA disk over 100GB)

for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$d = Get-Disk | Where-Object { ($_.BusType -eq 'NVMe' -or $_.BusType -eq 'SATA') -and $_.Size -gt 100GB } | Sort-Object Size -Descending | Select-Object -First 1; if ($d) { '{0};{1:N2}' -f $d.Number, ($d.Size/1GB) }"`) do (
    for /f "tokens=1,2 delims=;" %%B in ("%%A") do (
        set "DISKNUMBER=%%B"
        set "DISKSIZE=%%C"
    )
)

if not defined DISKNUMBER (
    echo No internal disk detected
    pause
    exit /b 1
)

echo Target Disk:
echo Disk %DISKNUMBER%
echo %DISKSIZE% GB
echo.

rem Select image

echo Select FFU Image
echo.

set /a COUNT=0
for %%F in ("%DEPLOYROOT%\Images\*.ffu") do (
    set /a COUNT+=1
    set "IMG_!COUNT!=%%~fF"
    echo !COUNT! - %%~nxF
)

if %COUNT%==0 (
    echo No FFU images found in %DEPLOYROOT%\Images
    pause
    exit /b 1
)

echo.
set "CHOICE="
set /p "CHOICE=Select image number: "

set "SELECTEDIMAGE="
if defined CHOICE set "SELECTEDIMAGE=!IMG_%CHOICE%!"

if not defined SELECTEDIMAGE (
    echo Invalid Selection
    exit /b 1
)

echo.
echo Selected:
echo %SELECTEDIMAGE%

echo.
echo WARNING
echo Disk %DISKNUMBER% WILL BE ERASED
pause

rem Start logging

set "LOGFILE=%DEPLOYROOT%\Logs\Deploy_%SERIAL%.log"

>>"%LOGFILE%" echo ==========================
>>"%LOGFILE%" echo Deployment Started
>>"%LOGFILE%" echo Date %DATE% %TIME%
>>"%LOGFILE%" echo Serial %SERIAL%
>>"%LOGFILE%" echo Model %MODEL%
>>"%LOGFILE%" echo Image %SELECTEDIMAGE%

rem Apply FFU

call "%DEPLOYROOT%\Scripts\ApplyFFU.bat" "%SELECTEDIMAGE%" %DISKNUMBER%

rem Driver installation

powershell.exe -ExecutionPolicy Bypass -File "%DEPLOYROOT%\Scripts\AddDrivers.ps1" -Model "%MODEL%"

>>"%LOGFILE%" echo Deployment Completed

echo.
echo Deployment Complete

wpeutil reboot
