#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$NoTimeZone
)

$RefreshSeconds = 2
$RequiredTimeZone = 'Eastern Standard Time'
$HomeTimeZone = 'Iran Standard Time'
$VpnAdapterPattern = '(?i)(vpn|wireguard|wintun|openvpn|tailscale|nordlynx|proton|mullvad|anyconnect|globalprotect|fortinet|tap[-_ ]|tun[-_ ])'

function Test-ClaudeProcess {
    param(
        [Parameter(Mandatory = $true)]
        $Process
    )

    if ([int]$Process.ProcessId -eq $PID) {
        return $false
    }

    $processName = [IO.Path]::GetFileNameWithoutExtension([string]$Process.Name)
    return ($processName -match '(?i)^claude($|[ -])')
}

function Get-ClaudeProcesses {
    try {
        return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            Where-Object { Test-ClaudeProcess $_ })
    }
    catch {
        return @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $PID -and $_.ProcessName -match '(?i)^claude($|[ -])' } |
            ForEach-Object {
                [pscustomobject]@{
                    ProcessId  = $_.Id
                    Name       = $_.ProcessName
                    CommandLine = $null
                }
            })
    }
}

function Get-TargetTimeZone {
    param(
        [AllowNull()][string]$VpnStatus,
        [bool]$IranHold = $false,
        [bool]$ClaudeRunning = $false
    )

    if (-not $VpnStatus) {
        return $HomeTimeZone
    }

    if ($IranHold -and -not $ClaudeRunning) {
        return $HomeTimeZone
    }

    return $RequiredTimeZone
}

