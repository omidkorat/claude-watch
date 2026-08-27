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
VPN_DISCONNECT_CONFIRMATIONS=3
VPN_POST_CHANGE_GRACE_SECONDS=10

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

update_vpn_state() {
    local raw_connected="$1"

    if [[ "$raw_connected" == true ]]; then
        vpn_state='connected'
        vpn_misses=0
        return
    fi

    # A time-zone change can briefly refresh macOS network state. Keep the
    # previous stable state during this grace period, but Claude is still
    # blocked immediately by the raw VPN check in the main loop.
    if (( SECONDS < vpn_grace_until )); then
        vpn_misses=0
        return
    fi

    vpn_misses=$((vpn_misses + 1))
    if (( vpn_misses >= VPN_DISCONNECT_CONFIRMATIONS )); then
        vpn_state='disconnected'
    fi
}

set_timezone() {
    local target_timezone="$1"
    local target_name="$2"
    local change_status change_output

    # Leave the alternate screen so macOS can show sudo's password prompt.
    printf '\033[?25h\033[?1049l\n'
    printf 'The network state requires the %s time zone.\n' "$target_name"
    printf 'Enter your Mac administrator password to change it to %s.\n' "$target_timezone"

    change_output=$(sudo /usr/sbin/systemsetup -settimezone "$target_timezone" 2>&1)
    change_status=$?

    if [[ $change_status -ne 0 ]]; then
        printf 'Time-zone change failed.\n'
        [[ -n "$change_output" ]] && printf '%s\n' "$change_output"
    fi

    printf '\033[?1049h\033[2J\033[H\033[?25l'
    [[ $change_status -eq 0 && "$(get_timezone)" == "$target_timezone" ]]
}

request_timezone_action() {
    local target_timezone="$1"
    local target_name="$2"
    local current_timezone="$3"
    local choice

    printf '\033[?25h\033[?1049l\n'
    printf 'Time-zone protection found a mismatch.\n\n'
    printf 'Current time zone:  %s\n' "${current_timezone:-Unknown}"
    printf 'Required time zone: %s (%s)\n\n' "$target_name" "$target_timezone"
    printf 'Reading the current time zone does not require administrator access.\n'
    printf 'macOS requires administrator access only to change this system-wide setting.\n\n'
    printf '[c] Change the time zone (administrator password required)\n'
    printf '[s] Skip time-zone protection for this session (no sudo)\n'
    printf '[x] Exit Claude Watch\n\n'

    if [[ -t 0 ]]; then
        IFS= read -r -p 'Choice [c/s/x]: ' choice
    else
        choice='s'
        printf 'No interactive terminal detected; skipping time-zone protection for this session.\n'
    fi

    printf '\033[?1049h\033[2J\033[H\033[?25l'
    case "$choice" in
        c|C) timezone_action='change' ;;
        x|X|q|Q) timezone_action='exit' ;;
        *) timezone_action='skip' ;;
    esac
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

    vpn_state='unknown'
    vpn_misses=0
    vpn_grace_until=0
    update_vpn_state false
    [[ "$vpn_state" == 'unknown' ]] || return 1
    update_vpn_state false
    [[ "$vpn_state" == 'unknown' ]] || return 1
    update_vpn_state false
    [[ "$vpn_state" == 'disconnected' ]] || return 1
    update_vpn_state true
    [[ "$vpn_state" == 'connected' && $vpn_misses -eq 0 ]] || return 1
    update_vpn_state false
    update_vpn_state false
    [[ "$vpn_state" == 'connected' ]] || return 1
    update_vpn_state false
    [[ "$vpn_state" == 'disconnected' ]] || return 1
    vpn_state='connected'
    vpn_misses=0
    vpn_grace_until=$((SECONDS + 60))
    update_vpn_state false
    [[ "$vpn_state" == 'connected' && $vpn_misses -eq 0 ]] || return 1

    printf 'Claude Watch macOS self-test passed.\n'
}

if [[ "${1:-}" == '--self-test' ]]; then
    invoke_self_test
    exit $?
fi

timezone_enforcement=true
if [[ "${1:-}" == '--no-timezone' ]]; then
    timezone_enforcement=false
fi

printf '\033[?1049h\033[2J\033[H\033[?25l'

timezone_attempted_for=''
timezone_changed_to=''
timezone_change_failed=false
vpn_state='unknown'
vpn_misses=0
vpn_grace_until=0

