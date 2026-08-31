#Requires -Version 5.1

# Suspends and resumes the entire VS Code process tree based on VPN
# connectivity on Windows. Unlike claude-watch.ps1 (which kills Claude
# processes), this script freezes VS Code with NtSuspendProcess so no
# code, extension, or integrated-terminal process under it can touch the
# network while the VPN is down, then wakes it back up with
# NtResumeProcess once the VPN returns. No windows or unsaved buffers
# are lost.

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Daemon,
    [string]$StatusFile,
    [string]$AppProcessName = 'Code'
)

$RefreshSeconds = 2
$VpnAdapterPattern = '(?i)(vpn|wireguard|wintun|openvpn|tailscale|nordlynx|proton|mullvad|anyconnect|globalprotect|fortinet|tap[-_ ]|tun[-_ ])'

Add-Type -Namespace CodeWatch -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern uint NtSuspendProcess(System.IntPtr processHandle);
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern uint NtResumeProcess(System.IntPtr processHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr OpenProcess(uint processAccess, bool bInheritHandle, int processId);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(System.IntPtr hObject);
'@ -ErrorAction SilentlyContinue

$ProcessAllAccess = 0x1FFFFF

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

function Get-VpnTunnelInterface {
    # First VPN-matching adapter that actually carries an IPv4 address,
    # independent of which check in Get-VpnStatus flagged it connected.
    if (-not (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) { return $null }

    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and (Test-VpnAdapter $_) })
    }
    catch {
        return $null
    }

    foreach ($adapter in $adapters) {
        try {
            $addr = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
                Select-Object -First 1 -ExpandProperty IPAddress
        }
        catch {
            $addr = $null
        }
        if ($addr) {
            return $adapter.Name
        }
    }

    return $null
}

function Get-PublicIp {
    # The externally-visible IP — what a leak would actually expose —
    # tried against a couple of providers in case one is blocked or down.
    foreach ($url in 'https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com') {
        try {
            $ip = (Invoke-RestMethod -Uri $url -TimeoutSec 3 -ErrorAction Stop).ToString().Trim()
            if ($ip) { return $ip }
        }
        catch {}
    }
    return $null
}

function Get-CodeProcessTree {
    # Every root "Code.exe"-style process plus its full descendant tree,
    # walked from a single process snapshot so nothing spawned by an
    # extension (language servers, integrated-terminal shells, helper
    # CLIs) is left able to reach the network while the tree is frozen.
    param(
        [object[]]$ProcessList
    )

    if (-not $ProcessList) {
        try {
            $ProcessList = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
        }
        catch {
            return @()
        }
    }

    $childrenOf = @{}
    foreach ($p in $ProcessList) {
        $parent = [int]$p.ParentProcessId
        if (-not $childrenOf.ContainsKey($parent)) {
            $childrenOf[$parent] = New-Object System.Collections.Generic.List[int]
        }
        $childrenOf[$parent].Add([int]$p.ProcessId)
    }

    $selfId = $PID
    $roots = @($ProcessList |
        Where-Object { $_.Name -eq "$AppProcessName.exe" -and [int]$_.ProcessId -ne $selfId } |
        ForEach-Object { [int]$_.ProcessId })

    $visited = @{}
    $queue = New-Object System.Collections.Generic.Queue[int]
    foreach ($r in $roots) {
        if (-not $visited.ContainsKey($r)) {
            $visited[$r] = $true
            $queue.Enqueue($r)
        }
    }

    $result = New-Object System.Collections.Generic.List[int]
    while ($queue.Count -gt 0) {
        $currentPid = $queue.Dequeue()
        if ($currentPid -ne $selfId) {
            $result.Add($currentPid)
        }
        if ($childrenOf.ContainsKey($currentPid)) {
            foreach ($c in $childrenOf[$currentPid]) {
                if (-not $visited.ContainsKey($c)) {
                    $visited[$c] = $true
                    $queue.Enqueue($c)
                }
            }
        }
    }

    return @($result)
}

function Suspend-ProcessById {
    param([int]$ProcessId)
    $handle = [CodeWatch.NativeMethods]::OpenProcess($ProcessAllAccess, $false, $ProcessId)
    if ($handle -ne [System.IntPtr]::Zero) {
        [void][CodeWatch.NativeMethods]::NtSuspendProcess($handle)
        [void][CodeWatch.NativeMethods]::CloseHandle($handle)
    }
}

function Resume-ProcessById {
    param([int]$ProcessId)
    $handle = [CodeWatch.NativeMethods]::OpenProcess($ProcessAllAccess, $false, $ProcessId)
    if ($handle -ne [System.IntPtr]::Zero) {
        [void][CodeWatch.NativeMethods]::NtResumeProcess($handle)
        [void][CodeWatch.NativeMethods]::CloseHandle($handle)
    }
}

