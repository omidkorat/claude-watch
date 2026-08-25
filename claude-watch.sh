#!/bin/bash

# Continuously monitor Claude processes, VPN connectivity, and time zone on macOS.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

REFRESH_SECONDS=2
REQUIRED_TIMEZONE='America/New_York'
HOME_TIMEZONE='Asia/Tehran'

cleanup() {
    printf '\033[?25h\033[?1049l%bMonitor stopped.%b\n' "$CYAN" "$RESET"
    stty echo 2>/dev/null || true
    exit 0
}

trap cleanup INT TERM HUP

claude_pids() {
    # Match process names only, including Claude helpers, without scanning
    # unrelated command-line arguments that happen to contain "claude".
    pgrep -i '^Claude($|[ -])' 2>/dev/null || true
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

get_timezone() {
    local timezone_link

    timezone_link=$(readlink /etc/localtime 2>/dev/null) || return 1
    case "$timezone_link" in
        */zoneinfo/*) printf '%s' "${timezone_link#*/zoneinfo/}" ;;
        *) return 1 ;;
    esac
}

target_timezone_for_vpn() {
    if [[ "$1" == true ]]; then
        printf '%s' "$REQUIRED_TIMEZONE"
    else
        printf '%s' "$HOME_TIMEZONE"
    fi
}

