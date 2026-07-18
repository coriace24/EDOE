@echo off
setlocal EnableDelayedExpansion
rem Usage: AddDrivers.bat <Model>

set "MODEL=%~1"
set "DRIVERROOT=\\EDOE-MDT\ftproot\FFU\Drivers"

echo Checking Drivers...

set "DRIVERPATH="

if defined MODEL (
    if not "!MODEL:Dell Pro Laptop=!"=="!MODEL!" set "DRIVERPATH=%DRIVERROOT%\Dell Pro Laptop"
    if not defined DRIVERPATH if not "!MODEL:Dell XE5=!"=="!MODEL!" set "DRIVERPATH=%DRIVERROOT%\Dell XE5"
    if not defined DRIVERPATH if not "!MODEL:Dell T560=!"=="!MODEL!" set "DRIVERPATH=%DRIVERROOT%\Dell T560"
)

if not defined DRIVERPATH (
    echo Unknown Manufacturer
    exit /b 0
)

echo Driver Package:
echo %DRIVERPATH%

rem Mount Windows partition

mkdir C:\Mount

dism.exe /Mount-Image /ImageFile:C:\install.wim /Index:1 /MountDir:C:\Mount

dism.exe /Image:C:\Mount /Add-Driver /Driver:"%DRIVERPATH%" /Recurse

dism.exe /Unmount-Image /MountDir:C:\Mount /Commit

echo Drivers Added
exit /b 0