function Suspend-CodeTree {
    $pids = @(Get-CodeProcessTree)
    foreach ($p in $pids) { Suspend-ProcessById -ProcessId $p }
    return $pids.Count -gt 0
}

function Resume-CodeTree {
    $pids = @(Get-CodeProcessTree)
    foreach ($p in $pids) { Resume-ProcessById -ProcessId $p }
}

function Write-DaemonStatus {
    param(
        [string]$VpnState,
        [string]$Detail,
        [string]$State,
        [int]$ProcessCount,
        [string]$Iface,
        [string]$IpAddress,
        [long]$PausedAt
    )

    if (-not $StatusFile) { return }
    $tmp = "$StatusFile.tmp.$PID"
    @(
        "VPN=$VpnState"
        "DETAIL=$Detail"
        "STATE=$State"
        "PIDS=$ProcessCount"
        "IFACE=$Iface"
        "IP=$IpAddress"
        "PAUSED_AT=$PausedAt"
        "UPDATED=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    ) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $StatusFile -Force
}

function Get-DaemonCommand {
    $cmdFile = "$StatusFile.cmd"
    if (-not $StatusFile -or -not (Test-Path $cmdFile)) { return $null }
    $cmd = (Get-Content -Path $cmdFile -Raw -ErrorAction SilentlyContinue)
    Remove-Item -Path $cmdFile -Force -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Trim() }
    return $null
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
        [int]$ProcessCount,
        [string]$VpnStatus,
        [bool]$Paused,
        [string]$TunnelIface,
        [string]$PublicIp,
        [long]$PausedAt
    )

    [Console]::SetCursorPosition(0, 0)
    Write-StatusLine 'VS Code Watch - Windows' Cyan
    Write-StatusLine ('Updated: {0:yyyy-MM-dd HH:mm:ss}  |  Refresh: {1}s' -f (Get-Date), $RefreshSeconds)
    Write-StatusLine ''

    if ($Paused) {
        $elapsed = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $PausedAt
        Write-StatusLine ('VS CODE IS PAUSED ({0} process(es) frozen, {1}s so far)' -f $ProcessCount, $elapsed) Red
    }
    elseif ($ProcessCount -eq 0) {
        Write-StatusLine 'No VS Code processes detected.' Green
    }
    elseif ($VpnStatus) {
        Write-StatusLine ('VS Code running: {0} process(es)' -f $ProcessCount) Green
    }
    else {
        Write-StatusLine ('VS Code running: {0} process(es)' -f $ProcessCount) Yellow
    }

    Write-StatusLine ''
    if ($VpnStatus) {
        Write-StatusLine ('VPN: {0}' -f $VpnStatus) Green
    }
    else {
        Write-StatusLine 'VPN: Not connected - VS Code auto-pause is armed' Red
    }

    Write-StatusLine ('Tunnel interface: {0}' -f $(if ($TunnelIface) { $TunnelIface } else { 'none' }))
    Write-StatusLine ('Public IP: {0}' -f $(if ($PublicIp) { $PublicIp } else { 'unknown' }))

    Write-StatusLine ''
    Write-StatusLine 'Options: [P] Pause now   [R] Resume now   [X] Exit'
    Write-StatusLine 'Monitor keeps refreshing automatically.'
}

