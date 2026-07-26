#Requires -Version 3.0
<#
    FFU Capture / Deploy Tool - graphical front end.

    Runs the same operations as FFU-Tool.bat (hardware identity, USB
    mount, FFU capture, FFU deploy) in a WinForms window.

    Boot image requirements (add with Dism /Add-Package to boot.wim):
        WinPE-WMI          - required by WinPE-PowerShell
        WinPE-NetFX        - required by WinPE-PowerShell
        WinPE-Scripting    - required by WinPE-PowerShell
        WinPE-PowerShell   - this script
        WinPE-StorageWMI   - optional, enables Get-Disk (diskpart is
                             parsed instead when it is absent)

    Hardware identity comes from DetectHardware.bat when it is present
    next to this script, so the service tag is still read on images
    without WMI. Disk and volume enumeration falls back to parsing
    diskpart output when the Storage cmdlets are unavailable.

    Launch it with FFU-GUI.bat (sets -STA, which WinForms requires).
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:SessionLog = Join-Path $env:TEMP ('FFU-GUI_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

# State for the running child process (dism)
$script:Proc = $null
$script:ProcOut = $null
$script:ProcErr = $null
$script:ProcOutPos = 0
$script:ProcErrPos = 0
$script:ProcKind = ''
$script:ProcTarget = ''
$script:LastPercent = -1
$script:LastDiskpartExit = -1

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -le 0) { return '' }
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt ($units.Count - 1)) {
        $Bytes = $Bytes / 1024
        $i++
    }
    return ('{0:N1} {1}' -f $Bytes, $units[$i])
}

function Write-Log {
    param([string]$Text, [string]$Level = 'INFO')
    if ($null -eq $Text) { return }
    $stamp = Get-Date -Format 'HH:mm:ss'
    foreach ($line in ($Text -split "`r`n|`r|`n")) {
        $t = $line.TrimEnd()
        if ($t.Length -eq 0) { continue }
        $entry = '[{0}] {1}' -f $stamp, $t
        $script:LogBox.AppendText($entry + [Environment]::NewLine)
        try { Add-Content -LiteralPath $script:SessionLog -Value ('{0} {1} {2}' -f $stamp, $Level, $t) -ErrorAction SilentlyContinue } catch { }
    }
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
}

function Set-Status {
    param([string]$Text)
    $script:StatusLabel.Text = $Text
    $script:Form.Refresh()
}

