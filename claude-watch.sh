#!/bin/bash

# Continuously monitor Claude processes and VPN connectivity on macOS.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

REFRESH_SECONDS=2

cleanup() {
    printf '\033[?25h\033[?1049l%bMonitor stopped.%b\n' "$CYAN" "$RESET"
    stty echo 2>/dev/null || true
    exit 0
}

trap cleanup INT TERM HUP

claude_pids() {
    ps -axo pid=,command= | awk -v self="$$" '
        $1 != self && tolower($0) ~ /claude/ &&
        $0 !~ /[a]wk -v self=/ { print $1 }
    ' | sort -u
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

    # OpenVPN clients such as VyprVPN may keep the normal default route while
    # sending traffic through two half-default routes (0/1 and 128/1).
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

kill_claude() {
    local pids
    pids=$(claude_pids)
    [[ -z "$pids" ]] && return

    while IFS= read -r pid; do
        kill -TERM "$pid" 2>/dev/null || true
    done <<< "$pids"

    sleep 1

    claude_pids | while IFS= read -r pid; do
        kill -KILL "$pid" 2>/dev/null || true
    done
}

printf '\033[?1049h\033[2J\033[H\033[?25l'

while true; do
    printf '\033[H'

    pids=$(claude_pids)
    vpn=''
    vpn_connected=false
    auto_killed=false

    if vpn=$(vpn_status); then
        vpn_connected=true
    fi

    if [[ -n "$pids" && "$vpn_connected" == false ]]; then
        kill_claude
        auto_killed=true
        pids=$(claude_pids)
    fi

    printf '\033[2K%b\n' "${BOLD}${CYAN}macOS Claude + VPN Monitor${RESET}"
    printf '\033[2KUpdated: %s  |  Refresh: %ss\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$REFRESH_SECONDS"
    printf '\033[2K\n'

    if [[ -n "$pids" ]]; then
        process_count=$(printf '%s\n' "$pids" | wc -l | tr -d ' ')
        if [[ "$vpn_connected" == true ]]; then
            claude_color="$YELLOW"
        else
            claude_color="$RED"
        fi

        if [[ "$process_count" -eq 1 ]]; then
            printf '\033[2K%b\n' "${claude_color}${BOLD}CLAUDE IS RUNNING: 1 process${RESET}"
        else
            printf '\033[2K%b\n' "${claude_color}${BOLD}CLAUDE IS RUNNING: ${process_count} processes${RESET}"
        fi
    else
        printf '\033[2K%b\n' "${GREEN}No Claude processes are running.${RESET}"
    fi

    if [[ "$auto_killed" == true ]]; then
        printf '\033[2K%b\n' "${RED}${BOLD}Claude was automatically stopped because the VPN is disconnected.${RESET}"
    fi

    printf '\033[2K\n'
    if [[ "$vpn_connected" == true ]]; then
        printf '\033[2K%b\n' "${GREEN}${BOLD}VPN: ${vpn}${RESET}"
    else
        printf '\033[2K%b\n' "${RED}${BOLD}VPN: Not connected — Claude auto-kill is armed${RESET}"
    fi

    printf '\033[2K\n'
    printf '\033[2K%s\n' 'Options: [k] Kill all Claude processes   [x] Exit'
    printf '\033[2K%s' 'Choice (monitor keeps refreshing): '
    printf '\033[J'

    choice=''
    if IFS= read -r -s -n 1 -t "$REFRESH_SECONDS" choice; then
        case "$choice" in
            k|K) kill_claude ;;
            x|X|q|Q) cleanup ;;
        esac
    fi
done
