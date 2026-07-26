@echo off
rem ==================================================================
rem FFU-GUI.bat - launcher for the graphical FFU Capture / Deploy tool.
rem
rem WinForms needs single-threaded apartment mode, which is why this
rem starts PowerShell with -STA rather than running the .ps1 directly.
rem Falls back to the console tool when PowerShell is not in the image.
rem ==================================================================
setlocal

wpeinit

where powershell >nul 2>&1
if errorlevel 1 goto NOPS

if not exist "%~dp0FFU-GUI.ps1" (
    echo ERROR: FFU-GUI.ps1 not found next to this script.
    echo Expected: %~dp0FFU-GUI.ps1
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0FFU-GUI.ps1"
set "RC=%errorlevel%"
if not "%RC%"=="0" (
    echo.
    echo The GUI exited with code %RC%.
    pause
)
exit /b %RC%

:NOPS
echo ==================================================================
echo PowerShell is not present in this boot image, so the GUI cannot
echo start. Add these optional components to boot.wim:
echo.
echo     WinPE-WMI, WinPE-NetFX, WinPE-Scripting, WinPE-PowerShell
echo     WinPE-StorageWMI  (optional - enables Get-Disk)
echo.
echo Falling back to the console tool.
echo ==================================================================
echo.
pause
if exist "%~dp0FFU-Tool.bat" (
    call "%~dp0FFU-Tool.bat"
    exit /b %errorlevel%
)
echo FFU-Tool.bat not found either.
pause
exit /b 1