set_timezone() {
    local target_timezone="$1"
    local target_name="$2"
    local change_status

    # Leave the alternate screen so macOS can show sudo's password prompt.
    printf '\033[?25h\033[?1049l\n'
    printf 'The network state requires the %s time zone.\n' "$target_name"
    printf 'Enter your Mac administrator password to change it to %s.\n' "$target_timezone"

    sudo /usr/sbin/systemsetup -settimezone "$target_timezone"
    change_status=$?

    if [[ $change_status -eq 0 ]]; then
        sudo /usr/sbin/systemsetup -setnetworktimeserver time.apple.com >/dev/null 2>&1 || true
        sudo /usr/sbin/systemsetup -setusingnetworktime on >/dev/null 2>&1 || true
    fi

    printf '\033[?1049h\033[2J\033[H\033[?25l'
    [[ $change_status -eq 0 && "$(get_timezone)" == "$target_timezone" ]]
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

invoke_self_test() {
    [[ "$(target_timezone_for_vpn true)" == "$REQUIRED_TIMEZONE" ]] || return 1
    [[ "$(target_timezone_for_vpn false)" == "$HOME_TIMEZONE" ]] || return 1
    [[ -n "$(get_timezone)" ]] || return 1
    [[ -e "/usr/share/zoneinfo/$REQUIRED_TIMEZONE" ]] || return 1
    [[ -e "/usr/share/zoneinfo/$HOME_TIMEZONE" ]] || return 1
    command -v pgrep >/dev/null 2>&1 || return 1
    command -v scutil >/dev/null 2>&1 || return 1
    command -v systemsetup >/dev/null 2>&1 || return 1
    printf 'Claude Watch macOS self-test passed.\n'
}

if [[ "${1:-}" == '--self-test' ]]; then
    invoke_self_test
    exit $?
fi

printf '\033[?1049h\033[2J\033[H\033[?25l'

timezone_attempted_for=''
timezone_changed_to=''
timezone_change_failed=false

while true; do
    printf '\033[H'

    pids=$(claude_pids)
    vpn=''
    vpn_connected=false
    auto_killed=false
    auto_kill_reason=''
    timezone=$(get_timezone)
    timezone_ready=false
    timezone_synced=false

    if [[ "$timezone" == "$REQUIRED_TIMEZONE" ]]; then
        timezone_ready=true
    fi

    if vpn=$(vpn_status); then
        vpn_connected=true
        target_timezone_name='New York'
    else
        target_timezone_name='Tehran'
    fi
    target_timezone=$(target_timezone_for_vpn "$vpn_connected")

    if [[ "$timezone" == "$target_timezone" ]]; then
        timezone_synced=true
        timezone_attempted_for=''
        timezone_change_failed=false
    fi

    # Claude is allowed only when both the VPN and New York time zone are ready.
    if [[ -n "$pids" && ("$vpn_connected" == false || "$timezone_ready" == false) ]]; then
        kill_claude
        auto_killed=true
        if [[ "$vpn_connected" == false ]]; then
            auto_kill_reason='the VPN is disconnected'
        else
            auto_kill_reason="the time zone is ${timezone:-unknown}, not $REQUIRED_TIMEZONE"
        fi
        pids=$(claude_pids)
    fi

    # Keep New York time while protected by VPN, and Tehran time otherwise.
    if [[ "$timezone_synced" == false && "$timezone_attempted_for" != "$target_timezone" ]]; then
        timezone_attempted_for="$target_timezone"
        if set_timezone "$target_timezone" "$target_timezone_name"; then
            timezone=$(get_timezone)
            timezone_synced=true
            timezone_changed_to="$target_timezone"
            timezone_change_failed=false
            if [[ "$timezone" == "$REQUIRED_TIMEZONE" ]]; then
                timezone_ready=true
            else
                timezone_ready=false
            fi
        else
            timezone=$(get_timezone)
            timezone_change_failed=true
        fi
    fi

    printf '\033[2K%b\n' "${BOLD}${CYAN}macOS Claude + VPN + Time Zone Monitor${RESET}"
    printf '\033[2KUpdated: %s  |  Refresh: %ss\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$REFRESH_SECONDS"
    printf '\033[2K\n'

    if [[ -n "$pids" ]]; then
        process_count=$(printf '%s\n' "$pids" | wc -l | tr -d ' ')
        if [[ "$vpn_connected" == true && "$timezone_ready" == true ]]; then
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
        printf '\033[2K%b\n' "${RED}${BOLD}Claude was automatically stopped because ${auto_kill_reason}.${RESET}"
    fi

    printf '\033[2K\n'
    if [[ "$vpn_connected" == true ]]; then
        printf '\033[2K%b\n' "${GREEN}${BOLD}VPN: ${vpn}${RESET}"
    else
        printf '\033[2K%b\n' "${RED}${BOLD}VPN: Not connected — Claude auto-kill is armed${RESET}"
    fi

    if [[ "$timezone_synced" == true ]]; then
        printf '\033[2K%b\n' "${GREEN}${BOLD}TIME ZONE: ${timezone}${RESET}"
    else
        printf '\033[2K%b\n' "${RED}${BOLD}TIME ZONE: ${timezone:-Unknown} — expected ${target_timezone}${RESET}"
    fi

    if [[ "$vpn_connected" == true && "$timezone_ready" == true ]]; then
        if [[ "$timezone_changed_to" == "$REQUIRED_TIMEZONE" ]]; then
            printf '\033[2K%b\n' "${GREEN}${BOLD}READY: Time zone changed to New York. You can open Claude now.${RESET}"
        else
            printf '\033[2K%b\n' "${GREEN}${BOLD}READY: VPN and New York time zone confirmed. You can open Claude.${RESET}"
        fi
    elif [[ "$vpn_connected" == false && "$timezone_synced" == true ]]; then
        printf '\033[2K%b\n' "${RED}${BOLD}SAFE: Time zone is Tehran. Claude remains blocked until VPN connects.${RESET}"
    elif [[ "$timezone_change_failed" == true ]]; then
        printf '\033[2K%b\n' "${RED}${BOLD}Time zone change failed. Claude remains blocked; press [t] to retry.${RESET}"
    else
        printf '\033[2K\n'
    fi

    printf '\033[2K\n'
    printf '\033[2K%s\n' 'Options: [k] Kill Claude   [t] Sync time zone   [x] Exit'
    printf '\033[2K%s' 'Choice (monitor keeps refreshing): '
    printf '\033[J'

    if [[ ! -t 0 ]]; then
        sleep "$REFRESH_SECONDS"
        continue
    fi

    choice=''
    if IFS= read -r -s -n 1 -t "$REFRESH_SECONDS" choice; then
        case "$choice" in
            k|K) kill_claude ;;
            t|T)
                timezone_attempted_for=''
                timezone_changed_to=''
                ;;
            x|X|q|Q) cleanup ;;
        esac
    fi
done
