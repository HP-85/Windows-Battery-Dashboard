<#
.SYNOPSIS
    Battery Dashboard - live battery stats, GUI mode by default, console mode optional.

.DESCRIPTION
    Polls Win32_Battery + root\WMI battery classes on an interval and renders either:
      - GUI mode (default): WinForms window with progress bar, readouts, and a scrolling history log.
      - Console mode (-Console switch): auto-refreshing text dashboard with a charge bar and history table.
    No admin rights required. Pure WMI, no Perfmon dependency.

.PARAMETER IntervalSeconds
    Refresh interval in seconds. Default: 5.

.PARAMETER Console
    Launch the console text dashboard instead of the default WinForms GUI dashboard.

.PARAMETER Log
    Console mode only. Logs each sample to a CSV file next to the script, named
    BatteryLog_<ComputerName>_<yyyy-MM-dd>.csv. Ignored (with a warning) in GUI mode.

.EXAMPLE
    .\Battery-Dashboard.ps1
    .\Battery-Dashboard.ps1 -IntervalSeconds 2
    .\Battery-Dashboard.ps1 -Console
    .\Battery-Dashboard.ps1 -Console -IntervalSeconds 2
    .\Battery-Dashboard.ps1 -Console -Log

.NOTES
    Author : Craig Cooley
    Date   : July 2026
    Built with Kiro-CLI
#>

[CmdletBinding()]
param(
    [int]$IntervalSeconds = 5,
    [switch]$Console,
    [switch]$Log,
    [switch]$Relaunched
)

if ($Log -and -not $Console) {
    Write-Warning "-Log is only supported in -Console mode; ignoring it for the GUI dashboard."
}

