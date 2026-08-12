#!/bin/bash
#
# Claude Watch Launcher for macOS
#
# Author:  Amirreza Shayesteh Far
# GitHub:  https://github.com/amirrezashf
# Website: https://amirrezaa.ir/
#
# Upstream project:
# https://github.com/omidkorat/claude-watch
#
# Purpose:
# - Double-click launcher for Claude Watch on macOS.
# - Works when committed directly inside a claude-watch repository.
# - Safely updates the local repository with fast-forward-only Git pulls.
# - Falls back to a managed clone when the launcher is used standalone.
#
# License:
# This launcher is intended to be distributed alongside the upstream
# claude-watch project and its MIT license.
#

set -u

UPSTREAM_REPO_URL="https://github.com/omidkorat/claude-watch.git"
MANAGED_ROOT="$HOME/Library/Application Support/Claude Watch"
MANAGED_REPO="$MANAGED_ROOT/repository"

# Resolve the directory containing this launcher, including paths with spaces.
LAUNCHER_DIR="$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd -P)"

# ---------- Terminal presentation ----------

if [ -t 1 ]; then
    RESET=$'\033[0m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    RED=$'\033[31m'
    CYAN=$'\033[36m'
else
    RESET=""
    BOLD=""
    DIM=""
    GREEN=""
    YELLOW=""
    RED=""
    CYAN=""
fi

clear

printf "%s%sClaude Watch%s\n" "$BOLD" "$CYAN" "$RESET"
printf "%smacOS launcher by Amirreza Shayesteh Far%s\n" "$DIM" "$RESET"
printf "%shttps://github.com/amirrezashf  •  https://amirrezaa.ir/%s\n\n" "$DIM" "$RESET"

pause_and_exit() {
    local code="${1:-1}"

    printf "\nPress any key to close..."
    IFS= read -r -n 1 _
    printf "\n"

    exit "$code"
}

die() {
    printf "\n%s%sError:%s %s\n" "$BOLD" "$RED" "$RESET" "$1" >&2
    pause_and_exit 1
}

warn() {
    printf "%s%sWarning:%s %s\n" "$BOLD" "$YELLOW" "$RESET" "$1"
}

ok() {
    printf "%s%s✓%s %s\n" "$BOLD" "$GREEN" "$RESET" "$1"
}

info() {
    printf "%s%s→%s %s\n" "$BOLD" "$CYAN" "$RESET" "$1"
}

# ---------- Requirements ----------

command -v git >/dev/null 2>&1 || die \
    "Git is not available.

Install Apple's Command Line Tools first:
xcode-select --install"

# ---------- Repository discovery ----------

REPO_DIR=""

# Preferred mode:
# The launcher is committed inside the repository next to claude-watch.sh.
if [ -f "$LAUNCHER_DIR/claude-watch.sh" ] && [ -d "$LAUNCHER_DIR/.git" ]; then
    REPO_DIR="$LAUNCHER_DIR"
    info "Using the repository containing this launcher."

# Convenience fallback:
# Common manual clone location used by many users.
elif [ -f "$HOME/claude-watch/claude-watch.sh" ] && [ -d "$HOME/claude-watch/.git" ]; then
    REPO_DIR="$HOME/claude-watch"
    info "Using existing repository at ~/claude-watch."

# Standalone mode:
# Keep a managed clone in Application Support.
else
    mkdir -p "$MANAGED_ROOT" || die \
        "Could not create:
$MANAGED_ROOT"

    if [ ! -d "$MANAGED_REPO/.git" ]; then
        info "No local Claude Watch repository was found."
        info "Cloning the upstream repository..."

        if [ -e "$MANAGED_REPO" ]; then
            rm -rf "$MANAGED_REPO" || die \
                "Could not remove an incomplete managed repository."
        fi

        if ! git clone --quiet --depth 1 "$UPSTREAM_REPO_URL" "$MANAGED_REPO"; then
            die "Could not clone:
$UPSTREAM_REPO_URL"
        fi

        ok "Repository cloned."
    fi

    REPO_DIR="$MANAGED_REPO"
    info "Using managed repository in Application Support."
fi

SCRIPT_PATH="$REPO_DIR/claude-watch.sh"

[ -d "$REPO_DIR/.git" ] || die \
    "Selected directory is not a Git repository:
$REPO_DIR"

[ -f "$SCRIPT_PATH" ] || die \
    "claude-watch.sh was not found:
$SCRIPT_PATH"

# ---------- Repository validation ----------

ORIGIN_URL="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"

if [ -n "$ORIGIN_URL" ]; then
    printf "%sRepository:%s %s\n" "$DIM" "$RESET" "$ORIGIN_URL"
else
    warn "No Git origin remote is configured."
fi

# ---------- Safe update ----------

if [ -z "$ORIGIN_URL" ]; then
    warn "Automatic update skipped because the repository has no origin remote."
elif [ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]; then
    warn "Local repository has uncommitted changes; automatic update skipped."
else
    CURRENT_BRANCH="$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || true)"

    if [ -z "$CURRENT_BRANCH" ]; then
        warn "Repository is in detached HEAD state; automatic update skipped."
    else
        info "Checking for updates on branch '$CURRENT_BRANCH'..."

        if git -C "$REPO_DIR" pull --quiet --ff-only origin "$CURRENT_BRANCH"; then
            ok "Repository is up to date."
        else
            warn "Update failed. The existing local version will be used."
        fi
    fi
fi

# ---------- Script validation ----------

chmod u+x "$SCRIPT_PATH" 2>/dev/null || die \
    "Could not make claude-watch.sh executable."

REVISION="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"

printf "%sRevision:%s   %s\n" "$DIM" "$RESET" "$REVISION"
printf "%sLocation:%s   %s\n\n" "$DIM" "$RESET" "$REPO_DIR"

# ---------- Run ----------

cd "$REPO_DIR" || die \
    "Could not enter:
$REPO_DIR"

info "Starting Claude Watch..."
printf "\n"

# Replace the launcher process with the original script so Ctrl-C and the
# script's own exit behavior remain clean and predictable.
exec "$SCRIPT_PATH"
