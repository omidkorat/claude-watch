#!/bin/bash

# Suspend and resume the entire VS Code process tree based on VPN
# connectivity on macOS. Unlike claude-watch.sh (which kills Claude
# processes), this script freezes VS Code with SIGSTOP so no code,
# extension, or integrated-terminal process under it can touch the
# network while the VPN is down, then wakes it back up with SIGCONT
# once the VPN returns. No windows or unsaved buffers are lost.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

REFRESH_SECONDS=2
SELF_PID=$$

# Override to target VS Code Insiders, VSCodium, etc.
APP_BUNDLE_NAME=${CODE_WATCH_APP_NAME:-"Visual Studio Code"}
LAUNCHER_PATTERN="/${APP_BUNDLE_NAME}\.app/Contents/MacOS/Code$"

# The public IP is what actually shows on the wire if something leaks, so
# it matters more here than the tunnel's local address — but it needs a
# real HTTP round trip, so it's only refreshed every PUBLIC_IP_INTERVAL
# cycles (and cached in between) instead of on every loop tick.
PUBLIC_IP_INTERVAL=15
public_ip_cache=""
public_ip_counter=0

DAEMON_MODE=false
STATUS_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --daemon)
            DAEMON_MODE=true
            STATUS_FILE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

paused=false
paused_at=0

