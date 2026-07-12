# Claude Watch

Claude Watch is a lightweight, interactive macOS and Windows terminal monitor for Claude processes and VPN connectivity.

## Features

- Refreshes every two seconds without filling Terminal scrollback.
- Shows the number of running processes whose command contains `claude`.
- Detects system-managed VPNs and common third-party VPN adapters.
- Automatically stops every matching Claude process when no VPN is detected.
- Lets you manually stop all matching processes by pressing `k`.
- Exits cleanly with `x`, `q`, or `Control-C`.

> [!WARNING]
> Claude Watch intentionally terminates processes automatically whenever its VPN checks report no connection. Because matching is case-insensitive and command-line based, it may also stop other processes whose command contains `claude`.

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
- Press `x` or `q` to exit.

## Status colors

- Green: VPN connected, or no Claude processes detected.
- Yellow: Claude is running while a VPN is connected.
- Red: VPN disconnected, auto-kill armed, or an automatic stop was triggered.

## VPN detection on macOS

Claude Watch checks, in order:

1. Connected VPN services reported by `scutil --nc list`.
2. Active `utun` tunnel interfaces reported by `scutil --nwi`.
3. Default routes using `utun`, `ppp`, or `ipsec` interfaces.

Some Apple services and third-party networking tools may also use tunnel interfaces. Review the script's behavior for your setup before relying on it as a security control.

## VPN detection on Windows

The PowerShell version checks, in order:

1. Connected Windows VPN profiles reported by `Get-VpnConnection`.
2. Active adapters reported by `Get-NetAdapter` whose names identify common VPN technologies or providers.
3. Connected VPN-like adapters reported by `Win32_NetworkAdapter` as a compatibility fallback.

The Windows version includes a non-destructive `-SelfTest` mode. GitHub Actions runs it on Windows PowerShell 5.1 for every pull request and every push to `main`.

## License

[MIT](LICENSE)
