@echo off
setlocal EnableDelayedExpansion

wpeinit

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

if defined DISKNUMBER goto DISKOK

rem Fallback: no disk detected automatically - list disks and ask

echo No internal disk detected automatically.
echo.
>"%TEMP%\ListDisk.txt" echo list disk
diskpart /s "%TEMP%\ListDisk.txt"
echo.
set /p "DISKNUMBER=Enter target disk number: "

if not defined DISKNUMBER (
    echo No disk selected
    pause
    exit /b 1
)
set "DISKSIZE="

:DISKOK
echo.
echo Target Disk: Disk %DISKNUMBER%
if defined DISKSIZE echo %DISKSIZE% GB
echo.

rem Image selection menu

:MENU
set "IMAGE="
echo ============================================
echo        FFU DEPLOYMENT MENU
echo ============================================
echo.
echo 1 - EVS 6520
echo 2 - EVS 6521
echo 3 - EVS EMS 6520
echo 4 - EVS DC 6520
echo 5 - Exit
echo.

set "choice="
set /p "choice=Select an image (1-5): "

if "%choice%"=="1" set "IMAGE=EVS6520.ffu"
if "%choice%"=="2" set "IMAGE=EVS6521.ffu"
if "%choice%"=="3" set "IMAGE=EVSEMS6520.ffu"
if "%choice%"=="4" set "IMAGE=EVSDC6520.ffu"
if "%choice%"=="5" exit

if not defined IMAGE goto MENU

set "SELECTEDIMAGE=%DEPLOYROOT%\Images\%IMAGE%"

echo.
echo Selected image: %SELECTEDIMAGE%
echo.
echo WARNING!
echo This will erase ALL data on Disk %DISKNUMBER%.
echo.
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

if errorlevel 1 (
    >>"%LOGFILE%" echo Deployment FAILED
    echo.
    echo Deployment FAILED.
    pause
    goto MENU
)

rem Driver installation

call "%DEPLOYROOT%\Scripts\AddDrivers.bat" "%MODEL%"

>>"%LOGFILE%" echo Deployment Completed

echo.
echo Deployment completed successfully.
pause

wpeutil reboot
