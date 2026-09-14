# Code Watch (VPN Kill-Switch)

Freezes the entire VS Code process tree — the editor, every helper process, and anything an extension spawned under it (language servers, integrated-terminal shells, CLIs) — the instant your VPN disconnects, and resumes automatically once it reconnects. No windows or unsaved buffers are lost; VS Code is simply unresponsive while paused.

Built for Cisco AnyConnect and similar corporate VPN setups where nothing under the editor should be able to reach the network outside the tunnel.

## What you get

- A dedicated **Code Watch** icon in the Activity Bar with a status dashboard: VPN state, tunnel interface, IP address, frozen-process count, and last check time.
- A red badge on that icon whenever VS Code is actually paused — visible at a glance, no click required.
- An optional status-bar indicator (enable via `View: Toggle Status Bar Visibility` if you keep your status bar hidden).
- Commands to start/stop monitoring or pause/resume manually.

## Commands

| Command | What it does |
|---|---|
| `Code Watch: Start Monitoring` | Launches the background watcher daemon. |
| `Code Watch: Stop Monitoring` | Ends the daemon (resumes VS Code first if it was paused). |
| `Code Watch: Pause VS Code Now` | Manually freezes VS Code, without waiting for a VPN drop. |
| `Code Watch: Resume VS Code Now` | Manually resumes a paused VS Code. |

## Settings

- `codeWatch.autoStart` (default `true`) — start the watcher automatically on launch.
- `codeWatch.appProcessName` — override which app/process to watch (for VS Code Insiders, VSCodium, etc.).

## How it works

On activation, the extension spawns a small detached daemon (`code-watch.sh` on macOS, `code-watch.ps1` on Windows — the same scripts from the parent [claude-watch](https://github.com/omidkorat/claude-watch) project) that runs independently of VS Code's own process. It polls VPN connectivity every couple of seconds; when the VPN drops it walks the full VS Code process tree and sends `SIGSTOP` (macOS) / `NtSuspendProcess` (Windows) to every process in it, then `SIGCONT` / `NtResumeProcess` once the VPN is back.

Because the daemon is detached and independent, it keeps working — and keeps watching — even while VS Code itself is frozen.

## Warning

Pausing the whole process tree also freezes anything running inside VS Code, including integrated terminals and other extensions (e.g. an AI coding assistant's CLI session). That's the point: nothing under the editor should be able to touch the network while the VPN is down.
