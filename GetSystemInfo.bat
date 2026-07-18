@echo off
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
