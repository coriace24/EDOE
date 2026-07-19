@echo off
setlocal

wpeinit

cls
echo =================================
echo       SYSTEM INFORMATION
echo =================================
echo.

set "BIOSVER="
set "SERIAL="
set "MODEL="
set "MANUFACTURER="

where cscript >nul 2>&1
if errorlevel 1 goto REGONLY

rem Query WMI through a temporary VBScript (works where wmic is removed)
set "VBS=%TEMP%\getsysinfo.vbs"
> "%VBS%" echo On Error Resume Next
>>"%VBS%" echo Set wmi = GetObject("winmgmts:\\.\root\cimv2")
>>"%VBS%" echo For Each b In wmi.ExecQuery("Select * From Win32_BIOS")
>>"%VBS%" echo WScript.Echo "BIOSVER=" ^& b.SMBIOSBIOSVersion
>>"%VBS%" echo WScript.Echo "SERIAL=" ^& b.SerialNumber
>>"%VBS%" echo Next
>>"%VBS%" echo For Each c In wmi.ExecQuery("Select * From Win32_ComputerSystem")
>>"%VBS%" echo WScript.Echo "MODEL=" ^& c.Model
>>"%VBS%" echo WScript.Echo "MANUFACTURER=" ^& c.Manufacturer
>>"%VBS%" echo Next

for /f "usebackq tokens=1,* delims==" %%A in (`cscript //nologo "%VBS%"`) do set "%%A=%%B"

del "%VBS%" >nul 2>&1

if defined SERIAL goto SHOW

:REGONLY
rem Fallback: read what the registry exposes (serial is not in the registry)
for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemManufacturer 2^>nul ^| find "REG_"') do set "MANUFACTURER=%%B"
for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemProductName 2^>nul ^| find "REG_"') do set "MODEL=%%B"
for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v BIOSVersion 2^>nul ^| find "REG_"') do set "BIOSVER=%%B"
if not defined SERIAL set "SERIAL=Not available"

:SHOW
echo Manufacturer : %MANUFACTURER%
echo Model        : %MODEL%
echo Serial       : %SERIAL%
echo BIOS Version : %BIOSVER%
echo.
pause

:MENU
cls
echo =================================
echo    FFU CAPTURE / DEPLOY TOOL
echo =================================
echo.
echo 1. USB Drive Mount
echo 2. Capture FFU Image
echo 3. Deploy FFU Image
echo 4. Exit
echo.
set "CHOICE="
set /p "CHOICE=Select an option (1-4): "
if "%CHOICE%"=="1" goto USBMOUNT
if "%CHOICE%"=="2" goto CAPTURE
if "%CHOICE%"=="3" goto DEPLOY
if "%CHOICE%"=="4" exit /b 0
echo Invalid selection.
pause
goto MENU

:USBMOUNT
cls
echo ==========================================
echo          USB Drive Mount Utility
echo ==========================================
echo.
echo Listing available volumes...
echo.
(
echo list volume
echo exit
) > "%TEMP%\listvol.txt"
diskpart /s "%TEMP%\listvol.txt"
del "%TEMP%\listvol.txt" >nul 2>&1
echo.
set "VOLNUM="
set /p "VOLNUM=Enter the USB Volume Number: "
if not defined VOLNUM (
    echo No volume selected.
    pause
    goto MENU
)
set "DRIVELETTER="
set /p "DRIVELETTER=Enter the drive letter to assign (Example: E): "
rem Accept "E:" as well as "E"
if defined DRIVELETTER set "DRIVELETTER=%DRIVELETTER::=%"
if not defined DRIVELETTER (
    echo No drive letter entered.
    pause
    goto MENU
)
echo.
echo Mounting volume %VOLNUM% as %DRIVELETTER%: ...
echo.
(
echo select volume %VOLNUM%
echo assign letter=%DRIVELETTER%
echo exit
) > "%TEMP%\mountusb.txt"
diskpart /s "%TEMP%\mountusb.txt"
set "MOUNTRESULT=%errorlevel%"
del "%TEMP%\mountusb.txt" >nul 2>&1
echo.
if "%MOUNTRESULT%"=="0" (
    echo =================================
    echo          Mount Completed
    echo =================================
) else (
    echo Mount FAILED.
)
pause
goto MENU

