#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$SelfTest
)

$RefreshSeconds = 2
$VpnAdapterPattern = '(?i)(vpn|wireguard|wintun|openvpn|tailscale|nordlynx|proton|mullvad|anyconnect|globalprotect|fortinet|tap[-_ ]|tun[-_ ])'

function Test-ClaudeProcess {
    param(
        [Parameter(Mandatory = $true)]
        $Process
    )

    if ([int]$Process.ProcessId -eq $PID) {
        return $false
    }

    return (([string]$Process.Name -match '(?i)claude') -or
        ([string]$Process.CommandLine -match '(?i)claude'))
}

function Get-ClaudeProcesses {
    try {
        return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            Where-Object { Test-ClaudeProcess $_ })
    }
    catch {
        return @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $PID -and $_.ProcessName -match '(?i)claude' } |
            ForEach-Object {
                [pscustomobject]@{
                    ProcessId  = $_.Id
                    Name       = $_.ProcessName
                    CommandLine = $null
                }
            })
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
        [bool]$AutoKilled
    )

    [Console]::SetCursorPosition(0, 0)
    Write-StatusLine 'Claude Watch - Windows' Cyan
    Write-StatusLine ('Updated: {0:yyyy-MM-dd HH:mm:ss}  |  Refresh: {1}s' -f (Get-Date), $RefreshSeconds)
    Write-StatusLine ''

    if ($ClaudeProcesses.Count -eq 0) {
        Write-StatusLine 'No Claude processes are running.' Green
    }
    elseif ($VpnStatus) {
        Write-StatusLine ('CLAUDE IS RUNNING: {0} process(es)' -f $ClaudeProcesses.Count) Yellow
    }
    else {
        Write-StatusLine ('CLAUDE IS RUNNING: {0} process(es)' -f $ClaudeProcesses.Count) Red
    }

    if ($AutoKilled) {
        Write-StatusLine 'Claude was automatically stopped because the VPN is disconnected.' Red
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
    Write-StatusLine 'Options: [K] Kill all Claude processes   [X] Exit'
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
    if (-not (Test-ClaudeProcess $commandSample)) { throw 'Claude command-line detection failed.' }
    if (Test-ClaudeProcess $otherSample) { throw 'Unrelated process detection failed.' }
    if (-not (Test-VpnAdapter $vpnSample)) { throw 'VPN adapter detection failed.' }
    if (Test-VpnAdapter $ethernetSample) { throw 'Unrelated adapter detection failed.' }

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

try {
    [Console]::Clear()
    [Console]::CursorVisible = $false

    while (-not $exitRequested) {
        $claudeProcesses = @(Get-ClaudeProcesses)
        $vpnStatus = Get-VpnStatus
        $autoKilled = $false

        if ($claudeProcesses.Count -gt 0 -and -not $vpnStatus) {
            Stop-ClaudeProcesses
            $autoKilled = $true
            $claudeProcesses = @(Get-ClaudeProcesses)
        }

        Show-Status -ClaudeProcesses $claudeProcesses -VpnStatus $vpnStatus -AutoKilled $autoKilled

        $deadline = (Get-Date).AddSeconds($RefreshSeconds)
        :waitLoop while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true).Key
                switch ($key) {
                    'K' {
                        Stop-ClaudeProcesses
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