# GUI mode: relaunch self hidden (no visible console/terminal window), then exit this instance.
# Console mode intentionally skips this so its window stays visible.
if (-not $Console -and -not $Relaunched) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$scriptPath`"", '-Relaunched', '-IntervalSeconds', $IntervalSeconds)
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden
    exit
}

# ---------- Shared data layer ----------

function Convert-ChemistryCode {
    param([int]$Code)
    if (-not $Code) { return $null }
    $bytes = [System.BitConverter]::GetBytes($Code) | Where-Object { $_ -ne 0 }
    $raw = [System.Text.Encoding]::ASCII.GetString($bytes).Trim()
    switch ($raw) {
        'LION' { return 'Lithium-ion' }
        'LIO'  { return 'Lithium-ion' }
        'LIP'  { return 'Lithium Polymer' }
        'NICD' { return 'Nickel Cadmium' }
        'NIMH' { return 'Nickel Metal Hydride' }
        'PBAC' { return 'Lead Acid' }
        default { return $raw }
    }
}

function Get-SystemInfo {
    $cs  = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

    [PSCustomObject]@{
        Model = if ($cs -and $cs.Model) { $cs.Model.Trim() } else { "Unknown model" }
        CPU   = if ($cpu -and $cpu.Name) { $cpu.Name.Trim() } else { "Unknown CPU" }
    }
}

function Get-BatterySnapshot {
    $win32  = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    $static = Get-CimInstance -Namespace root\WMI -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1
    $full   = Get-CimInstance -Namespace root\WMI -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1
    $status = Get-CimInstance -Namespace root\WMI -ClassName BatteryStatus -ErrorAction SilentlyContinue | Select-Object -First 1

    $designCapacity = $static.DesignedCapacity
    $fullCapacity   = $full.FullChargedCapacity

    $wearLevelPct = if ($designCapacity -and $fullCapacity) {
        [math]::Round((1 - ($fullCapacity / $designCapacity)) * 100, 1)
    } else { $null }

    $chargeLevelPct = if ($status -and $fullCapacity -and $fullCapacity -gt 0) {
        [math]::Round(($status.RemainingCapacity / $fullCapacity) * 100, 1)
    } elseif ($win32) {
        $win32.EstimatedChargeRemaining
    } else { $null }

    $chargeRateW = if ($status) {
        if ($status.Charging)        { [math]::Round($status.ChargeRate / 1000, 1) }
        elseif ($status.Discharging) { [math]::Round(-1 * $status.DischargeRate / 1000, 1) }
        else { 0 }
    } else { $null }

    [PSCustomObject]@{
        Timestamp              = Get-Date
        DeviceName              = if ($static) { $static.DeviceName.Trim() } else { $win32.Name }
        Chemistry               = Convert-ChemistryCode -Code $static.Chemistry
        DesignCapacity_mWh      = $designCapacity
        FullChargeCapacity_mWh  = $fullCapacity
        WearLevel_Pct           = $wearLevelPct
        RemainingCapacity_mWh   = $status.RemainingCapacity
        ChargeLevel_Pct         = $chargeLevelPct
        Voltage_V               = if ($status) { [math]::Round($status.Voltage / 1000, 1) } else { $null }
        ChargeRate_W            = $chargeRateW
        OnACPower               = $status.PowerOnline
        Charging                = $status.Charging
        Discharging             = $status.Discharging
    }
}

# ---------- Console dashboard ----------

function Start-ConsoleDashboard {
    param([int]$IntervalSeconds, [switch]$Log)

    function Format-Bar {
        param([double]$Percent, [int]$Width = 30)
        $filled = [math]::Round(($Percent / 100) * $Width)
        if ($filled -lt 0) { $filled = 0 }
        if ($filled -gt $Width) { $filled = $Width }
        $bar = ('#' * $filled) + ('-' * ($Width - $filled))
        return "[$bar] $Percent%"
    }

    $history = New-Object System.Collections.Generic.List[object]
    $maxHistory = 10

    $logPath = $null
    if ($Log) {
        $logDir = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
        $logPath = Join-Path $logDir "BatteryLog_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyy-MM-dd').csv"
    }

    $sysInfo = Get-SystemInfo

    Write-Host "Battery Dashboard - refreshing every $IntervalSeconds sec. Press Ctrl+C to stop." -ForegroundColor Cyan
    if ($logPath) {
        Write-Host "Logging to: $logPath" -ForegroundColor Cyan
    }
    Start-Sleep -Milliseconds 500

    while ($true) {
        $snap = Get-BatterySnapshot

        if (-not $snap.DeviceName) {
            Clear-Host
            Write-Host "No battery detected on this system." -ForegroundColor Red
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }

        $history.Add($snap)
        if ($history.Count -gt $maxHistory) { $history.RemoveAt(0) }

        if ($logPath) {
            $stateShort = if ($snap.Charging) { "Charging" } elseif ($snap.Discharging) { "Discharging" } else { "Idle" }
            [PSCustomObject]@{
                Timestamp       = $snap.Timestamp.ToString('yyyy-MM-dd HH:mm:ss')
                'Charge(%)'     = "{0:N1}" -f [double]$snap.ChargeLevel_Pct
                'Rate(W)'       = "{0:N1}" -f [double]$snap.ChargeRate_W
                'Voltage(V)'    = "{0:N1}" -f [double]$snap.Voltage_V
                State           = $stateShort
                RemainingCap_Wh = "{0:N1}" -f ($snap.RemainingCapacity_mWh / 1000)
                FullChargeCap_Wh = "{0:N1}" -f ($snap.FullChargeCapacity_mWh / 1000)
                DesignCap_Wh    = "{0:N1}" -f ($snap.DesignCapacity_mWh / 1000)
                WearLevel_Pct   = "{0:N1}" -f [double]$snap.WearLevel_Pct
            } | Export-Csv -Path $logPath -Append -NoTypeInformation
        }

        Clear-Host
        Write-Host "================ BATTERY DASHBOARD ================" -ForegroundColor Cyan
        Write-Host " Model       : $($sysInfo.Model)"
        Write-Host " CPU         : $($sysInfo.CPU)"
        Write-Host " Device      : $($snap.DeviceName)   ($($snap.Chemistry))"
        Write-Host " Last update : $($snap.Timestamp.ToString('HH:mm:ss'))     (refresh: ${IntervalSeconds}s)"
        Write-Host "-----------------------------------------------------"

        $chargeColor = if ($null -eq $snap.ChargeLevel_Pct) { 'Gray' } elseif ($snap.ChargeLevel_Pct -lt 20) { 'Red' } elseif ($snap.ChargeLevel_Pct -lt 50) { 'Yellow' } else { 'Green' }
        Write-Host " Charge Level  : " -NoNewline
        Write-Host (Format-Bar -Percent $snap.ChargeLevel_Pct) -ForegroundColor $chargeColor

        $stateText = if ($snap.Charging) { "Charging" }
                     elseif ($snap.Discharging) { "Discharging" }
                     elseif ($snap.OnACPower) { "On AC (fully charged / idle)" }
                     else { "Unknown" }
        $stateColor = if ($snap.Charging) { 'Green' } elseif ($snap.Discharging) { 'Yellow' } else { 'Gray' }
        Write-Host (" {0,-16}: " -f "State") -NoNewline
        Write-Host $stateText -ForegroundColor $stateColor

        Write-Host (" {0,-16}: {1} V" -f "Battery Voltage", $snap.Voltage_V)
        Write-Host (" {0,-16}: {1} W" -f "Charge Rate", $snap.ChargeRate_W)
        Write-Host (" {0,-16}: {1} Wh" -f "Remaining Cap", [math]::Round($snap.RemainingCapacity_mWh / 1000, 1))
        Write-Host (" {0,-16}: {1} Wh" -f "Full Charge", [math]::Round($snap.FullChargeCapacity_mWh / 1000, 1))
        Write-Host (" {0,-16}: {1} Wh" -f "Design Cap", [math]::Round($snap.DesignCapacity_mWh / 1000, 1))
        Write-Host (" {0,-16}: {1}%" -f "Wear Level", $snap.WearLevel_Pct)
        Write-Host "-----------------------------------------------------"
        Write-Host " Recent history (last $($history.Count) samples):"
        Write-Host (" {0,-8}  {1,10}  {2,9}  {3,11}   {4}" -f "Time", "Charge(%)", "Rate(W)", "Voltage(V)", "State")
        foreach ($h in $history) {
            $stateShort = if ($h.Charging) { "Charging" } elseif ($h.Discharging) { "Discharging" } else { "Idle" }
            $pctStr  = "{0:N1}" -f [double]$h.ChargeLevel_Pct
            $rateStr = "{0:N1}" -f [double]$h.ChargeRate_W
            $voltStr = "{0:N1}" -f [double]$h.Voltage_V
            Write-Host (" {0,-8}  {1,10}  {2,9}  {3,11}   {4}" -f $h.Timestamp.ToString('HH:mm:ss'), $pctStr, $rateStr, $voltStr, $stateShort)
        }
        Write-Host "======================================================"
        Write-Host " Press Ctrl+C to stop." -ForegroundColor DarkGray

        Start-Sleep -Seconds $IntervalSeconds
    }
}

# ---------- GUI dashboard ----------

function Start-GuiDashboard {
    param([int]$IntervalSeconds)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Battery Dashboard"
    $form.Size = New-Object System.Drawing.Size(620, 660)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $sysInfo = Get-SystemInfo

    $lblModel = New-Object System.Windows.Forms.Label
    $lblModel.Location = New-Object System.Drawing.Point(15, 15)
    $lblModel.Size = New-Object System.Drawing.Size(590, 18)
    $lblModel.ForeColor = [System.Drawing.Color]::Silver
    $lblModel.Text = "Model: $($sysInfo.Model)"
    $form.Controls.Add($lblModel)

    $lblCpu = New-Object System.Windows.Forms.Label
    $lblCpu.Location = New-Object System.Drawing.Point(15, 34)
    $lblCpu.Size = New-Object System.Drawing.Size(590, 18)
    $lblCpu.ForeColor = [System.Drawing.Color]::Silver
    $lblCpu.Text = "CPU: $($sysInfo.CPU)"
    $form.Controls.Add($lblCpu)

    $lblDevice = New-Object System.Windows.Forms.Label
    $lblDevice.Location = New-Object System.Drawing.Point(15, 55)
    $lblDevice.Size = New-Object System.Drawing.Size(590, 20)
    $lblDevice.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $lblDevice.Text = "Detecting battery..."
    $form.Controls.Add($lblDevice)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(15, 85)
    $progressBar.Size = New-Object System.Drawing.Size(480, 28)
    $progressBar.Minimum = 0
    $progressBar.Maximum = 100
    $form.Controls.Add($progressBar)

    $lblChargePct = New-Object System.Windows.Forms.Label
    $lblChargePct.Location = New-Object System.Drawing.Point(505, 85)
    $lblChargePct.Size = New-Object System.Drawing.Size(100, 28)
    $lblChargePct.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $lblChargePct.Text = "--%"
    $form.Controls.Add($lblChargePct)

    $lblState = New-Object System.Windows.Forms.Label
    $lblState.Location = New-Object System.Drawing.Point(15, 122)
    $lblState.Size = New-Object System.Drawing.Size(590, 22)
    $lblState.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblState.Text = "State: --"
    $form.Controls.Add($lblState)

    $gridPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $gridPanel.Location = New-Object System.Drawing.Point(15, 152)
    $gridPanel.Size = New-Object System.Drawing.Size(590, 130)
    $gridPanel.ColumnCount = 4
    $gridPanel.RowCount = 3
    $gridPanel.BackColor = [System.Drawing.Color]::FromArgb(38, 38, 38)

    function New-StatLabel([string]$text, [bool]$bold = $false) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $text
        $lbl.AutoSize = $false
        $lbl.Dock = "Fill"
        $lbl.TextAlign = "MiddleLeft"
        $lbl.ForeColor = if ($bold) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::Silver }
        if ($bold) { $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold) }
        return $lbl
    }

    $valVoltage    = New-StatLabel "--" $true
    $valChargeRate = New-StatLabel "--" $true
    $valRemaining  = New-StatLabel "--" $true
    $valFull       = New-StatLabel "--" $true
    $valDesign     = New-StatLabel "--" $true
    $valWear       = New-StatLabel "--" $true

    $gridPanel.Controls.Add((New-StatLabel "Battery Voltage:"), 0, 0)
    $gridPanel.Controls.Add($valVoltage, 1, 0)
    $gridPanel.Controls.Add((New-StatLabel "Charge Rate:"), 2, 0)
    $gridPanel.Controls.Add($valChargeRate, 3, 0)

    $gridPanel.Controls.Add((New-StatLabel "Remaining Cap:"), 0, 1)
    $gridPanel.Controls.Add($valRemaining, 1, 1)
    $gridPanel.Controls.Add((New-StatLabel "Full Charge Cap:"), 2, 1)
    $gridPanel.Controls.Add($valFull, 3, 1)

    $gridPanel.Controls.Add((New-StatLabel "Design Cap:"), 0, 2)
    $gridPanel.Controls.Add($valDesign, 1, 2)
    $gridPanel.Controls.Add((New-StatLabel "Wear Level:"), 2, 2)
    $gridPanel.Controls.Add($valWear, 3, 2)

    for ($i = 0; $i -lt 4; $i++) { $null = $gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle("Percent", 25))) }
    for ($i = 0; $i -lt 3; $i++) { $null = $gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 33))) }

    $form.Controls.Add($gridPanel)

    $historyHeader = New-Object System.Windows.Forms.Label
    $historyHeader.Location = New-Object System.Drawing.Point(15, 295)
    $historyHeader.Size = New-Object System.Drawing.Size(590, 20)
    $historyHeader.Font = New-Object System.Drawing.Font("Consolas", 9.5, [System.Drawing.FontStyle]::Bold)
    $historyHeader.ForeColor = [System.Drawing.Color]::White
    $historyHeader.BackColor = [System.Drawing.Color]::FromArgb(38, 38, 38)
    $historyHeader.Text = " {0,-8}  {1,10}  {2,9}  {3,11}   {4}" -f "Time", "Charge(%)", "Rate(W)", "Voltage(V)", "State"
    $form.Controls.Add($historyHeader)

    $historyBox = New-Object System.Windows.Forms.TextBox
    $historyBox.Location = New-Object System.Drawing.Point(15, 317)
    $historyBox.Size = New-Object System.Drawing.Size(590, 278)
    $historyBox.Multiline = $true
    $historyBox.ScrollBars = "Vertical"
    $historyBox.ReadOnly = $true
    $historyBox.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 18)
    $historyBox.ForeColor = [System.Drawing.Color]::Gainsboro
    $historyBox.Font = New-Object System.Drawing.Font("Consolas", 9.5)
    $historyBox.BorderStyle = "FixedSingle"
    $form.Controls.Add($historyBox)

    $lblFooter = New-Object System.Windows.Forms.Label
    $lblFooter.Location = New-Object System.Drawing.Point(15, 605)
    $lblFooter.Size = New-Object System.Drawing.Size(590, 20)
    $lblFooter.ForeColor = [System.Drawing.Color]::Gray
    $lblFooter.Text = "Refreshing every $IntervalSeconds sec | Source: WMI (Win32_Battery, root\WMI)"
    $form.Controls.Add($lblFooter)

    $maxHistoryLines = 100
    $historyLines = New-Object System.Collections.Generic.List[string]

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $IntervalSeconds * 1000

    $updateDashboard = {
        $snap = Get-BatterySnapshot

        if (-not $snap.DeviceName) {
            $lblDevice.Text = "No battery detected."
            return
        }

        $lblDevice.Text = "$($snap.DeviceName)  ($($snap.Chemistry))"

        $hasChargeLevel = $null -ne $snap.ChargeLevel_Pct
        $pct = if ($hasChargeLevel) { [int]([math]::Round($snap.ChargeLevel_Pct)) } else { 0 }
        $progressBar.Value = [math]::Max(0, [math]::Min(100, $pct))
        $lblChargePct.Text = if ($hasChargeLevel) { "$pct%" } else { "--%" }
        $lblChargePct.ForeColor = if (-not $hasChargeLevel) { [System.Drawing.Color]::Silver }
                                   elseif ($pct -lt 20) { [System.Drawing.Color]::OrangeRed }
                                   elseif ($pct -lt 50) { [System.Drawing.Color]::Gold }
                                   else { [System.Drawing.Color]::LimeGreen }

        $stateText = if ($snap.Charging) { "Charging" }
                     elseif ($snap.Discharging) { "Discharging" }
                     elseif ($snap.OnACPower) { "On AC (idle/full)" }
                     else { "Unknown" }
        $lblState.Text = "State: $stateText"
        $lblState.ForeColor = if ($snap.Charging) { [System.Drawing.Color]::LimeGreen }
                               elseif ($snap.Discharging) { [System.Drawing.Color]::Gold }
                               else { [System.Drawing.Color]::Silver }

        $valVoltage.Text    = "$([math]::Round($snap.Voltage_V, 1).ToString('N1')) V"
        $valChargeRate.Text = "$([math]::Round($snap.ChargeRate_W, 1).ToString('N1')) W"
        $valRemaining.Text  = "$([math]::Round($snap.RemainingCapacity_mWh / 1000, 1).ToString('N1')) Wh"
        $valFull.Text       = "$([math]::Round($snap.FullChargeCapacity_mWh / 1000, 1).ToString('N1')) Wh"
        $valDesign.Text     = "$([math]::Round($snap.DesignCapacity_mWh / 1000, 1).ToString('N1')) Wh"
        $valWear.Text       = "$([math]::Round($snap.WearLevel_Pct, 1).ToString('N1'))%"

        $timeLabel = $snap.Timestamp.ToString("HH:mm:ss")
        $stateShort = if ($snap.Charging) { "Charging" } elseif ($snap.Discharging) { "Discharging" } else { "Idle" }
        $pctStr  = "{0:N1}" -f [double]$pct
        $rateStr = "{0:N1}" -f [double]$snap.ChargeRate_W
        $voltStr = "{0:N1}" -f [double]$snap.Voltage_V
        $line = " {0,-8}  {1,10}  {2,9}  {3,11}   {4}" -f $timeLabel, $pctStr, $rateStr, $voltStr, $stateShort
        $historyLines.Add($line)
        if ($historyLines.Count -gt $maxHistoryLines) { $historyLines.RemoveAt(0) }

        $historyBox.Text = ($historyLines -join "`r`n")
        $historyBox.SelectionStart = $historyBox.Text.Length
        $historyBox.ScrollToCaret()
    }

    $timer.Add_Tick($updateDashboard)

    $form.Add_Shown({
        & $updateDashboard
        $timer.Start()
    })

    $form.Add_FormClosing({
        $timer.Stop()
        $timer.Dispose()
    })

    [System.Windows.Forms.Application]::Run($form)
}

# ---------- Entry point ----------

if ($Console) {
    Start-ConsoleDashboard -IntervalSeconds $IntervalSeconds -Log:$Log
} else {
    Start-GuiDashboard -IntervalSeconds $IntervalSeconds
}
