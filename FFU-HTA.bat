@echo off
rem ==================================================================
rem FFU-HTA.bat - launcher for the HTA front end.
rem
rem Needs only WinPE-HTA (mshta.exe) and WinPE-Scripting (WScript.Shell
rem and Scripting.FileSystemObject) in the boot image - no WMI, no .NET
rem and no PowerShell. Falls back to the console tool when mshta is not
rem present.
rem ==================================================================
setlocal

wpeinit

if not exist "%~dp0FFU-Tool.hta" (
    echo ERROR: FFU-Tool.hta not found next to this script.
    echo Expected: %~dp0FFU-Tool.hta
    pause
    exit /b 1
)

set "MSHTA=%SystemRoot%\System32\mshta.exe"
if not exist "%MSHTA%" set "MSHTA="
if not defined MSHTA for %%I in (mshta.exe) do if not "%%~$PATH:I"=="" set "MSHTA=%%~$PATH:I"
if not defined MSHTA goto NOHTA

"%MSHTA%" "%~dp0FFU-Tool.hta"
exit /b 0

:NOHTA
echo ==================================================================
echo mshta.exe is not present in this boot image, so the HTA cannot
echo start. Add these optional components to boot.wim:
echo.
echo     WinPE-HTA         (mshta.exe and the MSHTML engine)
echo     WinPE-Scripting   (WScript.Shell, FileSystemObject)
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
