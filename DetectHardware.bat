@echo off
rem ==================================================================
rem DetectHardware.bat - prints hardware identity as KEY=VALUE lines
rem
rem   MANUFACTURER=Dell Inc.
rem   MODEL=OptiPlex 7010
rem   SERIAL=ABC1234
rem   BIOSVER=1.23.0
rem
rem Only keys that were resolved are printed. Consume it with:
rem   for /f "usebackq tokens=1,* delims==" %%A in (`DetectHardware.bat`) do set "%%A=%%B"
rem
rem Detection order (first one that yields a serial wins):
rem   1. WMI via cscript          - needs WinPE-WMI
rem   2. raw SMBIOS table via cscript
rem   3. CIM via PowerShell       - needs WinPE-WMI + WinPE-PowerShell
rem   4. raw SMBIOS table via PowerShell
rem   5. wmic                     - removed on recent builds
rem   6. registry BIOS key        - rarely carries a serial
rem
rem The raw SMBIOS table (HKLM\SYSTEM\CurrentControlSet\Services\
rem mssmbios\Data\SMBiosData) is populated by the mssmbios driver on
rem every PC, so the service tag is readable even in a bare WinPE with
rem no WMI component present.
rem ==================================================================
setlocal

set "BIOSVER="
set "SERIAL="
set "MODEL="
set "MANUFACTURER="

where cscript >nul 2>&1
if errorlevel 1 goto TRYPS
set "VBS=%TEMP%\dethw_%RANDOM%.vbs"
call :WRITEVBS "%VBS%"
for /f "usebackq tokens=1,* delims==" %%A in (`cscript //nologo "%VBS%" 2^>nul`) do set "%%A=%%B"
del "%VBS%" >nul 2>&1
if defined SERIAL goto EMIT

:TRYPS
where powershell >nul 2>&1
if errorlevel 1 goto TRYWMIC
set "PS1=%TEMP%\dethw_%RANDOM%.ps1"
call :WRITEPS1 "%PS1%"
for /f "usebackq tokens=1,* delims==" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" 2^>nul`) do set "%%A=%%B"
del "%PS1%" >nul 2>&1
if defined SERIAL goto EMIT

:TRYWMIC
where wmic >nul 2>&1
if errorlevel 1 goto REGONLY
for /f "tokens=1,* delims==" %%A in ('wmic bios get serialnumber /value 2^>nul ^| find "="') do for /f "delims=" %%C in ("%%B") do set "SERIAL=%%C"
if not defined MODEL for /f "tokens=1,* delims==" %%A in ('wmic computersystem get model /value 2^>nul ^| find "="') do for /f "delims=" %%C in ("%%B") do set "MODEL=%%C"
if not defined MANUFACTURER for /f "tokens=1,* delims==" %%A in ('wmic computersystem get manufacturer /value 2^>nul ^| find "="') do for /f "delims=" %%C in ("%%B") do set "MANUFACTURER=%%C"
if not defined BIOSVER for /f "tokens=1,* delims==" %%A in ('wmic bios get smbiosbiosversion /value 2^>nul ^| find "="') do for /f "delims=" %%C in ("%%B") do set "BIOSVER=%%C"
if /i "%SERIAL%"=="To be filled by O.E.M." set "SERIAL="
if /i "%SERIAL%"=="Default string" set "SERIAL="
if /i "%SERIAL%"=="System Serial Number" set "SERIAL="
if "%SERIAL%"=="0" set "SERIAL="
if defined SERIAL goto EMIT

:REGONLY
rem Most firmware does not publish a serial here, but some OEMs do -
rem try it before giving up.
for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemSerialNumber 2^>nul ^| find "REG_"') do set "SERIAL=%%B"
if not defined SERIAL for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v BaseBoardSerialNumber 2^>nul ^| find "REG_"') do set "SERIAL=%%B"
if /i "%SERIAL%"=="To be filled by O.E.M." set "SERIAL="
if /i "%SERIAL%"=="Default string" set "SERIAL="
if /i "%SERIAL%"=="System Serial Number" set "SERIAL="
if not defined MANUFACTURER for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemManufacturer 2^>nul ^| find "REG_"') do set "MANUFACTURER=%%B"
if not defined MODEL for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemProductName 2^>nul ^| find "REG_"') do set "MODEL=%%B"
if not defined BIOSVER for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v BIOSVersion 2^>nul ^| find "REG_"') do set "BIOSVER=%%B"

