# Claude Watch

Claude Watch is a lightweight, interactive macOS and Windows terminal monitor for Claude processes, VPN connectivity, and safe time-zone switching.

## Features

- Refreshes every two seconds without filling Terminal scrollback.
- Shows the number of running Claude processes using process-name matching.
- Detects system-managed VPNs and common third-party VPN adapters.
- Allows Claude only when a VPN is connected and the time zone is New York.
- Automatically switches to New York time while the VPN is connected and Tehran time when it disconnects.
- Automatically stops every matching Claude process when either safety condition is not met.
- Lets you manually stop all matching processes by pressing `k`.
- Exits cleanly with `x`, `q`, or `Control-C`.

> [!WARNING]
> Claude Watch intentionally terminates Claude processes whenever its VPN or time-zone safety checks fail. Changing the system time zone requires macOS administrator authentication or Windows UAC approval.

## macOS

Requirements: macOS, its included Bash version, and a Terminal that supports ANSI escape sequences.

Install and run:

```bash
git clone https://github.com/omidkorat/claude-watch.git
cd claude-watch
chmod +x claude-watch.sh
./claude-watch.sh
```

## Windows

Requirements: Windows 10 or 11 and Windows PowerShell 5.1 or later.

Clone the repository, open PowerShell in its folder, and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\claude-watch.ps1
```

The execution-policy option applies only to that invocation and does not change the system policy.

## Controls

- Press `k` to stop every detected Claude process.
- Press `t` to retry synchronizing the time zone with the VPN state.
- Press `x` or `q` to exit.

## Status colors

- Green: a system condition is correctly synchronized.
- Yellow: Claude is running while both VPN and New York time are confirmed.
- Red: Claude is blocked, a safety condition failed, or an automatic stop was triggered.

## Time-zone safety

Claude Watch keeps the system in one of two explicit states:

| VPN | Required time zone | Claude |
| --- | --- | --- |
| Connected | New York (`America/New_York` on macOS; `Eastern Standard Time` on Windows) | Allowed |
| Disconnected | Tehran (`Asia/Tehran` on macOS; `Iran Standard Time` on Windows) | Blocked |

Claude is stopped before an inconsistent time zone is corrected. If administrator authorization is declined or the change cannot be verified, Claude remains blocked and the monitor offers a manual retry with `t`.

## VPN detection on macOS

Claude Watch checks, in order:

1. Connected VPN services reported by `scutil --nc list`.
2. Active `utun` tunnel interfaces reported by `scutil --nwi`.
3. Full-tunnel routes using `utun`, `tun`, `tap`, `ppp`, or `ipsec` interfaces, including OpenVPN's `0/1` plus `128/1` routing pattern used by VyprVPN.

Some Apple services and third-party networking tools may also use tunnel interfaces. Review the script's behavior for your setup before relying on it as a security control.

## VPN detection on Windows

The PowerShell version checks, in order:

1. Connected Windows VPN profiles reported by `Get-VpnConnection`.
2. Active adapters reported by `Get-NetAdapter` whose names identify common VPN technologies or providers.
3. Connected VPN-like adapters reported by `Win32_NetworkAdapter` as a compatibility fallback.

The Windows version includes a non-destructive `-SelfTest` mode. GitHub Actions runs it on Windows PowerShell 5.1 for every pull request and every push to `main`.

## License

[MIT](LICENSE)