:CAPTURE
cls
echo =================================
echo         FFU IMAGE CAPTURE
echo =================================
echo.
set "SOURCEDISK="
set /p "SOURCEDISK=Enter source PhysicalDrive number (example: 0): "
if not defined SOURCEDISK (
    echo No source disk entered.
    pause
    goto MENU
)
echo.
echo Available drive letters:
echo.
fsutil fsinfo drives
echo.
set "USBDRIVE="
set /p "USBDRIVE=Enter destination drive letter (example: D): "
if defined USBDRIVE set "USBDRIVE=%USBDRIVE::=%"
if not defined USBDRIVE (
    echo No destination drive entered.
    pause
    goto MENU
)
echo.
set "FFUNAME="
set /p "FFUNAME=Enter FFU filename (example: Server2022.ffu): "
if not defined FFUNAME (
    echo No filename entered.
    pause
    goto MENU
)
echo.
echo Capturing FFU...
echo.
dism /Capture-FFU ^
 /ImageFile:"%USBDRIVE%:\%FFUNAME%" ^
 /CaptureDrive:\\.\PhysicalDrive%SOURCEDISK% ^
 /Name:"CAPTURE"
set "CAPTURERESULT=%errorlevel%"
if "%CAPTURERESULT%"=="0" (
    echo.
    echo Capture completed successfully.
) else (
    echo.
    echo Capture FAILED.
)
pause
goto MENU

:DEPLOY
cls
set "IMAGE="
echo =================================
echo        FFU DEPLOYMENT MENU
echo =================================
echo.
echo 1 - EVS 6520 WS
echo 2 - EVS 6521 WS
echo 3 - EVS 6520 RR
echo 4 - EVS 6520 EMS
echo 5 - EVS 6521 EMS
echo 6 - EVS 6520 DC
echo 7 - Exit
echo.
set "choice="
set /p "choice=Select an image (1-7): "
if "%choice%"=="1" set "IMAGE=EVS6520WS.ffu"
if "%choice%"=="2" set "IMAGE=EVS6521WS.ffu"
if "%choice%"=="3" set "IMAGE=EVS6520RR.ffu"
if "%choice%"=="4" set "IMAGE=EVS6520EMS.ffu"
if "%choice%"=="5" set "IMAGE=EVS6521EMS.ffu"
if "%choice%"=="6" set "IMAGE=EVS6520DC.ffu"
if "%choice%"=="7" exit /b 0
if not defined IMAGE (
    echo Invalid selection.
    pause
    goto DEPLOY
)
echo.
(
echo list disk
echo exit
) > "%TEMP%\listdisk.txt"
diskpart /s "%TEMP%\listdisk.txt"
del "%TEMP%\listdisk.txt" >nul 2>&1
echo.
set "DISK="
set /p "DISK=Enter target disk number: "
if not defined DISK (
    echo No disk selected.
    pause
    goto MENU
)
echo.
echo Target Disk: Disk %DISK%
echo.
echo Available drive letters:
echo.
fsutil fsinfo drives
echo.
set "SOURCEDRIVE="
set /p "SOURCEDRIVE=Enter Source Drive letter (example: F): "
if defined SOURCEDRIVE set "SOURCEDRIVE=%SOURCEDRIVE::=%"
if not defined SOURCEDRIVE (
    echo No source drive entered.
    pause
    goto MENU
)
set "SELECTEDIMAGE=%SOURCEDRIVE%:\Images\%IMAGE%"
echo.
echo Selected image: %SELECTEDIMAGE%
echo.
echo WARNING!
echo.
echo This will erase ALL data on Disk %DISK%.
echo.
set "CONFIRM="
set /p "CONFIRM=Type YES to continue or press Enter to cancel: "
if /i not "%CONFIRM%"=="YES" (
    echo Deployment cancelled.
    pause
    goto MENU
)
echo.
echo Applying FFU Image...
dism /Apply-FFU /ImageFile:"%SELECTEDIMAGE%" /ApplyDrive:\\.\PhysicalDrive%DISK%
set "DEPLOYRESULT=%errorlevel%"
if "%DEPLOYRESULT%"=="0" (
    echo.
    echo Deployment completed successfully.
) else (
    echo.
    echo Deployment FAILED.
)
pause
goto MENU