:EMIT
if defined MANUFACTURER echo MANUFACTURER=%MANUFACTURER%
if defined MODEL echo MODEL=%MODEL%
if defined SERIAL echo SERIAL=%SERIAL%
if defined BIOSVER echo BIOSVER=%BIOSVER%
if defined SERIAL (exit /b 0) else (exit /b 1)

rem ------------------------------------------------------------------
rem VBScript helper: WMI query, then parse the raw SMBIOS table
rem (structure type 0 = BIOS version, type 1 = manufacturer/model/serial)
rem ------------------------------------------------------------------
:WRITEVBS
> "%~1" echo On Error Resume Next
>>"%~1" echo serial = "" : model = "" : manuf = "" : biosver = ""
>>"%~1" echo Set wmi = GetObject("winmgmts:\\.\root\cimv2")
>>"%~1" echo If Err.Number = 0 Then
>>"%~1" echo For Each b In wmi.ExecQuery("Select * From Win32_BIOS")
>>"%~1" echo serial = Clean(b.SerialNumber)
>>"%~1" echo biosver = Clean(b.SMBIOSBIOSVersion)
>>"%~1" echo Next
>>"%~1" echo For Each c In wmi.ExecQuery("Select * From Win32_ComputerSystem")
>>"%~1" echo model = Clean(c.Model)
>>"%~1" echo manuf = Clean(c.Manufacturer)
>>"%~1" echo Next
>>"%~1" echo End If
>>"%~1" echo Err.Clear
>>"%~1" echo If Len(serial) = 0 Then ParseSmbios
>>"%~1" echo If Len(serial) ^> 0 Then WScript.Echo "SERIAL=" ^& serial
>>"%~1" echo If Len(model) ^> 0 Then WScript.Echo "MODEL=" ^& model
>>"%~1" echo If Len(manuf) ^> 0 Then WScript.Echo "MANUFACTURER=" ^& manuf
>>"%~1" echo If Len(biosver) ^> 0 Then WScript.Echo "BIOSVER=" ^& biosver
>>"%~1" echo Sub ParseSmbios
>>"%~1" echo Dim data, strs(255), i, j, t, ln, cnt, s, k, ub, sh
>>"%~1" echo Set sh = CreateObject("WScript.Shell")
>>"%~1" echo data = sh.RegRead("HKLM\SYSTEM\CurrentControlSet\Services\mssmbios\Data\SMBiosData")
>>"%~1" echo If Not IsArray(data) Then Exit Sub
>>"%~1" echo ub = UBound(data)
>>"%~1" echo i = 8
>>"%~1" echo Do While i + 1 ^<= ub
>>"%~1" echo t = data(i)
>>"%~1" echo ln = data(i + 1)
>>"%~1" echo If ln ^< 4 Then Exit Do
>>"%~1" echo If i + ln ^> ub Then Exit Do
>>"%~1" echo j = i + ln
>>"%~1" echo cnt = 0
>>"%~1" echo Do While j ^<= ub
>>"%~1" echo If data(j) = 0 Then Exit Do
>>"%~1" echo s = ""
>>"%~1" echo Do While j ^<= ub
>>"%~1" echo If data(j) = 0 Then Exit Do
>>"%~1" echo s = s ^& Chr(data(j))
>>"%~1" echo j = j + 1
>>"%~1" echo Loop
>>"%~1" echo If cnt ^< 255 Then cnt = cnt + 1
>>"%~1" echo strs(cnt) = s
>>"%~1" echo j = j + 1
>>"%~1" echo Loop
>>"%~1" echo If t = 0 And ln ^>= 6 And Len(biosver) = 0 Then
>>"%~1" echo k = data(i + 5)
>>"%~1" echo If k ^> 0 And k ^<= cnt Then biosver = Clean(strs(k))
>>"%~1" echo End If
>>"%~1" echo If t = 1 And ln ^>= 8 Then
>>"%~1" echo k = data(i + 4)
>>"%~1" echo If k ^> 0 And k ^<= cnt And Len(manuf) = 0 Then manuf = Clean(strs(k))
>>"%~1" echo k = data(i + 5)
>>"%~1" echo If k ^> 0 And k ^<= cnt And Len(model) = 0 Then model = Clean(strs(k))
>>"%~1" echo k = data(i + 7)
>>"%~1" echo If k ^> 0 And k ^<= cnt Then serial = Clean(strs(k))
>>"%~1" echo End If
>>"%~1" echo If t = 127 Then Exit Do
>>"%~1" echo If cnt = 0 Then i = j + 2 Else i = j + 1
>>"%~1" echo Loop
>>"%~1" echo End Sub
>>"%~1" echo Function Clean(v)
>>"%~1" echo v = Trim("" ^& v)
>>"%~1" echo u = UCase(v)
>>"%~1" echo If u = "TO BE FILLED BY O.E.M." Or u = "DEFAULT STRING" Or u = "SYSTEM SERIAL NUMBER" Then v = ""
>>"%~1" echo If u = "NOT SPECIFIED" Or u = "NOT AVAILABLE" Or u = "NONE" Or u = "0" Then v = ""
>>"%~1" echo If u = "SYSTEM PRODUCT NAME" Or u = "SYSTEM MANUFACTURER" Or u = "OEM" Then v = ""
>>"%~1" echo Clean = v
>>"%~1" echo End Function
exit /b 0

