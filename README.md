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
3. Full-tunnel routes using `utun`, `tun`, `tap`, `ppp`, or `ipsec` interfaces, including OpenVPN's `0/1` plus `128/1` routing pattern used by VyprVPN.

Some Apple services and third-party networking tools may also use tunnel interfaces. Review the script's behavior for your setup before relying on it as a security control.

## VPN detection on Windows

The PowerShell version checks, in order:

1. Connected Windows VPN profiles reported by `Get-VpnConnection`.
2. Active adapters reported by `Get-NetAdapter` whose names identify common VPN technologies or providers.
3. Connected VPN-like adapters reported by `Win32_NetworkAdapter` as a compatibility fallback.

The Windows version includes a non-destructive `-SelfTest` mode. GitHub Actions runs it on Windows PowerShell 5.1 for every pull request and every push to `main`.

## VS Code VPN kill-switch (code-watch)

`code-watch.sh` (macOS) and `code-watch.ps1` (Windows) do the same VPN detection as above, but instead of killing processes they **freeze the entire VS Code process tree** — the app, every helper process, and anything an extension spawned under it (language servers, integrated-terminal shells, CLIs) — with `SIGSTOP`/`NtSuspendProcess` whenever the VPN drops, and wake it back up with `SIGCONT`/`NtResumeProcess` once the VPN reconnects. No windows or unsaved buffers are lost; VS Code is simply unresponsive while paused.

> [!WARNING]
> Pausing the whole process tree also freezes anything running inside VS Code, including integrated terminals and other extensions (e.g. Claude Code CLI sessions) — you won't be able to interact with them until the VPN comes back.

Run standalone for testing:

```bash
./code-watch.sh                       # interactive, like claude-watch.sh
./code-watch.sh --daemon /tmp/status  # headless, writes KEY=VALUE status lines
```

```powershell
powershell -File .\code-watch.ps1                                   # interactive
powershell -File .\code-watch.ps1 -Daemon -StatusFile C:\temp\status # headless
```

In daemon mode, drop `pause`, `resume`, or `stop` into `<status-file>.cmd` to control it externally.

### VS Code extension

`vscode-extension/` wraps these scripts as a VS Code extension, so the kill-switch is armed automatically every time VS Code opens instead of depending on someone remembering to run a script in a terminal.

It launches the appropriate script as a detached background daemon on startup and surfaces status in a dedicated **Code Watch** view in the Activity Bar: VPN state, tunnel interface, public IP (what a leak would actually expose, not just the tunnel's local address), frozen-process count, and last-check time. The Activity Bar icon gets a badge only while VS Code is actually paused, so there's something to notice without opening the panel. An optional status-bar indicator is also available if you keep your status bar visible. Commands: `Code Watch: Start/Stop Monitoring`, `Pause/Resume Now`.

Because the extension host is itself part of the frozen process tree, it can't show a live countdown while paused — see `vscode-extension/README.md` for the details and workaround (watching from a separate terminal outside VS Code).

Build it with:

```bash
cd vscode-extension
npm install
npm run build
```

Then run it from the Extension Development Host (`F5` in VS Code) or package it with `vsce package`.

## License

[MIT](LICENSE)