write_status() {
    [[ -z "$STATUS_FILE" ]] && return
    local tmp="${STATUS_FILE}.tmp.$$"
    {
        printf 'VPN=%s\n' "$1"
        printf 'DETAIL=%s\n' "$2"
        printf 'STATE=%s\n' "$3"
        printf 'PIDS=%s\n' "$4"
        printf 'IFACE=%s\n' "$5"
        printf 'IP=%s\n' "$6"
        printf 'PAUSED_AT=%s\n' "$7"
        printf 'UPDATED=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "$tmp" && mv "$tmp" "$STATUS_FILE"
}

resume_before_exit() {
    if [[ "$paused" == true ]]; then
        resume_code
    fi
}

cleanup() {
    resume_before_exit
    if [[ "$DAEMON_MODE" == false ]]; then
        printf '\033[?25h\033[?1049l%bMonitor stopped.%b\n' "$CYAN" "$RESET"
        stty echo 2>/dev/null || true
    fi
    rm -f "${STATUS_FILE}.cmd" 2>/dev/null
    exit 0
}

trap cleanup INT TERM HUP

code_pids() {
    # A single ps snapshot plus an in-awk BFS over the pid/ppid table.
    # macOS's `pgrep -P` has been observed to silently drop real children
    # under this app's process tree, which is unacceptable for a script
    # that decides what to freeze — so the tree walk never shells out to
    # pgrep per level.
    ps -eo pid,ppid,comm | awk -v self="$SELF_PID" -v pat="$LAUNCHER_PATTERN" '
        NR == 1 { next }
        {
            pid = $1
            ppid = $2
            comm = $0
            sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", comm)
            ppid_of[pid] = ppid
            comm_of[pid] = comm
            children[ppid] = children[ppid] " " pid
            if (ppid == 1 && pid != self && comm ~ pat) {
                roots[pid] = 1
            }
        }
        END {
            n = 0
            for (r in roots) { queue[n++] = r; visited[r] = 1 }
            for (i = 0; i < n; i++) {
                p = queue[i]
                if (p != self) print p
                split(children[p], kids, " ")
                for (k in kids) {
                    c = kids[k]
                    if (c != "" && !(c in visited)) {
                        visited[c] = 1
                        queue[n++] = c
                    }
                }
            }
        }
    ' | sort -un
}

vpn_status() {
    local connected_service nwi_interfaces routed_tunnels

    connected_service=$(scutil --nc list 2>/dev/null |
        sed -nE '/\(Connected\)/s/.*"([^"]+)".*/\1/p' |
        paste -sd ',' - | sed 's/,/, /g')
    if [[ -n "$connected_service" ]]; then
        printf 'Connected: %s' "$connected_service"
        return 0
    fi

    nwi_interfaces=$(scutil --nwi 2>/dev/null | awk '
        /Network interfaces:/ {
            for (i = 3; i <= NF; i++) {
                gsub(/,/, "", $i)
                if ($i ~ /^utun[0-9]+$/) print $i
            }
        }
    ' | sort -u | paste -sd ',' - | sed 's/,/, /g')

    if [[ -n "$nwi_interfaces" ]]; then
        printf 'Connected (active tunnel: %s)' "$nwi_interfaces"
        return 0
    fi

    # Cisco AnyConnect / OpenVPN-style clients may keep the normal default
    # route while sending traffic through two half-default routes (0/1 and
    # 128/1), the same pattern used by VyprVPN.
    routed_tunnels=$(netstat -rn -f inet 2>/dev/null | awk '
        /^Destination/ {
            for (i = 1; i <= NF; i++)
                if ($i == "Netif") interface_column = i
            next
        }
        interface_column &&
        ($1 == "default" || $1 == "0/1" || $1 == "0.0.0.0/1" ||
         $1 == "128/1" || $1 == "128.0/1" || $1 == "128.0.0.0/1") &&
        $interface_column ~ /^(utun|tun|tap|ppp|ipsec)[0-9]*$/ {
            print $interface_column
        }
    ' | sort -u | paste -sd ',' - | sed 's/,/, /g')

    if [[ -n "$routed_tunnels" ]]; then
        printf 'Connected (routed tunnel: %s)' "$routed_tunnels"
        return 0
    fi

    return 1
}

# First tunnel interface that actually carries an address, independent of
# which detection method above flagged the VPN as connected.
vpn_tunnel_iface() {
    local iface ip
    for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^(utun|tun|tap|ppp|ipsec)[0-9]*$'); do
        ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2; exit}')
        if [[ -n "$ip" ]]; then
            printf '%s' "$iface"
            return 0
        fi
    done
    return 1
}

# The externally-visible IP — what a leak would actually expose — tried
# against a couple of providers in case one is blocked or down.
fetch_public_ip() {
    local ip
    ip=$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null) && [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
    ip=$(curl -fsS --max-time 3 https://ifconfig.me/ip 2>/dev/null) && [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
    ip=$(curl -fsS --max-time 3 https://icanhazip.com 2>/dev/null | tr -d '[:space:]') && [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
    return 1
}

suspend_code() {
    local pids
    pids=$(code_pids)
    [[ -z "$pids" ]] && return 1
    while IFS= read -r pid; do
        kill -STOP "$pid" 2>/dev/null || true
    done <<< "$pids"
    [[ "$paused" == false ]] && paused_at=$(date +%s)
    paused=true
    return 0
}

resume_code() {
    local pids
    pids=$(code_pids)
    [[ -n "$pids" ]] && while IFS= read -r pid; do
        kill -CONT "$pid" 2>/dev/null || true
    done <<< "$pids"
    paused=false
    paused_at=0
}

check_command_file() {
    [[ -z "$STATUS_FILE" || ! -f "${STATUS_FILE}.cmd" ]] && return
    local cmd
    cmd=$(<"${STATUS_FILE}.cmd")
    rm -f "${STATUS_FILE}.cmd"
    case "$cmd" in
        pause) suspend_code ;;
        resume) resume_code ;;
        stop) cleanup ;;
    esac
}

if [[ "$DAEMON_MODE" == false ]]; then
    printf '\033[?1049h\033[2J\033[H\033[?25l'
fi

while true; do
    check_command_file

    vpn=''
    vpn_connected=false
    if vpn=$(vpn_status); then
        vpn_connected=true
    fi

    pids=$(code_pids)
    process_count=0
    [[ -n "$pids" ]] && process_count=$(printf '%s\n' "$pids" | wc -l | tr -d ' ')

    iface=$(vpn_tunnel_iface) || iface=''

    public_ip_counter=$((public_ip_counter + 1))
    if [[ -z "$public_ip_cache" || "$public_ip_counter" -ge "$PUBLIC_IP_INTERVAL" ]]; then
        if new_ip=$(fetch_public_ip); then
            public_ip_cache="$new_ip"
        fi
        public_ip_counter=0
    fi

    if [[ "$vpn_connected" == false && "$paused" == false && -n "$pids" ]]; then
        suspend_code
    elif [[ "$vpn_connected" == true && "$paused" == true ]]; then
        resume_code
    fi

    state='running'
    [[ "$paused" == true ]] && state='paused'

    if [[ "$DAEMON_MODE" == true ]]; then
        write_status "$([[ "$vpn_connected" == true ]] && echo connected || echo disconnected)" "$vpn" "$state" "$process_count" "$iface" "$public_ip_cache" "$paused_at"
        sleep "$REFRESH_SECONDS"
        continue
    fi

    printf '\033[H'
    printf '\033[2K%b\n' "${BOLD}${CYAN}macOS VS Code + VPN Monitor${RESET}"
    printf '\033[2KUpdated: %s  |  Refresh: %ss\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$REFRESH_SECONDS"
    printf '\033[2K\n'

    if [[ "$paused" == true ]]; then
        elapsed=$(( $(date +%s) - paused_at ))
        printf '\033[2K%b\n' "${RED}${BOLD}VS CODE IS PAUSED (${process_count} processes frozen, ${elapsed}s so far)${RESET}"
    elif [[ -n "$pids" ]]; then
        color=$([[ "$vpn_connected" == true ]] && echo "$GREEN" || echo "$YELLOW")
        printf '\033[2K%b\n' "${color}${BOLD}VS Code running: ${process_count} processes${RESET}"
    else
        printf '\033[2K%b\n' "${GREEN}No VS Code processes detected.${RESET}"
    fi

    printf '\033[2K\n'
    if [[ "$vpn_connected" == true ]]; then
        printf '\033[2K%b\n' "${GREEN}${BOLD}VPN: ${vpn}${RESET}"
    else
        printf '\033[2K%b\n' "${RED}${BOLD}VPN: Not connected — VS Code auto-pause is armed${RESET}"
    fi

    printf '\033[2KTunnel interface: %s\n' "${iface:-none}"
    printf '\033[2KPublic IP: %s\n' "${public_ip_cache:-unknown}"

    printf '\033[2K\n'
    printf '\033[2K%s\n' 'Options: [p] Pause now   [r] Resume now   [x] Exit'
    printf '\033[2K%s' 'Choice (monitor keeps refreshing): '
    printf '\033[J'

    choice=''
    if IFS= read -r -s -n 1 -t "$REFRESH_SECONDS" choice; then
        case "$choice" in
            p|P) suspend_code ;;
            r|R) resume_code ;;
            x|X|q|Q) cleanup ;;
        esac
    fi
done