function Invoke-SelfTest {
    $vpnSample = [pscustomobject]@{
        Name                 = 'WireGuard Tunnel'
        InterfaceDescription = 'WireGuard Tunnel Adapter'
    }
    $ciscoSample = [pscustomobject]@{
        Name                 = 'Ethernet 2'
        InterfaceDescription = 'Cisco AnyConnect Secure Mobility Client Virtual Adapter'
    }
    $ethernetSample = [pscustomobject]@{
        Name                 = 'Ethernet'
        InterfaceDescription = 'Intel Ethernet Controller'
    }

    if (-not (Test-VpnAdapter $vpnSample)) { throw 'VPN adapter detection failed.' }
    if (-not (Test-VpnAdapter $ciscoSample)) { throw 'Cisco AnyConnect adapter detection failed.' }
    if (Test-VpnAdapter $ethernetSample) { throw 'Unrelated adapter detection failed.' }

    # Synthetic process table: Code.exe root (1000) with a renderer
    # (1001), an extension host (1002) that spawned a helper CLI (1003),
    # plus an unrelated process (2000) that must never be included.
    $fakeProcesses = @(
        [pscustomobject]@{ ProcessId = 1000; ParentProcessId = 1; Name = 'Code.exe' }
        [pscustomobject]@{ ProcessId = 1001; ParentProcessId = 1000; Name = 'Code.exe' }
        [pscustomobject]@{ ProcessId = 1002; ParentProcessId = 1000; Name = 'Code.exe' }
        [pscustomobject]@{ ProcessId = 1003; ParentProcessId = 1002; Name = 'claude.exe' }
        [pscustomobject]@{ ProcessId = 2000; ParentProcessId = 1; Name = 'notepad.exe' }
    )

    $tree = @(Get-CodeProcessTree -ProcessList $fakeProcesses)
    foreach ($expected in 1000, 1001, 1002, 1003) {
        if ($tree -notcontains $expected) { throw "Process tree walk missed pid $expected." }
    }
    if ($tree -contains 2000) { throw 'Process tree walk included an unrelated process.' }
    if ($tree -contains $PID) { throw 'Process tree walk included its own pid.' }

    $null = Get-VpnStatus
    $null = @(Get-CodeProcessTree)
    $null = Get-VpnTunnelInterface
    # Get-PublicIp is intentionally not exercised here: it depends on
    # outbound network access, which self-test must not require.

    Write-Host 'Code Watch Windows self-test passed.' -ForegroundColor Green
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if ($Daemon) {
    $paused = $false
    $pausedAt = 0
    $publicIpCache = $null
    $publicIpCounter = 0
    $publicIpInterval = 15 # ~30s at the default 2s refresh, so we don't hammer the lookup service
    try {
        while ($true) {
            $command = Get-DaemonCommand
            if ($command -eq 'pause') {
                Suspend-CodeTree | Out-Null
                if (-not $paused) { $pausedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
                $paused = $true
            }
            elseif ($command -eq 'resume') {
                Resume-CodeTree
                $paused = $false
                $pausedAt = 0
            }
            elseif ($command -eq 'stop') {
                break
            }

            $vpnStatus = Get-VpnStatus
            $pids = @(Get-CodeProcessTree)
            $tunnelIface = Get-VpnTunnelInterface

            $publicIpCounter++
            if (-not $publicIpCache -or $publicIpCounter -ge $publicIpInterval) {
                $newIp = Get-PublicIp
                if ($newIp) { $publicIpCache = $newIp }
                $publicIpCounter = 0
            }

            if (-not $vpnStatus -and -not $paused -and $pids.Count -gt 0) {
                Suspend-CodeTree | Out-Null
                $pausedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $paused = $true
            }
            elseif ($vpnStatus -and $paused) {
                Resume-CodeTree
                $paused = $false
                $pausedAt = 0
            }

            Write-DaemonStatus -VpnState $(if ($vpnStatus) { 'connected' } else { 'disconnected' }) `
                -Detail $vpnStatus -State $(if ($paused) { 'paused' } else { 'running' }) -ProcessCount $pids.Count `
                -Iface $(if ($tunnelIface) { $tunnelIface } else { '' }) -IpAddress $(if ($publicIpCache) { $publicIpCache } else { '' }) `
                -PausedAt $pausedAt

            Start-Sleep -Seconds $RefreshSeconds
        }
    }
    finally {
        if ($paused) { Resume-CodeTree }
    }
    exit 0
}

$originalCursorVisible = [Console]::CursorVisible
$exitRequested = $false
$paused = $false
$pausedAt = 0
$publicIpCache = $null
$publicIpCounter = 0
$publicIpInterval = 15

try {
    [Console]::Clear()
    [Console]::CursorVisible = $false

    while (-not $exitRequested) {
        $vpnStatus = Get-VpnStatus
        $pids = @(Get-CodeProcessTree)
        $tunnelIface = Get-VpnTunnelInterface

        $publicIpCounter++
        if (-not $publicIpCache -or $publicIpCounter -ge $publicIpInterval) {
            $newIp = Get-PublicIp
            if ($newIp) { $publicIpCache = $newIp }
            $publicIpCounter = 0
        }

        if (-not $vpnStatus -and -not $paused -and $pids.Count -gt 0) {
            Suspend-CodeTree | Out-Null
            $pausedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $paused = $true
        }
        elseif ($vpnStatus -and $paused) {
            Resume-CodeTree
            $paused = $false
            $pausedAt = 0
        }

        Show-Status -ProcessCount $pids.Count -VpnStatus $vpnStatus -Paused $paused -TunnelIface $tunnelIface -PublicIp $publicIpCache -PausedAt $pausedAt

        $deadline = (Get-Date).AddSeconds($RefreshSeconds)
        :waitLoop while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true).Key
                switch ($key) {
                    'P' {
                        Suspend-CodeTree | Out-Null
                        $pausedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                        $paused = $true
                        break waitLoop
                    }
                    'R' {
                        Resume-CodeTree
                        $paused = $false
                        $pausedAt = 0
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
    if ($paused) {
        Resume-CodeTree
    }
    [Console]::CursorVisible = $originalCursorVisible
    Write-Host 'Monitor stopped.' -ForegroundColor Cyan
}
