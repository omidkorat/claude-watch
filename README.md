# Claude Watch

Claude Watch is a lightweight, interactive macOS Terminal monitor for Claude processes and VPN connectivity.

## Features

- Refreshes every two seconds without filling Terminal scrollback.
- Shows the number of running processes whose command contains `claude`.
- Detects macOS-managed VPNs and active tunnel interfaces.
- Automatically stops every matching Claude process when no VPN is detected.
- Lets you manually stop all matching processes by pressing `k`.
- Exits cleanly with `x`, `q`, or `Control-C`.

> [!WARNING]
> Claude Watch intentionally terminates processes automatically whenever its VPN checks report no connection. Because matching is case-insensitive and command-line based, it may also stop other processes whose command contains `claude`.

## Requirements

- macOS
- The Bash version included with macOS
- A standard Terminal that supports ANSI escape sequences

## Install

```bash
git clone https://github.com/omidkorat/claude-watch.git
cd claude-watch
chmod +x claude-watch.sh
```

## Run

```bash
./claude-watch.sh
```

While it is running:

- Press `k` to stop every detected Claude process.
- Press `x` or `q` to exit.

## Status colors

- Green: VPN connected, or no Claude processes detected.
- Yellow: Claude is running while a VPN is connected.
- Red: VPN disconnected, auto-kill armed, or an automatic stop was triggered.

## VPN detection

Claude Watch checks, in order:

1. Connected VPN services reported by `scutil --nc list`.
2. Active `utun` tunnel interfaces reported by `scutil --nwi`.
3. Default routes using `utun`, `ppp`, or `ipsec` interfaces.

Some Apple services and third-party networking tools may also use tunnel interfaces. Review the script's behavior for your setup before relying on it as a security control.

## License

[MIT](LICENSE)