while true; do
    printf '\033[H'

    pids=$(claude_pids)
    vpn=''
    raw_vpn_connected=false
    vpn_connected=false
    auto_killed=false
    auto_kill_reason=''
    timezone=$(get_timezone)
    timezone_ready=false
    timezone_synced=false
    timezone_target_known=false

    if [[ "$timezone" == "$REQUIRED_TIMEZONE" ]]; then
        timezone_ready=true
    fi

    if vpn=$(vpn_status); then
        raw_vpn_connected=true
        vpn_connected=true
    fi
    update_vpn_state "$raw_vpn_connected"

    case "$vpn_state" in
        connected)
            target_timezone="$REQUIRED_TIMEZONE"
            target_timezone_name='New York'
            timezone_target_known=true
            ;;
        disconnected)
            target_timezone="$HOME_TIMEZONE"
            target_timezone_name='Tehran'
            timezone_target_known=true
            ;;
        *)
            target_timezone=''
            target_timezone_name=''
            ;;
    esac

    if [[ "$timezone_target_known" == true && "$timezone" == "$target_timezone" ]]; then
        timezone_synced=true
        timezone_attempted_for=''
        timezone_change_failed=false
    fi

    # A disconnected VPN always blocks Claude, regardless of time-zone preference.
    if [[ -n "$pids" && "$vpn_connected" == false ]]; then
        kill_claude
        auto_killed=true
        auto_kill_reason='the VPN is disconnected'
        pids=$(claude_pids)
    fi

    # Ask before requesting elevated access. Skipping disables this protection
    # for the current session and guarantees that sudo will not be called.
    if [[ "$timezone_enforcement" == true && "$timezone_target_known" == true && "$timezone_synced" == false && "$timezone_attempted_for" != "$target_timezone" ]]; then
        timezone_attempted_for="$target_timezone"
        request_timezone_action "$target_timezone" "$target_timezone_name" "$timezone"
        case "$timezone_action" in
            skip)
                timezone_enforcement=false
                timezone_change_failed=false
                ;;
            exit)
                cleanup
                ;;
            change)
                if [[ -n "$pids" ]]; then
                    kill_claude
                    auto_killed=true
                    auto_kill_reason="time-zone protection requires $REQUIRED_TIMEZONE"
                    pids=$(claude_pids)
                fi
                if set_timezone "$target_timezone" "$target_timezone_name"; then
                    timezone=$(get_timezone)
                    timezone_synced=true
                    timezone_changed_to="$target_timezone"
                    timezone_change_failed=false
                    vpn_grace_until=$((SECONDS + VPN_POST_CHANGE_GRACE_SECONDS))
                    if [[ "$timezone" == "$REQUIRED_TIMEZONE" ]]; then
                        timezone_ready=true
                    else
                        timezone_ready=false
                    fi
                else
                    timezone=$(get_timezone)
                    timezone_change_failed=true
                fi
                ;;
        esac
    fi

    # If protected time-zone correction failed, newly opened Claude processes
    # remain blocked until the user retries or skips this protection.
    if [[ -n "$pids" && "$vpn_connected" == true && "$timezone_enforcement" == true && "$timezone_ready" == false ]]; then
        kill_claude
        auto_killed=true
        auto_kill_reason="the time zone is ${timezone:-unknown}, not $REQUIRED_TIMEZONE"
        pids=$(claude_pids)
    fi

    printf '\033[2K%b\n' "${BOLD}${CYAN}macOS Claude + VPN + Time Zone Monitor${RESET}"
    printf '\033[2KUpdated: %s  |  Refresh: %ss\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$REFRESH_SECONDS"
    printf '\033[2K\n'

    if [[ -n "$pids" ]]; then
        process_count=$(printf '%s\n' "$pids" | wc -l | tr -d ' ')
        if [[ "$vpn_connected" == true && ("$timezone_enforcement" == false || "$timezone_ready" == true) ]]; then
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
    if [[ "$raw_vpn_connected" == true ]]; then
        printf '\033[2K%b\n' "${GREEN}${BOLD}VPN: ${vpn}${RESET}"
    elif [[ "$vpn_state" != 'disconnected' ]]; then
        printf '\033[2K%b\n' "${YELLOW}${BOLD}VPN: Rechecking (${vpn_misses}/${VPN_DISCONNECT_CONFIRMATIONS}) — Claude blocked; time zone unchanged${RESET}"
    else
        printf '\033[2K%b\n' "${RED}${BOLD}VPN: Not connected — Claude auto-kill is armed${RESET}"
    fi

    if [[ "$timezone_enforcement" == false ]]; then
        printf '\033[2K%b\n' "${YELLOW}${BOLD}TIME ZONE: ${timezone:-Unknown} — protection skipped for this session${RESET}"
    elif [[ "$timezone_target_known" == false ]]; then
        printf '\033[2K%b\n' "${YELLOW}${BOLD}TIME ZONE: ${timezone:-Unknown} — waiting for stable VPN state${RESET}"
    elif [[ "$timezone_synced" == true ]]; then
        printf '\033[2K%b\n' "${GREEN}${BOLD}TIME ZONE: ${timezone}${RESET}"
    else
        printf '\033[2K%b\n' "${RED}${BOLD}TIME ZONE: ${timezone:-Unknown} — expected ${target_timezone}${RESET}"
    fi

    if [[ "$vpn_connected" == true && "$timezone_enforcement" == false ]]; then
        printf '\033[2K%b\n' "${GREEN}${BOLD}READY: VPN confirmed. Time-zone protection is disabled. You can open Claude.${RESET}"
    elif [[ "$vpn_connected" == true && "$timezone_ready" == true ]]; then
        if [[ "$timezone_changed_to" == "$REQUIRED_TIMEZONE" ]]; then
            printf '\033[2K%b\n' "${GREEN}${BOLD}READY: Time zone changed to New York. You can open Claude now.${RESET}"
        else
            printf '\033[2K%b\n' "${GREEN}${BOLD}READY: VPN and New York time zone confirmed. You can open Claude.${RESET}"
        fi
    elif [[ "$vpn_connected" == false && "$timezone_enforcement" == false ]]; then
        printf '\033[2K%b\n' "${RED}${BOLD}SAFE: VPN is disconnected. Claude remains blocked.${RESET}"
    elif [[ "$vpn_connected" == false && "$timezone_synced" == true ]]; then
        printf '\033[2K%b\n' "${RED}${BOLD}SAFE: Time zone is Tehran. Claude remains blocked until VPN connects.${RESET}"
    elif [[ "$timezone_change_failed" == true ]]; then
        printf '\033[2K%b\n' "${RED}${BOLD}Time zone change failed. Claude remains blocked; press [t] to retry.${RESET}"
    else
        printf '\033[2K\n'
    fi

    printf '\033[2K\n'
    printf '\033[2K%s\n' 'Options: [k] Kill Claude   [t] Enable/sync time zone   [x] Exit'
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
                timezone_enforcement=true
                timezone_attempted_for=''
                timezone_changed_to=''
                ;;
            x|X|q|Q) cleanup ;;
        esac
    fi
done
