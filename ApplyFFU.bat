@echo off
rem Usage: ApplyFFU.bat <ImageFile> <DiskNumber>

set "IMAGE=%~1"
set "DISK=%~2"

if "%IMAGE%"=="" (
    echo Usage: ApplyFFU.bat ^<ImageFile^> ^<DiskNumber^>
    exit /b 1
)
if "%DISK%"=="" (
    echo Usage: ApplyFFU.bat ^<ImageFile^> ^<DiskNumber^>
    exit /b 1
)

echo.
echo Applying FFU Image...

dism.exe /Apply-FFU /ImageFile:"%IMAGE%" /ApplyDrive:\\.\PhysicalDrive%DISK%

if %ERRORLEVEL% NEQ 0 (
    echo FFU Deployment Failed
    exit /b 1
)

echo FFU Applied Successfully
exit /b 0