function Show-Info {
    param([string]$Text, [string]$Title = 'FFU Tool')
    [void][System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Show-Warn {
    param([string]$Text, [string]$Title = 'FFU Tool')
    [void][System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
}

# Reads text appended to a file since the last call. Opens with full
# sharing so it can tail a file dism still has open.
function Read-NewText {
    param([string]$Path, [ref]$Position)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($fs.Length -le $Position.Value) { return '' }
        $count = [int]($fs.Length - $Position.Value)
        $fs.Position = $Position.Value
        $buffer = New-Object byte[] $count
        $read = $fs.Read($buffer, 0, $count)
        $Position.Value = $Position.Value + $read
        return [System.Text.Encoding]::Default.GetString($buffer, 0, $read)
    } catch {
        return ''
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

# ------------------------------------------------------------------
# diskpart
# ------------------------------------------------------------------

function Invoke-Diskpart {
    param([string[]]$Commands)
    $file = Join-Path $env:TEMP ('ffugui_dp_{0}.txt' -f (Get-Random))
    $script:LastDiskpartExit = -1
    try {
        Set-Content -LiteralPath $file -Value ($Commands + 'exit') -Encoding ASCII
        $out = & diskpart.exe /s $file 2>&1 | Out-String
        $script:LastDiskpartExit = $LASTEXITCODE
        return $out
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

# diskpart prints fixed-width tables under a row of dashes. Column
# positions are taken from that dashes row, so labels containing
# spaces do not shift the parse and it survives localized headers.
function ConvertFrom-DiskpartTable {
    param([string]$Text)
    $lines = $Text -split "`r`n|`r|`n"
    $sep = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-{3,}(\s+-{3,})+\s*$') { $sep = $i; break }
    }
    if ($sep -lt 0) { return @() }

    $spans = @()
    $rx = [regex]'-+'
    foreach ($m in $rx.Matches($lines[$sep])) {
        $spans += , @($m.Index, $m.Length)
    }

    $rows = @()
    for ($i = $sep + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim().Length -eq 0) { continue }
        if ($line -notmatch '\d') { continue }
        $cols = @()
        foreach ($span in $spans) {
            $start = $span[0]
            $len = $span[1]
            if ($start -ge $line.Length) {
                $cols += ''
                continue
            }
            # Take the column plus one trailing char; values sometimes
            # run a character wider than the dashes.
            $take = [Math]::Min($len + 1, $line.Length - $start)
            $cols += $line.Substring($start, $take).Trim()
        }
        $rows += , $cols
    }
    return $rows
}

function Get-DiskList {
    $result = @()
    $useStorage = $true
    try {
        $disks = @(Get-Disk -ErrorAction Stop)
    } catch {
        $useStorage = $false
        $disks = @()
    }

    if ($useStorage -and $disks.Count -gt 0) {
        foreach ($d in $disks) {
            $result += [pscustomobject]@{
                Number = [int]$d.Number
                Size   = Format-Size $d.Size
                Model  = ('' + $d.FriendlyName).Trim()
                Bus    = ('' + $d.BusType).Trim()
                Style  = ('' + $d.PartitionStyle).Trim()
                Source = 'Get-Disk'
            }
        }
        return $result
    }

    # Fallback: parse "list disk"
    $out = Invoke-Diskpart @('rescan', 'list disk')
    foreach ($cols in (ConvertFrom-DiskpartTable $out)) {
        if ($cols.Count -lt 3) { continue }
        if ($cols[0] -notmatch '(\d+)') { continue }
        $num = [int]$matches[1]
        $style = ''
        if ($cols.Count -ge 6 -and $cols[5] -match '\*') { $style = 'GPT' }
        elseif ($cols.Count -ge 3) { $style = 'MBR' }
        $result += [pscustomobject]@{
            Number = $num
            Size   = $cols[2]
            Model  = ''
            Bus    = ''
            Style  = $style
            Source = 'diskpart'
        }
    }
    return $result
}

function Get-VolumeList {
    $out = Invoke-Diskpart @('rescan', 'list volume')
    $result = @()
    foreach ($cols in (ConvertFrom-DiskpartTable $out)) {
        if ($cols.Count -lt 6) { continue }
        if ($cols[0] -notmatch '(\d+)') { continue }
        $result += [pscustomobject]@{
            Number = [int]$matches[1]
            Letter = $cols[1]
            Label  = $cols[2]
            Fs     = $cols[3]
            Type   = $cols[4]
            Size   = $cols[5]
            Status = $(if ($cols.Count -ge 7) { $cols[6] } else { '' })
            Info   = $(if ($cols.Count -ge 8) { $cols[7] } else { '' })
        }
    }
    return $result
}

function Get-FreeDriveLetters {
    $used = @{}
    foreach ($v in (Get-VolumeList)) {
        if ($v.Letter -match '^[A-Za-z]$') { $used[$v.Letter.ToUpper()] = $true }
    }
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        $l = $d.Name.Substring(0, 1).ToUpper()
        $used[$l] = $true
    }
    $free = @()
    foreach ($c in [char[]]'DEFGHIJKLMNOPQRSTUVWXYZ') {
        if (-not $used.ContainsKey([string]$c)) { $free += [string]$c }
    }
    return $free
}

# ------------------------------------------------------------------
# Hardware identity
# ------------------------------------------------------------------

function Get-HardwareInfo {
    $info = @{ MANUFACTURER = ''; MODEL = ''; SERIAL = ''; BIOSVER = '' }

    $detect = Join-Path $script:Root 'DetectHardware.bat'
    if (Test-Path -LiteralPath $detect) {
        try {
            $lines = & cmd.exe /c "`"$detect`"" 2>$null
            foreach ($line in $lines) {
                if ($line -match '^\s*(MANUFACTURER|MODEL|SERIAL|BIOSVER)=(.*)$') {
                    $info[$matches[1]] = $matches[2].Trim()
                }
            }
        } catch { }
    }

    if (-not $info['SERIAL']) {
        try {
            $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            if (-not $info['SERIAL']) { $info['SERIAL'] = ('' + $bios.SerialNumber).Trim() }
            if (-not $info['BIOSVER']) { $info['BIOSVER'] = ('' + $bios.SMBIOSBIOSVersion).Trim() }
            if (-not $info['MODEL']) { $info['MODEL'] = ('' + $cs.Model).Trim() }
            if (-not $info['MANUFACTURER']) { $info['MANUFACTURER'] = ('' + $cs.Manufacturer).Trim() }
        } catch { }
    }

    $junk = @('To be filled by O.E.M.', 'Default string', 'System Serial Number',
        'Not Specified', 'Not Available', 'None', '0', 'System Product Name',
        'System manufacturer', 'OEM')
    foreach ($k in @($info.Keys)) {
        if ($junk -contains $info[$k]) { $info[$k] = '' }
    }
    return $info
}

function Update-HardwareInfo {
    Set-Status 'Reading hardware information...'
    $info = Get-HardwareInfo
    $script:HwManufacturer.Text = $(if ($info['MANUFACTURER']) { $info['MANUFACTURER'] } else { 'Unknown' })
    $script:HwModel.Text = $(if ($info['MODEL']) { $info['MODEL'] } else { 'Unknown' })
    $script:HwBios.Text = $(if ($info['BIOSVER']) { $info['BIOSVER'] } else { 'Unknown' })
    if ($info['SERIAL']) {
        $script:HwSerial.Text = $info['SERIAL']
        $script:HwSerial.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
        $script:Serial = $info['SERIAL']
    } else {
        $script:HwSerial.Text = 'Not available - add WinPE-WMI to the boot image'
        $script:HwSerial.ForeColor = [System.Drawing.Color]::Firebrick
        $script:Serial = ''
    }
    Write-Log ('Hardware: {0} / {1} / serial {2}' -f $script:HwManufacturer.Text, $script:HwModel.Text, $script:HwSerial.Text)
    Set-Status 'Ready'
}

# ------------------------------------------------------------------
# Confirmation dialog that requires typing YES
# ------------------------------------------------------------------

function Confirm-Destructive {
    param([string]$Message, [string]$Detail)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Confirm - data will be erased'
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(520, 250)

    $icon = New-Object System.Windows.Forms.Label
    $icon.Text = 'WARNING'
    $icon.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $icon.ForeColor = [System.Drawing.Color]::Firebrick
    $icon.Location = New-Object System.Drawing.Point(20, 15)
    $icon.Size = New-Object System.Drawing.Size(200, 30)
    $dlg.Controls.Add($icon)

    $msg = New-Object System.Windows.Forms.Label
    $msg.Text = $Message
    $msg.Location = New-Object System.Drawing.Point(20, 50)
    $msg.Size = New-Object System.Drawing.Size(480, 40)
    $msg.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($msg)

    $det = New-Object System.Windows.Forms.Label
    $det.Text = $Detail
    $det.Location = New-Object System.Drawing.Point(20, 95)
    $det.Size = New-Object System.Drawing.Size(480, 65)
    $dlg.Controls.Add($det)

    $prompt = New-Object System.Windows.Forms.Label
    $prompt.Text = 'Type YES to continue:'
    $prompt.Location = New-Object System.Drawing.Point(20, 165)
    $prompt.Size = New-Object System.Drawing.Size(150, 20)
    $dlg.Controls.Add($prompt)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(175, 162)
    $box.Size = New-Object System.Drawing.Size(120, 24)
    $box.CharacterCasing = 'Upper'
    $dlg.Controls.Add($box)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Erase and continue'
    $ok.Location = New-Object System.Drawing.Point(255, 205)
    $ok.Size = New-Object System.Drawing.Size(140, 30)
    $ok.Enabled = $false
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(405, 205)
    $cancel.Size = New-Object System.Drawing.Size(95, 30)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($cancel)

    $box.Add_TextChanged({ $ok.Enabled = ($box.Text.Trim() -ceq 'YES') })

    $dlg.AcceptButton = $null
    $dlg.CancelButton = $cancel
    $r = $dlg.ShowDialog($script:Form)
    $typed = $box.Text.Trim()
    $dlg.Dispose()
    return (($r -eq [System.Windows.Forms.DialogResult]::OK) -and ($typed -ceq 'YES'))
}

# ------------------------------------------------------------------
# Running dism without freezing the UI
# ------------------------------------------------------------------

function Start-Dism {
    param([string[]]$Arguments, [string]$Kind, [string]$Target)

    if ($script:Proc -and -not $script:Proc.HasExited) {
        Show-Warn 'An operation is already running.'
        return
    }

    $stamp = Get-Random
    $script:ProcOut = Join-Path $env:TEMP ('ffugui_out_{0}.txt' -f $stamp)
    $script:ProcErr = Join-Path $env:TEMP ('ffugui_err_{0}.txt' -f $stamp)
    $script:ProcOutPos = 0
    $script:ProcErrPos = 0
    $script:ProcKind = $Kind
    $script:ProcTarget = $Target
    $script:LastPercent = -1

    Write-Log ('Running: dism.exe {0}' -f ($Arguments -join ' '))
    Set-Status ('{0} in progress...' -f $Kind)
    $script:Progress.Value = 0
    Set-Busy $true

    try {
        $script:Proc = Start-Process -FilePath 'dism.exe' -ArgumentList $Arguments `
            -RedirectStandardOutput $script:ProcOut -RedirectStandardError $script:ProcErr `
            -NoNewWindow -PassThru
    } catch {
        Write-Log ('Failed to start dism: {0}' -f $_.Exception.Message) 'ERROR'
        Set-Status 'Failed to start dism'
        Set-Busy $false
        return
    }
    $script:Timer.Start()
}

function Update-FromProcess {
    $text = Read-NewText -Path $script:ProcOut -Position ([ref]$script:ProcOutPos)
    $text += Read-NewText -Path $script:ProcErr -Position ([ref]$script:ProcErrPos)

    if ($text) {
        foreach ($chunk in ($text -split "`r`n|`r|`n")) {
            $t = $chunk.Trim()
            if ($t.Length -eq 0) { continue }
            if ($t -match '(\d+(?:[\.,]\d+)?)%') {
                $p = [int][double]($matches[1] -replace ',', '.')
                if ($p -ge 0 -and $p -le 100) {
                    $script:Progress.Value = $p
                    if ($p -ne $script:LastPercent) {
                        $script:LastPercent = $p
                        Set-Status ('{0} in progress... {1}%' -f $script:ProcKind, $p)
                    }
                }
                # Progress bars redraw constantly; keep them out of the log.
                if ($t -match '^[\[\]=\s\d\.,%]+$') { continue }
            }
            Write-Log $t
        }
    }

    if ($script:Proc -and $script:Proc.HasExited) {
        $script:Timer.Stop()
        $code = $script:Proc.ExitCode
        # Drain anything written between the last tick and exit.
        $tail = Read-NewText -Path $script:ProcOut -Position ([ref]$script:ProcOutPos)
        $tail += Read-NewText -Path $script:ProcErr -Position ([ref]$script:ProcErrPos)
        foreach ($chunk in ($tail -split "`r`n|`r|`n")) {
            $t = $chunk.Trim()
            if ($t.Length -eq 0) { continue }
            if ($t -match '^[\[\]=\s\d\.,%]+$') { continue }
            Write-Log $t
        }

        Remove-Item -LiteralPath $script:ProcOut -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:ProcErr -Force -ErrorAction SilentlyContinue

        if ($code -eq 0) {
            $script:Progress.Value = 100
            Write-Log ('{0} completed successfully ({1})' -f $script:ProcKind, $script:ProcTarget) 'OK'
            Set-Status ('{0} completed successfully' -f $script:ProcKind)
            Show-Info ('{0} completed successfully.' -f $script:ProcKind)
        } else {
            Write-Log ('{0} FAILED with exit code {1}' -f $script:ProcKind, $code) 'ERROR'
            Set-Status ('{0} FAILED (exit code {1})' -f $script:ProcKind, $code)
            Show-Warn ('{0} FAILED.{1}{1}dism exit code: {2}{1}See the log for details.' -f $script:ProcKind, [Environment]::NewLine, $code)
        }
        $script:Proc = $null
        Set-Busy $false
    }
}

function Set-Busy {
    param([bool]$Busy)
    $script:DeployButton.Enabled = -not $Busy
    $script:CaptureButton.Enabled = -not $Busy
    $script:MountButton.Enabled = -not $Busy
    $script:RefreshDisksButton.Enabled = -not $Busy
    $script:RefreshVolumesButton.Enabled = -not $Busy
    $script:RefreshCaptureDisksButton.Enabled = -not $Busy
    $script:RefreshImagesButton.Enabled = -not $Busy
    $script:HwRefreshButton.Enabled = -not $Busy
    $script:StopButton.Enabled = ($Busy -and $script:ProcKind -eq 'Capture')
    if ($Busy) {
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::AppStarting
    } else {
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
        $script:ProcKind = ''
    }
}

# ------------------------------------------------------------------
# Form
# ------------------------------------------------------------------

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'FFU Capture / Deploy Tool'
$script:Form.StartPosition = 'CenterScreen'
$script:Form.ClientSize = New-Object System.Drawing.Size(940, 720)
$script:Form.MinimumSize = New-Object System.Drawing.Size(900, 700)
$script:Form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# --- System information -------------------------------------------
$hwGroup = New-Object System.Windows.Forms.GroupBox
$hwGroup.Text = 'System Information'
$hwGroup.Location = New-Object System.Drawing.Point(12, 10)
$hwGroup.Size = New-Object System.Drawing.Size(916, 100)
$hwGroup.Anchor = 'Top,Left,Right'
$script:Form.Controls.Add($hwGroup)

function New-FieldLabel {
    param([string]$Text, [int]$X, [int]$Y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size(95, 20)
    return $l
}

function New-FieldValue {
    param([int]$X, [int]$Y, [int]$W)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = '...'
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, 20)
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $l.AutoEllipsis = $true
    return $l
}

$hwGroup.Controls.Add((New-FieldLabel 'Manufacturer:' 15 28))
$script:HwManufacturer = New-FieldValue 110 28 250
$hwGroup.Controls.Add($script:HwManufacturer)

$hwGroup.Controls.Add((New-FieldLabel 'Model:' 15 55))
$script:HwModel = New-FieldValue 110 55 250
$hwGroup.Controls.Add($script:HwModel)

$hwGroup.Controls.Add((New-FieldLabel 'Service tag:' 390 28))
$script:HwSerial = New-FieldValue 485 28 300
$hwGroup.Controls.Add($script:HwSerial)

$hwGroup.Controls.Add((New-FieldLabel 'BIOS version:' 390 55))
$script:HwBios = New-FieldValue 485 55 300
$hwGroup.Controls.Add($script:HwBios)

$script:HwRefreshButton = New-Object System.Windows.Forms.Button
$script:HwRefreshButton.Text = 'Refresh'
$script:HwRefreshButton.Location = New-Object System.Drawing.Point(805, 38)
$script:HwRefreshButton.Size = New-Object System.Drawing.Size(95, 30)
$script:HwRefreshButton.Anchor = 'Top,Right'
$script:HwRefreshButton.Add_Click({ Update-HardwareInfo })
$hwGroup.Controls.Add($script:HwRefreshButton)

# --- Tabs ----------------------------------------------------------
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 118)
$tabs.Size = New-Object System.Drawing.Size(916, 350)
$tabs.Anchor = 'Top,Left,Right'
$script:Form.Controls.Add($tabs)

$tabDeploy = New-Object System.Windows.Forms.TabPage
$tabDeploy.Text = '  Deploy FFU  '
$tabDeploy.UseVisualStyleBackColor = $true
$tabs.TabPages.Add($tabDeploy)

$tabCapture = New-Object System.Windows.Forms.TabPage
$tabCapture.Text = '  Capture FFU  '
$tabCapture.UseVisualStyleBackColor = $true
$tabs.TabPages.Add($tabCapture)

$tabUsb = New-Object System.Windows.Forms.TabPage
$tabUsb.Text = '  USB Drive Mount  '
$tabUsb.UseVisualStyleBackColor = $true
$tabs.TabPages.Add($tabUsb)

# ---------------- Deploy tab ---------------------------------------
$lblTargetDisk = New-Object System.Windows.Forms.Label
$lblTargetDisk.Text = 'Target disk (will be completely erased):'
$lblTargetDisk.Location = New-Object System.Drawing.Point(12, 12)
$lblTargetDisk.Size = New-Object System.Drawing.Size(300, 20)
$tabDeploy.Controls.Add($lblTargetDisk)

$script:DiskList = New-Object System.Windows.Forms.ListView
$script:DiskList.Location = New-Object System.Drawing.Point(12, 34)
$script:DiskList.Size = New-Object System.Drawing.Size(560, 130)
$script:DiskList.View = 'Details'
$script:DiskList.FullRowSelect = $true
$script:DiskList.MultiSelect = $false
$script:DiskList.GridLines = $true
$script:DiskList.HideSelection = $false
[void]$script:DiskList.Columns.Add('Disk', 50)
[void]$script:DiskList.Columns.Add('Size', 90)
[void]$script:DiskList.Columns.Add('Model', 240)
[void]$script:DiskList.Columns.Add('Bus', 70)
[void]$script:DiskList.Columns.Add('Style', 60)
$tabDeploy.Controls.Add($script:DiskList)

$script:RefreshDisksButton = New-Object System.Windows.Forms.Button
$script:RefreshDisksButton.Text = 'Rescan disks'
$script:RefreshDisksButton.Location = New-Object System.Drawing.Point(585, 34)
$script:RefreshDisksButton.Size = New-Object System.Drawing.Size(120, 30)
$tabDeploy.Controls.Add($script:RefreshDisksButton)

$lblImage = New-Object System.Windows.Forms.Label
$lblImage.Text = 'FFU image:'
$lblImage.Location = New-Object System.Drawing.Point(12, 175)
$lblImage.Size = New-Object System.Drawing.Size(120, 20)
$tabDeploy.Controls.Add($lblImage)

$script:ImageList = New-Object System.Windows.Forms.ListView
$script:ImageList.Location = New-Object System.Drawing.Point(12, 197)
$script:ImageList.Size = New-Object System.Drawing.Size(560, 110)
$script:ImageList.View = 'Details'
$script:ImageList.FullRowSelect = $true
$script:ImageList.MultiSelect = $false
$script:ImageList.GridLines = $true
$script:ImageList.HideSelection = $false
[void]$script:ImageList.Columns.Add('Image', 250)
[void]$script:ImageList.Columns.Add('Size', 90)
[void]$script:ImageList.Columns.Add('Location', 210)
$tabDeploy.Controls.Add($script:ImageList)

$script:RefreshImagesButton = New-Object System.Windows.Forms.Button
$script:RefreshImagesButton.Text = 'Scan for images'
$script:RefreshImagesButton.Location = New-Object System.Drawing.Point(585, 197)
$script:RefreshImagesButton.Size = New-Object System.Drawing.Size(120, 30)
$tabDeploy.Controls.Add($script:RefreshImagesButton)

$browseImage = New-Object System.Windows.Forms.Button
$browseImage.Text = 'Browse...'
$browseImage.Location = New-Object System.Drawing.Point(585, 233)
$browseImage.Size = New-Object System.Drawing.Size(120, 30)
$tabDeploy.Controls.Add($browseImage)

$script:DeployButton = New-Object System.Windows.Forms.Button
$script:DeployButton.Text = 'Deploy image to disk'
$script:DeployButton.Location = New-Object System.Drawing.Point(730, 197)
$script:DeployButton.Size = New-Object System.Drawing.Size(160, 66)
$script:DeployButton.BackColor = [System.Drawing.Color]::FromArgb(200, 30, 30)
$script:DeployButton.ForeColor = [System.Drawing.Color]::White
$script:DeployButton.FlatStyle = 'Flat'
$script:DeployButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$tabDeploy.Controls.Add($script:DeployButton)

# ---------------- Capture tab --------------------------------------
$lblSourceDisk = New-Object System.Windows.Forms.Label
$lblSourceDisk.Text = 'Source disk to capture:'
$lblSourceDisk.Location = New-Object System.Drawing.Point(12, 12)
$lblSourceDisk.Size = New-Object System.Drawing.Size(300, 20)
$tabCapture.Controls.Add($lblSourceDisk)

$script:CaptureDiskList = New-Object System.Windows.Forms.ListView
$script:CaptureDiskList.Location = New-Object System.Drawing.Point(12, 34)
$script:CaptureDiskList.Size = New-Object System.Drawing.Size(560, 130)
$script:CaptureDiskList.View = 'Details'
$script:CaptureDiskList.FullRowSelect = $true
$script:CaptureDiskList.MultiSelect = $false
$script:CaptureDiskList.GridLines = $true
$script:CaptureDiskList.HideSelection = $false
[void]$script:CaptureDiskList.Columns.Add('Disk', 50)
[void]$script:CaptureDiskList.Columns.Add('Size', 90)
[void]$script:CaptureDiskList.Columns.Add('Model', 240)
[void]$script:CaptureDiskList.Columns.Add('Bus', 70)
[void]$script:CaptureDiskList.Columns.Add('Style', 60)
$tabCapture.Controls.Add($script:CaptureDiskList)

$script:RefreshCaptureDisksButton = New-Object System.Windows.Forms.Button
$script:RefreshCaptureDisksButton.Text = 'Rescan disks'
$script:RefreshCaptureDisksButton.Location = New-Object System.Drawing.Point(585, 34)
$script:RefreshCaptureDisksButton.Size = New-Object System.Drawing.Size(120, 30)
$tabCapture.Controls.Add($script:RefreshCaptureDisksButton)

$lblDest = New-Object System.Windows.Forms.Label
$lblDest.Text = 'Destination folder:'
$lblDest.Location = New-Object System.Drawing.Point(12, 180)
$lblDest.Size = New-Object System.Drawing.Size(120, 20)
$tabCapture.Controls.Add($lblDest)

$script:CaptureFolder = New-Object System.Windows.Forms.TextBox
$script:CaptureFolder.Location = New-Object System.Drawing.Point(140, 177)
$script:CaptureFolder.Size = New-Object System.Drawing.Size(432, 24)
$tabCapture.Controls.Add($script:CaptureFolder)

$browseFolder = New-Object System.Windows.Forms.Button
$browseFolder.Text = 'Browse...'
$browseFolder.Location = New-Object System.Drawing.Point(585, 175)
$browseFolder.Size = New-Object System.Drawing.Size(120, 28)
$tabCapture.Controls.Add($browseFolder)

$lblFile = New-Object System.Windows.Forms.Label
$lblFile.Text = 'File name:'
$lblFile.Location = New-Object System.Drawing.Point(12, 215)
$lblFile.Size = New-Object System.Drawing.Size(120, 20)
$tabCapture.Controls.Add($lblFile)

$script:CaptureName = New-Object System.Windows.Forms.TextBox
$script:CaptureName.Location = New-Object System.Drawing.Point(140, 212)
$script:CaptureName.Size = New-Object System.Drawing.Size(432, 24)
$script:CaptureName.Text = 'Capture.ffu'
$tabCapture.Controls.Add($script:CaptureName)

$lblImgName = New-Object System.Windows.Forms.Label
$lblImgName.Text = 'Image name:'
$lblImgName.Location = New-Object System.Drawing.Point(12, 250)
$lblImgName.Size = New-Object System.Drawing.Size(120, 20)
$tabCapture.Controls.Add($lblImgName)

$script:CaptureLabel = New-Object System.Windows.Forms.TextBox
$script:CaptureLabel.Location = New-Object System.Drawing.Point(140, 247)
$script:CaptureLabel.Size = New-Object System.Drawing.Size(432, 24)
$script:CaptureLabel.Text = 'CAPTURE'
$tabCapture.Controls.Add($script:CaptureLabel)

$script:CaptureButton = New-Object System.Windows.Forms.Button
$script:CaptureButton.Text = 'Capture disk to FFU'
$script:CaptureButton.Location = New-Object System.Drawing.Point(730, 197)
$script:CaptureButton.Size = New-Object System.Drawing.Size(160, 66)
$script:CaptureButton.FlatStyle = 'Flat'
$script:CaptureButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$tabCapture.Controls.Add($script:CaptureButton)

# ---------------- USB mount tab ------------------------------------
$lblVolumes = New-Object System.Windows.Forms.Label
$lblVolumes.Text = 'Volumes:'
$lblVolumes.Location = New-Object System.Drawing.Point(12, 12)
$lblVolumes.Size = New-Object System.Drawing.Size(300, 20)
$tabUsb.Controls.Add($lblVolumes)

$script:VolumeList = New-Object System.Windows.Forms.ListView
$script:VolumeList.Location = New-Object System.Drawing.Point(12, 34)
$script:VolumeList.Size = New-Object System.Drawing.Size(690, 230)
$script:VolumeList.View = 'Details'
$script:VolumeList.FullRowSelect = $true
$script:VolumeList.MultiSelect = $false
$script:VolumeList.GridLines = $true
$script:VolumeList.HideSelection = $false
[void]$script:VolumeList.Columns.Add('Vol', 45)
[void]$script:VolumeList.Columns.Add('Ltr', 40)
[void]$script:VolumeList.Columns.Add('Label', 160)
[void]$script:VolumeList.Columns.Add('Fs', 70)
[void]$script:VolumeList.Columns.Add('Type', 100)
[void]$script:VolumeList.Columns.Add('Size', 90)
[void]$script:VolumeList.Columns.Add('Status', 90)
[void]$script:VolumeList.Columns.Add('Info', 80)
$tabUsb.Controls.Add($script:VolumeList)

$script:RefreshVolumesButton = New-Object System.Windows.Forms.Button
$script:RefreshVolumesButton.Text = 'Rescan volumes'
$script:RefreshVolumesButton.Location = New-Object System.Drawing.Point(730, 34)
$script:RefreshVolumesButton.Size = New-Object System.Drawing.Size(160, 30)
$tabUsb.Controls.Add($script:RefreshVolumesButton)

$lblLetter = New-Object System.Windows.Forms.Label
$lblLetter.Text = 'Assign letter:'
$lblLetter.Location = New-Object System.Drawing.Point(730, 80)
$lblLetter.Size = New-Object System.Drawing.Size(100, 20)
$tabUsb.Controls.Add($lblLetter)

$script:LetterCombo = New-Object System.Windows.Forms.ComboBox
$script:LetterCombo.Location = New-Object System.Drawing.Point(730, 102)
$script:LetterCombo.Size = New-Object System.Drawing.Size(80, 24)
$script:LetterCombo.DropDownStyle = 'DropDownList'
$tabUsb.Controls.Add($script:LetterCombo)

$script:MountButton = New-Object System.Windows.Forms.Button
$script:MountButton.Text = 'Mount volume'
$script:MountButton.Location = New-Object System.Drawing.Point(730, 140)
$script:MountButton.Size = New-Object System.Drawing.Size(160, 34)
$script:MountButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$tabUsb.Controls.Add($script:MountButton)

# --- Progress and log ----------------------------------------------
$script:Progress = New-Object System.Windows.Forms.ProgressBar
$script:Progress.Location = New-Object System.Drawing.Point(12, 478)
$script:Progress.Size = New-Object System.Drawing.Size(790, 22)
$script:Progress.Anchor = 'Top,Left,Right'
$script:Progress.Style = 'Continuous'
$script:Progress.Minimum = 0
$script:Progress.Maximum = 100
$script:Form.Controls.Add($script:Progress)

$script:StopButton = New-Object System.Windows.Forms.Button
$script:StopButton.Text = 'Stop'
$script:StopButton.Location = New-Object System.Drawing.Point(812, 476)
$script:StopButton.Size = New-Object System.Drawing.Size(116, 26)
$script:StopButton.Anchor = 'Top,Right'
$script:StopButton.Enabled = $false
$script:Form.Controls.Add($script:StopButton)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Location = New-Object System.Drawing.Point(12, 508)
$script:LogBox.Size = New-Object System.Drawing.Size(916, 172)
$script:LogBox.Anchor = 'Top,Bottom,Left,Right'
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$script:LogBox.ForeColor = [System.Drawing.Color]::Gainsboro
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$script:Form.Controls.Add($script:LogBox)

$script:StatusStrip = New-Object System.Windows.Forms.StatusStrip
$script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$script:StatusLabel.Text = 'Starting...'
[void]$script:StatusStrip.Items.Add($script:StatusLabel)
$script:Form.Controls.Add($script:StatusStrip)

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 400
$script:Timer.Add_Tick({ Update-FromProcess })

# ------------------------------------------------------------------
# Actions
# ------------------------------------------------------------------

function Refresh-Disks {
    Set-Status 'Scanning disks...'
    $script:DiskList.Items.Clear()
    $script:CaptureDiskList.Items.Clear()
    try {
        $disks = @(Get-DiskList)
    } catch {
        Write-Log ('Disk scan failed: {0}' -f $_.Exception.Message) 'ERROR'
        Set-Status 'Disk scan failed'
        return
    }
    foreach ($d in $disks) {
        foreach ($lv in @($script:DiskList, $script:CaptureDiskList)) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$d.Number)
            [void]$item.SubItems.Add($d.Size)
            [void]$item.SubItems.Add($d.Model)
            [void]$item.SubItems.Add($d.Bus)
            [void]$item.SubItems.Add($d.Style)
            $item.Tag = $d.Number
            [void]$lv.Items.Add($item)
        }
    }
    Write-Log ('Found {0} disk(s)' -f $disks.Count)
    Set-Status 'Ready'
}

function Refresh-Volumes {
    Set-Status 'Scanning volumes...'
    $script:VolumeList.Items.Clear()
    try {
        $vols = @(Get-VolumeList)
    } catch {
        Write-Log ('Volume scan failed: {0}' -f $_.Exception.Message) 'ERROR'
        Set-Status 'Volume scan failed'
        return
    }
    foreach ($v in $vols) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$v.Number)
        [void]$item.SubItems.Add($v.Letter)
        [void]$item.SubItems.Add($v.Label)
        [void]$item.SubItems.Add($v.Fs)
        [void]$item.SubItems.Add($v.Type)
        [void]$item.SubItems.Add($v.Size)
        [void]$item.SubItems.Add($v.Status)
        [void]$item.SubItems.Add($v.Info)
        $item.Tag = $v.Number
        [void]$script:VolumeList.Items.Add($item)
    }

    $script:LetterCombo.Items.Clear()
    foreach ($l in (Get-FreeDriveLetters)) { [void]$script:LetterCombo.Items.Add($l) }
    if ($script:LetterCombo.Items.Count -gt 0) { $script:LetterCombo.SelectedIndex = 0 }

    Write-Log ('Found {0} volume(s)' -f $vols.Count)
    Set-Status 'Ready'
}

function Refresh-Images {
    Set-Status 'Scanning for FFU images...'
    $script:ImageList.Items.Clear()
    $found = 0
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        foreach ($sub in @('Images', 'FFU', '')) {
            $path = if ($sub) { Join-Path $drive.Name $sub } else { $drive.Name }
            if (-not (Test-Path -LiteralPath $path)) { continue }
            try {
                $files = @(Get-ChildItem -LiteralPath $path -Filter '*.ffu' -File -ErrorAction SilentlyContinue)
            } catch {
                $files = @()
            }
            foreach ($f in $files) {
                $item = New-Object System.Windows.Forms.ListViewItem($f.Name)
                [void]$item.SubItems.Add((Format-Size $f.Length))
                [void]$item.SubItems.Add($f.DirectoryName)
                $item.Tag = $f.FullName
                [void]$script:ImageList.Items.Add($item)
                $found++
            }
        }
    }
    Write-Log ('Found {0} FFU image(s)' -f $found)
    Set-Status 'Ready'
}

function Get-SelectedDiskNumber {
    param($ListView)
    if ($ListView.SelectedItems.Count -eq 0) { return $null }
    return [int]$ListView.SelectedItems[0].Tag
}

$script:RefreshDisksButton.Add_Click({ Refresh-Disks })
$script:RefreshCaptureDisksButton.Add_Click({ Refresh-Disks })
$script:RefreshVolumesButton.Add_Click({ Refresh-Volumes })
$script:RefreshImagesButton.Add_Click({ Refresh-Images })

$browseImage.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'FFU images (*.ffu)|*.ffu|All files (*.*)|*.*'
        $dlg.Title = 'Select an FFU image'
        if ($dlg.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $f = Get-Item -LiteralPath $dlg.FileName
            $item = New-Object System.Windows.Forms.ListViewItem($f.Name)
            [void]$item.SubItems.Add((Format-Size $f.Length))
            [void]$item.SubItems.Add($f.DirectoryName)
            $item.Tag = $f.FullName
            [void]$script:ImageList.Items.Add($item)
            $item.Selected = $true
            $script:ImageList.Focus()
        }
        $dlg.Dispose()
    })

$browseFolder.Add_Click({
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'FFU images (*.ffu)|*.ffu'
        $dlg.Title = 'Choose where to save the FFU'
        $dlg.FileName = $script:CaptureName.Text
        if ($dlg.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:CaptureFolder.Text = Split-Path -Parent $dlg.FileName
            $script:CaptureName.Text = Split-Path -Leaf $dlg.FileName
        }
        $dlg.Dispose()
    })

$script:MountButton.Add_Click({
        $vol = Get-SelectedDiskNumber $script:VolumeList
        if ($null -eq $vol) {
            Show-Warn 'Select a volume first.'
            return
        }
        if ($script:LetterCombo.SelectedItem -eq $null) {
            Show-Warn 'No free drive letter is available.'
            return
        }
        $letter = [string]$script:LetterCombo.SelectedItem
        Set-Status ('Mounting volume {0} as {1}:' -f $vol, $letter)
        $out = Invoke-Diskpart @("select volume $vol", "assign letter=$letter")
        Write-Log $out
        # diskpart often exits 0 even when a command failed, so the
        # mounted path is the real test.
        if ($script:LastDiskpartExit -eq 0 -and (Test-Path -LiteralPath ('{0}:\' -f $letter))) {
            Write-Log ('Volume {0} mounted as {1}:' -f $vol, $letter) 'OK'
            Show-Info ('Volume {0} is now mounted as {1}:' -f $vol, $letter)
        } else {
            Write-Log ('Mount of volume {0} failed' -f $vol) 'ERROR'
            Show-Warn 'Mount failed. See the log for the diskpart output.'
        }
        Refresh-Volumes
        Refresh-Images
    })

$script:DeployButton.Add_Click({
        $disk = Get-SelectedDiskNumber $script:DiskList
        if ($null -eq $disk) {
            Show-Warn 'Select a target disk first.'
            return
        }
        if ($script:ImageList.SelectedItems.Count -eq 0) {
            Show-Warn 'Select an FFU image first.'
            return
        }
        $image = [string]$script:ImageList.SelectedItems[0].Tag
        if (-not (Test-Path -LiteralPath $image)) {
            Show-Warn ('Image not found:{0}{1}' -f [Environment]::NewLine, $image)
            return
        }

        $row = $script:DiskList.SelectedItems[0]
        $detail = ('Disk {0}   {1}   {2}{3}{3}Image: {4}' -f `
                $row.SubItems[0].Text, $row.SubItems[1].Text, $row.SubItems[2].Text,
            [Environment]::NewLine, (Split-Path -Leaf $image))

        if (-not (Confirm-Destructive -Message ('Everything on disk {0} will be erased.' -f $disk) -Detail $detail)) {
            Write-Log 'Deployment cancelled by user.'
            return
        }

        Start-Dism -Kind 'Deployment' -Target ('disk {0}' -f $disk) -Arguments @(
            '/Apply-FFU'
            ('/ImageFile:{0}' -f $image)
            ('/ApplyDrive:\\.\PhysicalDrive{0}' -f $disk)
        )
    })

$script:CaptureButton.Add_Click({
        $disk = Get-SelectedDiskNumber $script:CaptureDiskList
        if ($null -eq $disk) {
            Show-Warn 'Select a source disk first.'
            return
        }
        $folder = $script:CaptureFolder.Text.Trim()
        $name = $script:CaptureName.Text.Trim()
        if (-not $folder) {
            Show-Warn 'Choose a destination folder.'
            return
        }
        if (-not (Test-Path -LiteralPath $folder)) {
            Show-Warn ('Destination folder not found:{0}{1}' -f [Environment]::NewLine, $folder)
            return
        }
        if (-not $name) {
            Show-Warn 'Enter a file name.'
            return
        }
        if ($name -notmatch '\.ffu$') { $name = $name + '.ffu' }
        $target = Join-Path $folder $name

        if (Test-Path -LiteralPath $target) {
            $r = [System.Windows.Forms.MessageBox]::Show($script:Form,
                ('{0} already exists. Overwrite it?' -f $target), 'Overwrite?',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }

        $label = $script:CaptureLabel.Text.Trim()
        if (-not $label) { $label = 'CAPTURE' }

        Start-Dism -Kind 'Capture' -Target $target -Arguments @(
            '/Capture-FFU'
            ('/ImageFile:{0}' -f $target)
            ('/CaptureDrive:\\.\PhysicalDrive{0}' -f $disk)
            ('/Name:{0}' -f $label)
        )
    })

$script:StopButton.Add_Click({
        if ($script:Proc -and -not $script:Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show($script:Form,
                'Stop the running capture?', 'Stop',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
                try {
                    $script:Proc.Kill()
                    Write-Log 'Capture stopped by user.' 'WARN'
                } catch {
                    Write-Log ('Could not stop dism: {0}' -f $_.Exception.Message) 'ERROR'
                }
            }
        }
    })

$script:Form.Add_FormClosing({
        param($sender, $e)
        if ($script:Proc -and -not $script:Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show($script:Form,
                'An operation is still running. Closing now may leave the disk in an unusable state. Close anyway?',
                'Operation in progress',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
                $e.Cancel = $true
                return
            }
        }
        $script:Timer.Stop()
    })

$script:Form.Add_Shown({
        Write-Log ('FFU GUI started. Session log: {0}' -f $script:SessionLog)
        Update-HardwareInfo
        Refresh-Disks
        Refresh-Volumes
        Refresh-Images
        Set-Status 'Ready'
    })

[void]$script:Form.ShowDialog()
$script:Form.Dispose()
