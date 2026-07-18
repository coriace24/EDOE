@echo off
wpeinit

cls

rem Locate the FFU folder on the USB drive this script is running from.
rem Checked in order: next to this script, the root of the script's
rem drive, then every other drive letter. The internal disk (usually C:
rem in WinPE) and the ramdisk (X:) are checked last.

set "DEPLOYROOT="
if exist "%~dp0FFU\" set "DEPLOYROOT=%~dp0FFU"
if not defined DEPLOYROOT if exist "%~d0\FFU\" set "DEPLOYROOT=%~d0\FFU"
if not defined DEPLOYROOT for %%D in (D E F G H I J K L M N O P Q R S T U V W Y Z C X) do (
    if not defined DEPLOYROOT if exist "%%D:\FFU\" set "DEPLOYROOT=%%D:\FFU"
)

if not defined DEPLOYROOT (
    echo ERROR: Could not find a folder named FFU on any drive.
    echo Make sure the USB stick contains a FFU folder.
    pause
    exit
)

rem Mount the FFU folder as Z: so the images are always at Z:\

subst Z: /d >nul 2>&1
subst Z: "%DEPLOYROOT%"
if errorlevel 1 (
    echo ERROR: Could not mount %DEPLOYROOT% as Z:
    pause
    exit
)

:MENU
set "IMAGE="
echo ============================================
echo        FFU DEPLOYMENT MENU
echo ============================================
echo.
echo FFU folder: %DEPLOYROOT% (mounted as Z:)
echo.
echo 1 - EVS 6520
echo 2 - EVS 6521
echo 3 - EVS EMS 6520
echo 4 - EVS DC 6520
echo 5 - Exit
echo.

set /p choice=Select an image (1-5):

if "%choice%"=="1" set IMAGE=EVS6520.ffu
if "%choice%"=="2" set IMAGE=EVS6521.ffu
if "%choice%"=="3" set IMAGE=EVSEMS6520.ffu
if "%choice%"=="4" set IMAGE=EVSDC6520.ffu
if "%choice%"=="5" goto QUIT

if not defined IMAGE goto MENU

echo.
echo Selected image: %IMAGE%
echo.

echo list disk > "%TEMP%\ListDisk.txt"
diskpart /s "%TEMP%\ListDisk.txt"

set /p DISK=Enter target disk number:

echo.
echo WARNING!
echo This will erase ALL data on Disk %DISK%.
echo.
pause

dism /Apply-FFU /ImageFile:Z:\%IMAGE% /ApplyDrive:\\.\PhysicalDrive%DISK%

if errorlevel 1 (
    echo.
    echo Deployment FAILED.
    pause
    goto MENU
)

echo.
echo Deployment completed successfully.
pause

subst Z: /d >nul 2>&1
wpeutil reboot
exit

:QUIT
subst Z: /d >nul 2>&1
exit