function Set-ClaudeWatchTimeZone {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TimeZoneId
    )

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

        if ($isAdministrator) {
            Set-TimeZone -Id $TimeZoneId -ErrorAction Stop
        }
        else {
            $escapedId = $TimeZoneId.Replace("'", "''")
            $command = "Set-TimeZone -Id '$escapedId' -ErrorAction Stop"
            $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $process = Start-Process -FilePath powershell.exe -Verb RunAs -Wait -PassThru `
                -ArgumentList "-NoProfile -EncodedCommand $encodedCommand" -ErrorAction Stop
            if ($process.ExitCode -ne 0) {
                return $false
            }
        }

        return ((Get-TimeZone -ErrorAction Stop).Id -eq $TimeZoneId)
    }
    catch {
        return $false
    }
}

function Request-TimeZoneAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentTimeZone,

        [Parameter(Mandatory = $true)]
        [string]$TargetTimeZone
    )

    try {
        [Console]::CursorVisible = $true
        [Console]::Clear()
        Write-Host 'Time-zone protection found a mismatch.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host "Current time zone:  $CurrentTimeZone"
        Write-Host "Required time zone: $TargetTimeZone"
        Write-Host ''
        Write-Host 'Reading the current time zone does not require administrator access.'
        Write-Host 'Windows requires administrator approval only to change this system-wide setting.'
        Write-Host ''
        Write-Host '[C] Change the time zone (Windows UAC approval required)'
        Write-Host '[S] Skip time-zone protection for this session (no elevation)'
        Write-Host '[X] Exit Claude Watch'
        Write-Host ''
        $choice = Read-Host 'Choice [C/S/X]'
    }
    catch {
        $choice = 'S'
    }
    finally {
        [Console]::Clear()
        [Console]::CursorVisible = $false
    }

    switch ($choice) {
        { $_ -match '(?i)^c$' } { return 'Change' }
        { $_ -match '(?i)^(x|q)$' } { return 'Exit' }
        default { return 'Skip' }
    }
}

function Test-VpnAdapter {
    param(
        [Parameter(Mandatory = $true)]
        $Adapter
    )

    $description = '{0} {1}' -f ([string]$Adapter.Name), ([string]$Adapter.InterfaceDescription)
    return ($description -match $VpnAdapterPattern)
}

function Get-VpnStatus {
    $vpnNames = @()

    if (Get-Command -Name Get-VpnConnection -ErrorAction SilentlyContinue) {
        try {
            $vpnNames += @(Get-VpnConnection -ErrorAction Stop |
                Where-Object { $_.ConnectionStatus -eq 'Connected' } |
                ForEach-Object { $_.Name })
        }
        catch {}

        try {
            $vpnNames += @(Get-VpnConnection -AllUserConnection -ErrorAction Stop |
                Where-Object { $_.ConnectionStatus -eq 'Connected' } |
                ForEach-Object { $_.Name })
        }
        catch {}
    }

    $vpnNames = @($vpnNames | Where-Object { $_ } | Sort-Object -Unique)
    if ($vpnNames.Count -gt 0) {
        return 'Connected: {0}' -f ($vpnNames -join ', ')
    }

    if (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue) {
        try {
            $adapters = @(Get-NetAdapter -ErrorAction Stop |
                Where-Object { $_.Status -eq 'Up' -and (Test-VpnAdapter $_) })
            if ($adapters.Count -gt 0) {
                return 'Connected (active adapter: {0})' -f (($adapters.Name | Sort-Object -Unique) -join ', ')
            }
        }
        catch {}
    }

    try {
        $adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop |
            Where-Object { $_.NetConnectionStatus -eq 2 -and (Test-VpnAdapter $_) })
        if ($adapters.Count -gt 0) {
            return 'Connected (active adapter: {0})' -f (($adapters.Name | Sort-Object -Unique) -join ', ')
        }
    }
    catch {}

    return $null
}

function Stop-ClaudeProcesses {
    foreach ($attempt in 1..2) {
        $processes = @(Get-ClaudeProcesses)
        foreach ($process in $processes) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }

        if ($attempt -eq 1 -and $processes.Count -gt 0) {
            Start-Sleep -Milliseconds 300
        }
    }
}

function Write-StatusLine {
    param(
        [AllowEmptyString()]
        [string]$Text,

        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    $width = [Math]::Max(20, [Console]::WindowWidth - 1)
    if ($Text.Length -gt $width) {
        $Text = $Text.Substring(0, $width)
    }

    Write-Host $Text.PadRight($width) -ForegroundColor $Color
}

function Show-Status {
    param(
        [object[]]$ClaudeProcesses,
        [string]$VpnStatus,
        [bool]$AutoKilled,
        [string]$AutoKillReason,
        [string]$CurrentTimeZone,
        [string]$TargetTimeZone,
        [bool]$TimeZoneSynced,
        [bool]$TimeZoneChangeFailed,
        [string]$TimeZoneChangedTo,
        [bool]$TimeZoneEnforced,
        [bool]$IranHold
    )

    [Console]::SetCursorPosition(0, 0)
    Write-StatusLine 'Claude Watch - Windows' Cyan
    Write-StatusLine ('Updated: {0:yyyy-MM-dd HH:mm:ss}  |  Refresh: {1}s' -f (Get-Date), $RefreshSeconds)
    Write-StatusLine ''

    if ($ClaudeProcesses.Count -eq 0) {
        Write-StatusLine 'No Claude processes are running.' Green
    }
    elseif ($VpnStatus -and ((-not $TimeZoneEnforced) -or $CurrentTimeZone -eq $RequiredTimeZone)) {
        Write-StatusLine ('CLAUDE IS RUNNING: {0} process(es)' -f $ClaudeProcesses.Count) Yellow
    }
    else {
        Write-StatusLine ('CLAUDE IS RUNNING: {0} process(es)' -f $ClaudeProcesses.Count) Red
    }

    if ($AutoKilled) {
        Write-StatusLine ('Claude was automatically stopped because {0}.' -f $AutoKillReason) Red
    }
    else {
        Write-StatusLine ''
    }

    Write-StatusLine ''
    if ($VpnStatus) {
        Write-StatusLine ('VPN: {0}' -f $VpnStatus) Green
    }
    else {
        Write-StatusLine 'VPN: Not connected - Claude auto-kill is armed' Red
    }

    Write-StatusLine ''
    if (-not $TimeZoneEnforced) {
        Write-StatusLine ('TIME ZONE: {0} - protection skipped for this session' -f $CurrentTimeZone) Yellow
    }
    elseif ($TimeZoneSynced) {
        Write-StatusLine ('TIME ZONE: {0}' -f $CurrentTimeZone) Green
    }
    else {
        Write-StatusLine ('TIME ZONE: {0} - expected {1}' -f $CurrentTimeZone, $TargetTimeZone) Red
    }

    if ($VpnStatus -and $TimeZoneEnforced -and $IranHold -and $TimeZoneSynced -and $ClaudeProcesses.Count -eq 0) {
        Write-StatusLine 'STANDBY: Iran time is restored. Press [T] to prepare New York before opening Claude.' Yellow
    }
    elseif ($VpnStatus -and -not $TimeZoneEnforced) {
        Write-StatusLine 'READY: VPN confirmed. Time-zone protection is disabled. You can open Claude.' Green
    }
    elseif ($VpnStatus -and $CurrentTimeZone -eq $RequiredTimeZone) {
        if ($TimeZoneChangedTo -eq $RequiredTimeZone) {
            Write-StatusLine 'READY: Time zone changed to New York. You can open Claude now.' Green
        }
        else {
            Write-StatusLine 'READY: VPN and New York time zone confirmed. You can open Claude.' Green
        }
    }
    elseif (-not $VpnStatus -and -not $TimeZoneEnforced) {
        Write-StatusLine 'SAFE: VPN is disconnected. Claude remains blocked.' Red
    }
    elseif (-not $VpnStatus -and $TimeZoneSynced) {
        Write-StatusLine 'SAFE: Time zone is Tehran. Claude remains blocked until VPN connects.' Red
    }
    elseif ($TimeZoneChangeFailed) {
        Write-StatusLine 'Time zone change failed. Claude remains blocked; press [T] to retry.' Red
    }
    else {
        Write-StatusLine ''
    }

    Write-StatusLine ''
    if ($ClaudeProcesses.Count -eq 0) {
        Write-StatusLine 'Options: [K] Kill   [T] Prepare New York   [I] Restore Iran   [X] Exit'
    }
    else {
        Write-StatusLine 'Options: [K] Kill   [T] Prepare New York   [X] Exit'
    }
    Write-StatusLine 'Monitor keeps refreshing automatically.'
}

function Invoke-SelfTest {
    $claudeSample = [pscustomobject]@{
        ProcessId  = 10001
        Name       = 'Claude.exe'
        CommandLine = 'C:\Program Files\Claude\Claude.exe'
    }
    $commandSample = [pscustomobject]@{
        ProcessId  = 10002
        Name       = 'node.exe'
        CommandLine = 'node.exe C:\tools\claude-helper.js'
    }
    $helperSample = [pscustomobject]@{
        ProcessId  = 10004
        Name       = 'Claude Helper.exe'
        CommandLine = 'C:\Program Files\Claude\Claude Helper.exe'
    }
    $otherSample = [pscustomobject]@{
        ProcessId  = 10003
        Name       = 'notepad.exe'
        CommandLine = 'notepad.exe'
    }
    $vpnSample = [pscustomobject]@{
        Name                 = 'WireGuard Tunnel'
        InterfaceDescription = 'WireGuard Tunnel Adapter'
    }
    $ethernetSample = [pscustomobject]@{
        Name                 = 'Ethernet'
        InterfaceDescription = 'Intel Ethernet Controller'
    }

    if (-not (Test-ClaudeProcess $claudeSample)) { throw 'Claude name detection failed.' }
    if (Test-ClaudeProcess $commandSample) { throw 'Command-line false-positive rejection failed.' }
    if (-not (Test-ClaudeProcess $helperSample)) { throw 'Claude helper detection failed.' }
    if (Test-ClaudeProcess $otherSample) { throw 'Unrelated process detection failed.' }
    if (-not (Test-VpnAdapter $vpnSample)) { throw 'VPN adapter detection failed.' }
    if (Test-VpnAdapter $ethernetSample) { throw 'Unrelated adapter detection failed.' }
    if ((Get-TargetTimeZone 'Connected: Test VPN' $false $false) -ne $RequiredTimeZone) { throw 'VPN time-zone target failed.' }
    if ((Get-TargetTimeZone 'Connected: Test VPN' $true $false) -ne $HomeTimeZone) { throw 'Iran hold target failed.' }
    if ((Get-TargetTimeZone 'Connected: Test VPN' $true $true) -ne $RequiredTimeZone) { throw 'Claude release of Iran hold failed.' }
    if ((Get-TargetTimeZone $null $false $false) -ne $HomeTimeZone) { throw 'Disconnected time-zone target failed.' }
    if (-not (Get-TimeZone -ListAvailable | Where-Object { $_.Id -eq $RequiredTimeZone })) { throw 'New York time-zone ID is unavailable.' }
    if (-not (Get-TimeZone -ListAvailable | Where-Object { $_.Id -eq $HomeTimeZone })) { throw 'Tehran time-zone ID is unavailable.' }

    $null = @(Get-ClaudeProcesses)
    $null = Get-VpnStatus
    Write-Host 'Claude Watch Windows self-test passed.' -ForegroundColor Green
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

$originalCursorVisible = [Console]::CursorVisible
$exitRequested = $false
$timeZoneAttemptedFor = $null
$timeZoneChangedTo = $null
$timeZoneChangeFailed = $false
$timeZoneEnforcement = -not $NoTimeZone
$iranHold = $false

try {
    [Console]::Clear()
    [Console]::CursorVisible = $false

    while (-not $exitRequested) {
        $claudeProcesses = @(Get-ClaudeProcesses)
        $vpnStatus = Get-VpnStatus
        $autoKilled = $false
        $autoKillReason = $null
        $currentTimeZone = (Get-TimeZone).Id
        if ($claudeProcesses.Count -gt 0) {
            $iranHold = $false
        }

        $targetTimeZone = Get-TargetTimeZone $vpnStatus $iranHold ($claudeProcesses.Count -gt 0)
        $timeZoneSynced = ($currentTimeZone -eq $targetTimeZone)

        if ($timeZoneSynced) {
            $timeZoneAttemptedFor = $null
            $timeZoneChangeFailed = $false
        }

        if ($claudeProcesses.Count -gt 0 -and -not $vpnStatus) {
            Stop-ClaudeProcesses
            $autoKilled = $true
            $autoKillReason = 'the VPN is disconnected'
            $claudeProcesses = @(Get-ClaudeProcesses)
        }

        if ($timeZoneEnforcement -and -not $timeZoneSynced -and $timeZoneAttemptedFor -ne $targetTimeZone) {
            $timeZoneAttemptedFor = $targetTimeZone
            $timeZoneAction = Request-TimeZoneAction -CurrentTimeZone $currentTimeZone -TargetTimeZone $targetTimeZone
            switch ($timeZoneAction) {
                'Skip' {
                    $timeZoneEnforcement = $false
                    $timeZoneChangeFailed = $false
                }
                'Exit' {
                    $exitRequested = $true
                }
                'Change' {
                    if ($claudeProcesses.Count -gt 0) {
                        Stop-ClaudeProcesses
                        $autoKilled = $true
                        $autoKillReason = "time-zone protection requires $RequiredTimeZone"
                        $claudeProcesses = @(Get-ClaudeProcesses)
                    }

                    if (Set-ClaudeWatchTimeZone $targetTimeZone) {
                        $currentTimeZone = (Get-TimeZone).Id
                        $timeZoneSynced = $true
                        $timeZoneChangedTo = $targetTimeZone
                        $timeZoneChangeFailed = $false
                    }
                    else {
                        $currentTimeZone = (Get-TimeZone).Id
                        $timeZoneChangeFailed = $true
                    }
                }
            }
        }

        if ($exitRequested) {
            continue
        }

        if ($claudeProcesses.Count -gt 0 -and $vpnStatus -and $timeZoneEnforcement -and
            $currentTimeZone -ne $RequiredTimeZone) {
            Stop-ClaudeProcesses
            $autoKilled = $true
            $autoKillReason = "the time zone is $currentTimeZone, not $RequiredTimeZone"
            $claudeProcesses = @(Get-ClaudeProcesses)
        }

        Show-Status -ClaudeProcesses $claudeProcesses -VpnStatus $vpnStatus -AutoKilled $autoKilled `
            -AutoKillReason $autoKillReason -CurrentTimeZone $currentTimeZone `
            -TargetTimeZone $targetTimeZone -TimeZoneSynced $timeZoneSynced `
            -TimeZoneChangeFailed $timeZoneChangeFailed -TimeZoneChangedTo $timeZoneChangedTo `
            -TimeZoneEnforced $timeZoneEnforcement -IranHold $iranHold

        $deadline = (Get-Date).AddSeconds($RefreshSeconds)
        :waitLoop while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true).Key
                switch ($key) {
                    'K' {
                        Stop-ClaudeProcesses
                        break waitLoop
                    }
                    'T' {
                        $timeZoneEnforcement = $true
                        $iranHold = $false
                        $timeZoneAttemptedFor = $null
                        $timeZoneChangedTo = $null
                        break waitLoop
                    }
                    'I' {
                        if ($claudeProcesses.Count -eq 0) {
                            $timeZoneEnforcement = $true
                            $iranHold = $true
                            $timeZoneAttemptedFor = $null
                            $timeZoneChangedTo = $null
                        }
                        break waitLoop
                    }
                    'X' {
                        $exitRequested = $true
                        break waitLoop
                    }
                    'Q' {
                        $exitRequested = $true
                        break waitLoop
                    }
                }
            }

            Start-Sleep -Milliseconds 100
        }
    }
}
finally {
    [Console]::CursorVisible = $originalCursorVisible
    Write-Host 'Monitor stopped.' -ForegroundColor Cyan
}