rem ------------------------------------------------------------------
rem PowerShell helper: CIM query with the same raw SMBIOS fallback
rem ------------------------------------------------------------------
:WRITEPS1
> "%~1" echo $ErrorActionPreference = 'SilentlyContinue'
>>"%~1" echo function Clean([string]$v) {
>>"%~1" echo   $v = $v.Trim()
>>"%~1" echo   $junk = @('To be filled by O.E.M.','Default string','System Serial Number','Not Specified','Not Available','None','0','System Product Name','System manufacturer','OEM')
>>"%~1" echo   if ($junk -contains $v) { return '' }
>>"%~1" echo   return $v
>>"%~1" echo }
>>"%~1" echo $bios = Get-CimInstance Win32_BIOS
>>"%~1" echo $cs = Get-CimInstance Win32_ComputerSystem
>>"%~1" echo $serial = Clean ([string]$bios.SerialNumber)
>>"%~1" echo $model = Clean ([string]$cs.Model)
>>"%~1" echo $manuf = Clean ([string]$cs.Manufacturer)
>>"%~1" echo $biosver = Clean ([string]$bios.SMBIOSBIOSVersion)
>>"%~1" echo if (-not $serial) {
>>"%~1" echo   $d = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\mssmbios\Data').SMBiosData
>>"%~1" echo   if ($d) {
>>"%~1" echo     $i = 8
>>"%~1" echo     while ($i + 1 -lt $d.Length) {
>>"%~1" echo       $t = $d[$i]; $ln = $d[$i + 1]
>>"%~1" echo       if ($ln -lt 4 -or $i + $ln -ge $d.Length) { break }
>>"%~1" echo       $j = $i + $ln
>>"%~1" echo       $strs = @()
>>"%~1" echo       while ($j -lt $d.Length -and $d[$j] -ne 0) {
>>"%~1" echo         $s = ''
>>"%~1" echo         while ($j -lt $d.Length -and $d[$j] -ne 0) { $s += [char]$d[$j]; $j++ }
>>"%~1" echo         $strs += $s
>>"%~1" echo         $j++
>>"%~1" echo       }
>>"%~1" echo       if ($t -eq 0 -and $ln -ge 6 -and -not $biosver) {
>>"%~1" echo         $k = $d[$i + 5]
>>"%~1" echo         if ($k -gt 0 -and $k -le $strs.Count) { $biosver = Clean ($strs[$k - 1]) }
>>"%~1" echo       }
>>"%~1" echo       if ($t -eq 1 -and $ln -ge 8) {
>>"%~1" echo         $k = $d[$i + 4]
>>"%~1" echo         if ($k -gt 0 -and $k -le $strs.Count -and -not $manuf) { $manuf = Clean ($strs[$k - 1]) }
>>"%~1" echo         $k = $d[$i + 5]
>>"%~1" echo         if ($k -gt 0 -and $k -le $strs.Count -and -not $model) { $model = Clean ($strs[$k - 1]) }
>>"%~1" echo         $k = $d[$i + 7]
>>"%~1" echo         if ($k -gt 0 -and $k -le $strs.Count) { $serial = Clean ($strs[$k - 1]) }
>>"%~1" echo       }
>>"%~1" echo       if ($t -eq 127) { break }
>>"%~1" echo       if ($strs.Count -eq 0) { $i = $j + 2 } else { $i = $j + 1 }
>>"%~1" echo     }
>>"%~1" echo   }
>>"%~1" echo }
>>"%~1" echo if ($serial) { "SERIAL=$serial" }
>>"%~1" echo if ($model) { "MODEL=$model" }
>>"%~1" echo if ($manuf) { "MANUFACTURER=$manuf" }
>>"%~1" echo if ($biosver) { "BIOSVER=$biosver" }
exit /b 0
