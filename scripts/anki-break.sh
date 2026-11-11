#!/bin/sh
# Anki-Break: open Anki while Claude Code works, close it when Claude is done.
#
#   anki-break.sh start            UserPromptSubmit: mark the session as working
#   anki-break.sh stop             Stop and friends: unmark it, send Anki away
#   anki-break.sh pause <folder> <session> [duration]   pause in one chat
#   anki-break.sh resume <folder> <session>             resume in one chat
#   anki-break.sh doctor [folder] [session]             diagnose, change nothing
#
# Internal actions, run in the background: open-later, finish.
# Hook events pass JSON on stdin. See SPEC.md for the full behaviour.

DEFAULT_DELAY=10
MAX_DELAY=600
IDLE_MS=1500           # focus only moves after this much keyboard and mouse quiet
IDLE_WAIT=60           # seconds to wait for that quiet before giving up
LAUNCH_WAIT=30         # seconds to wait for a launching Anki to run
QUIET_SECONDS=60       # after another session stops, Anki stays closed this long
ACTIVE_MINUTES=120     # working marks older than this are ignored
CLEANUP_MINUTES=1440   # session and stop files older than this are deleted
PAUSE_CLEANUP=10080    # pause files of chats that never ended are deleted after 7 days
MAX_PAUSE=1440         # longest timed pause, in minutes
LOG_LINES=200

SELF=$0
DATA=${CLAUDE_PLUGIN_DATA:-}
SESSIONS="$DATA/sessions"
STOPS="$DATA/stops"
PAUSED="$DATA/paused"
INPUT=""
ANKI_PATH=""
ANKI_ID=""

# ---------------------------------------------------------------- settings

delay_seconds() {
    value=${CLAUDE_PLUGIN_OPTION_DELAY_SECONDS:-}
    if printf '%s' "$value" | grep -Eq '^[0-9]{1,6}([.][0-9]+)?$'; then
        value=${value%%.*}
        if [ "$value" -gt "$MAX_DELAY" ]; then
            value=$MAX_DELAY
        fi
        printf '%s\n' "$value"
    else
        printf '%s\n' "$DEFAULT_DELAY"
    fi
}

when_done() {
    value=$(printf '%s' "${CLAUDE_PLUGIN_OPTION_WHEN_DONE:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    if [ "$value" = quit ]; then
        echo quit
    else
        echo keep
    fi
}

disabled() {
    [ -n "${ANKI_BREAK_DISABLE:-}" ] && [ "${ANKI_BREAK_DISABLE}" != 0 ]
}

# ---------------------------------------------------------------- helpers

log() {
    [ -n "$DATA" ] || return 0
    mkdir -p "$DATA" 2>/dev/null || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$DATA/log" 2>/dev/null
}

trim_log() {
    [ -f "$DATA/log" ] || return 0
    lines=$(wc -l <"$DATA/log" | tr -d ' ')
    if [ "$lines" -gt $((LOG_LINES * 2)) ]; then
        tail -n "$LOG_LINES" "$DATA/log" >"$DATA/log.tmp" && mv "$DATA/log.tmp" "$DATA/log"
    fi
}

is_mac() {
    [ "$(uname -s 2>/dev/null)" = Darwin ]
}

valid_bundle() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$'
}

# Anki's bundle id changed: net.ankiweb.dtop up to 25.06, net.ankiweb.launcher
# for 25.07 to 25.09, net.ankiweb.anki from 26.05. Read it from the app itself.
find_anki() {
    ANKI_PATH=""
    ANKI_ID=""
    # ANKI_BREAK_APP_DIR replaces the standard folders. It exists for the tests.
    if [ -n "${ANKI_BREAK_APP_DIR:-}" ]; then
        set -- "$ANKI_BREAK_APP_DIR"
    else
        set -- /Applications "$HOME/Applications"
    fi
    for dir in "$@"; do
        if [ -d "$dir/Anki.app" ]; then
            ANKI_PATH="$dir/Anki.app"
            break
        fi
    done
    if [ -z "$ANKI_PATH" ]; then
        ANKI_PATH=$(mdfind "kMDItemCFBundleIdentifier == 'net.ankiweb.anki' || kMDItemCFBundleIdentifier == 'net.ankiweb.launcher' || kMDItemCFBundleIdentifier == 'net.ankiweb.dtop'" 2>/dev/null | head -n 1)
    fi
    [ -n "$ANKI_PATH" ] || return 1
    ANKI_ID=$(defaults read "$ANKI_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null)
    if ! valid_bundle "$ANKI_ID"; then
        ANKI_ID=net.ankiweb.anki
    fi
    return 0
}

# The app Claude Code runs in. macOS passes __CFBundleIdentifier to the shells
# of Terminal, iTerm, VS Code and other apps. Cron jobs, launchd jobs and SSH
# sessions do not have it, so scripted runs never open Anki.
host_app() {
    host=${__CFBundleIdentifier:-}
    if valid_bundle "$host" && [ "$host" != "$ANKI_ID" ]; then
        printf '%s\n' "$host"
    fi
}

# lsappinfo needs no permission. It prints "[ NULL ]" or nothing when an app
# is not running.
app_asn() {
    lsappinfo find "bundleid=$1" 2>/dev/null | grep -v NULL | head -n 1
}

app_running() {
    [ -n "$(app_asn "$1")" ]
}

anki_running() {
    app_running "$ANKI_ID"
}

anki_pid() {
    asn=$(app_asn "$ANKI_ID")
    [ -n "$asn" ] || return 0
    lsappinfo info -only pid "$asn" 2>/dev/null |
        sed -n 's/.*"pid"[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1
}

front_app() {
    asn=$(lsappinfo front 2>/dev/null | grep -v NULL)
    [ -n "$asn" ] || return 0
    lsappinfo info -only bundleid "$asn" 2>/dev/null |
        sed -n 's/.*"CFBundleIdentifier"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1
}

idle_ms() {
    # Time since the last keyboard or mouse input, in nanoseconds. No permission needed.
    value=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ { printf "%d\n", $NF / 1000000; exit }')
    printf '%s\n' "${value:-999999}"
}

wait_until_idle() {
    waited=0
    while [ "$(idle_ms)" -lt "$IDLE_MS" ]; do
        if [ "$waited" -ge "$IDLE_WAIT" ]; then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

# A directory lock that records its owner. It is only broken when that
# process is gone, never because it is held for a long time.
lock() {
    [ -n "$DATA" ] || return 1
    tries=0
    while ! mkdir "$DATA/lock" 2>/dev/null; do
        tries=$((tries + 1))
        holder=$(cat "$DATA/lock/pid" 2>/dev/null)
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            rm -rf "$DATA/lock"
            continue
        fi
        if [ -z "$holder" ] && [ "$tries" -ge 5 ]; then
            # The owner died between creating the lock and writing its pid.
            rm -rf "$DATA/lock"
            continue
        fi
        if [ "$tries" -ge 120 ]; then
            log "lock busy for two minutes, giving up"
            return 1
        fi
        sleep 1
    done
    echo $$ >"$DATA/lock/pid"
    return 0
}

unlock() {
    if [ "$(cat "$DATA/lock/pid" 2>/dev/null)" = $$ ]; then
        rm -rf "$DATA/lock"
    fi
}

use_folder() {
    DATA=$1
    SESSIONS="$DATA/sessions"
    STOPS="$DATA/stops"
    PAUSED="$DATA/paused"
}

read_input() {
    if [ ! -t 0 ]; then
        INPUT=$(cat)
    fi
}

# A string field of the hook's JSON input, limited to safe characters.
json_field() {
    printf '%s\n' "$INPUT" |
        sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([A-Za-z0-9_-]\{1,128\}\)\".*/\1/p" |
        head -n 1
}

valid_session() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]{1,128}$'
}

# A pause file holds the end time in epoch seconds, or 0 for "until resumed".
is_paused() {
    file="$PAUSED/$1"
    [ -f "$file" ] || return 1
    ends=$(cat "$file" 2>/dev/null)
    case $ends in
        '' | *[!0-9]*)
            rm -f "$file"
            return 1
            ;;
    esac
    if [ "$ends" -eq 0 ] || [ "$(date +%s)" -lt "$ends" ]; then
        return 0
    fi
    rm -f "$file"
    return 1
}

# Minutes from "30", "30m" or "2h", between 1 and MAX_PAUSE.
duration_minutes() {
    value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ' | sed 's/^0*\([0-9]\)/\1/')
    if printf '%s' "$value" | grep -Eq '^[0-9]{1,4}m?$'; then
        minutes=${value%m}
    elif printf '%s' "$value" | grep -Eq '^[0-9]{1,2}h$'; then
        minutes=$((${value%h} * 60))
    else
        return 1
    fi
    if [ "$minutes" -lt 1 ] || [ "$minutes" -gt "$MAX_PAUSE" ]; then
        return 1
    fi
    printf '%s\n' "$minutes"
}

clock() {
    date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null
}

folder_error() {
    echo "Anki-Break could not find its data folder. Restart Claude Code and try again." >&2
    exit 2
}

# pause and resume get the data folder and session id from the skill.
check_skill_args() {
    # The folder must be a real absolute path, not an unsubstituted ${...}.
    # Claude Code creates it on first use, so it may not exist yet.
    case ${1:-} in
        /*) ;;
        *) folder_error ;;
    esac
    # shellcheck disable=SC2016
    case $1 in
        *'${'*) folder_error ;;
    esac
    mkdir -p "$1" 2>/dev/null || folder_error
    if ! valid_session "${2:-}"; then
        echo "Anki-Break could not tell which chat this is. Restart Claude Code and try again." >&2
        exit 2
    fi
    use_folder "$1"
}

still_working() {
    [ -f "$SESSIONS/$1" ] && [ "$(sed -n 1p "$SESSIONS/$1" 2>/dev/null)" = "$2" ]
}

# True when the session already started a newer turn than the given one.
newer_turn() {
    [ -f "$SESSIONS/$1" ] && [ "$(sed -n 1p "$SESSIONS/$1" 2>/dev/null)" != "$2" ]
}

working_count() {
    [ -d "$SESSIONS" ] || { echo 0; return 0; }
    find "$SESSIONS" -type f -mmin "-$ACTIVE_MINUTES" | wc -l | tr -d ' '
}

# True when a session other than $1 stopped in the last QUIET_SECONDS: it may
# be waiting for the user, so Anki should not cover it.
other_recent_stop() {
    [ -d "$STOPS" ] || return 1
    now=$(date +%s)
    for file in "$STOPS"/*; do
        [ -f "$file" ] || continue
        [ "${file##*/}" = "$1" ] && continue
        stamp=$(cat "$file" 2>/dev/null)
        case $stamp in
            '' | *[!0-9]*) continue ;;
        esac
        if [ $((now - stamp)) -lt "$QUIET_SECONDS" ]; then
            return 0
        fi
    done
    return 1
}

# Forget a launch once that Anki is gone, or when another Anki runs now.
forget_dead_launch() {
    [ -f "$DATA/launched" ] || return 0
    saved=$(cat "$DATA/launched" 2>/dev/null)
    current=$(anki_pid)
    if [ -z "$current" ] || { [ -n "$saved" ] && [ "$saved" != "$current" ]; }; then
        rm -f "$DATA/launched"
    fi
}

in_background() {
    # Run this script again with the given action, detached from the hook,
    # so the hook returns at once. Tests set ANKI_BREAK_SYNC to 1 (run it in
    # the foreground) or skip (do not run it).
    if [ "${ANKI_BREAK_SYNC:-}" = 1 ]; then
        sh "$SELF" "$@" </dev/null >/dev/null 2>&1
    elif [ "${ANKI_BREAK_SYNC:-}" = skip ]; then
        :
    else
        nohup sh "$SELF" "$@" </dev/null >/dev/null 2>&1 &
    fi
}

quit_anki() {
    # The standard quit event lets Anki save and sync as usual. Ignoring the
    # reply keeps a dialog in Anki from blocking us. The first time, macOS asks
    # whether the terminal app may control Anki (Automation).
    if error=$(osascript \
        -e 'ignoring application responses' \
        -e "tell application id \"$ANKI_ID\" to quit" \
        -e 'end ignoring' 2>&1 >/dev/null); then
        log "quit anki"
    else
        log "quit refused ($error). Allow Automation for Anki in System Settings"
    fi
}

bring_back() {
    host=$1
    if valid_bundle "$host" && [ "$host" != "$ANKI_ID" ] && app_running "$host"; then
        open -b "$host" 2>/dev/null && log "back to $host"
    fi
}

# ---------------------------------------------------------------- actions

do_start() {
    read_input
    sid=$(json_field session_id)
    sid=${sid:-default}
    if [ -z "$DATA" ] || disabled || ! is_mac || ! find_anki; then
        return 0
    fi
    host=$(host_app)
    if [ -z "$host" ]; then
        # No terminal or editor behind this Claude Code: a scripted run.
        return 0
    fi
    if is_paused "$sid"; then
        log "start $sid skipped, paused in this chat"
        return 0
    fi
    mkdir -p "$SESSIONS" "$STOPS" 2>/dev/null || return 0
    find "$SESSIONS" "$STOPS" -type f -mmin "+$CLEANUP_MINUTES" -exec rm -f {} + 2>/dev/null
    find "$PAUSED" -type f -mmin "+$PAUSE_CLEANUP" -exec rm -f {} + 2>/dev/null
    token="$(date +%s).$$"
    printf '%s\n' "$token" >"$SESSIONS/$sid"
    log "start $sid from $host (delay_seconds=$(delay_seconds) when_done=$(when_done))"
    trim_log
    in_background open-later "$sid" "$token"
}

do_open_later() {
    sid=$1
    token=$2
    find_anki || return 0
    host=$(host_app)
    [ -n "$host" ] || return 0
    sleep "$(delay_seconds)"
    still_working "$sid" "$token" || return 0
    if is_paused "$sid"; then
        return 0
    fi
    if other_recent_stop "$sid"; then
        log "another session just stopped, anki stays closed this turn"
        return 0
    fi
    if ! wait_until_idle; then
        log "user kept typing, anki stays closed this turn"
        return 0
    fi

    lock || return 0
    if ! still_working "$sid" "$token"; then
        unlock
        return 0
    fi
    front=$(front_app)
    if [ "$front" = "$ANKI_ID" ]; then
        unlock
        return 0
    fi
    if [ "$front" != "$host" ]; then
        log "user is in ${front:-another app}, not interrupting"
        unlock
        return 0
    fi
    forget_dead_launch
    launching=no
    if ! anki_running; then
        launching=yes
        : >"$DATA/launched"
        : >"$DATA/starting"
    fi
    unlock

    typing=no
    if [ "$launching" = yes ]; then
        # Launch without activating, so a slow start never takes the keyboard.
        if ! open -g -b "$ANKI_ID" 2>/dev/null; then
            log "could not open anki"
            rm -f "$DATA/starting" "$DATA/launched"
            return 0
        fi
        waited=0
        while [ "$waited" -lt "$LAUNCH_WAIT" ] && ! anki_running; do
            sleep 1
            waited=$((waited + 1))
        done
        anki_pid >"$DATA/launched"
        log "launched anki for $sid"
        if ! wait_until_idle; then
            typing=yes
        fi
    fi

    lock || return 0
    rm -f "$DATA/starting"
    if ! still_working "$sid" "$token"; then
        unlock
        log "claude finished while anki was starting"
        do_finish "$sid" "$token"
        return 0
    fi
    front=$(front_app)
    if [ "$typing" = yes ] || [ "$front" != "$host" ]; then
        unlock
        log "user is busy, anki stays in the background"
        return 0
    fi
    unlock
    open -b "$ANKI_ID" 2>/dev/null && log "opened anki for $sid"
}

do_stop() {
    read_input
    sid=$(json_field session_id)
    sid=${sid:-default}
    [ -n "$DATA" ] || return 0
    if [ "$(json_field hook_event_name)" = SessionEnd ]; then
        # A pause lasts until the chat ends.
        rm -f "$PAUSED/$sid" 2>/dev/null
    fi
    token=$(sed -n 1p "$SESSIONS/$sid" 2>/dev/null)
    rm -f "$SESSIONS/$sid" 2>/dev/null
    if [ -z "$token" ] || disabled || ! is_mac; then
        # Not a turn Anki-Break started, or a second stop for the same one.
        return 0
    fi
    mkdir -p "$STOPS" 2>/dev/null && date +%s >"$STOPS/$sid"
    in_background finish "$sid" "$token"
}

do_finish() {
    sid=$1
    token=$2
    find_anki || return 0
    host=$(host_app)
    if [ -f "$DATA/starting" ]; then
        # Anki is launching in the background. open-later finishes the job.
        return 0
    fi
    forget_dead_launch
    if [ "$(front_app)" != "$ANKI_ID" ] && [ ! -f "$DATA/launched" ]; then
        return 0
    fi
    # Moving focus while the user types sends keys to the wrong window:
    # grading cards, or answering a Claude dialog.
    idle=yes
    if ! wait_until_idle; then
        idle=no
        log "user kept typing, focus left alone"
    fi

    lock || return 0
    if [ -f "$DATA/starting" ]; then
        unlock
        return 0
    fi
    if newer_turn "$sid" "$token"; then
        unlock
        log "a new prompt started in $sid, anki stays"
        return 0
    fi
    others=$(working_count)
    front=$(front_app)
    quit=no
    if [ "$others" -eq 0 ] && [ -f "$DATA/launched" ]; then
        if [ "$(when_done)" = keep ]; then
            rm -f "$DATA/launched"
        elif [ "$idle" = yes ]; then
            # The flag stays until this Anki is gone, so a refused or slow
            # quit is tried again next time.
            quit=yes
        fi
    elif [ "$others" -gt 0 ]; then
        log "another session is still working, anki stays open"
    fi
    unlock

    if [ "$front" = "$ANKI_ID" ] && [ "$idle" = yes ]; then
        bring_back "$host"
    fi
    if [ "$quit" = yes ]; then
        quit_anki
    fi
}

do_pause() {
    check_skill_args "${1:-}" "${2:-}"
    sid=$2
    ends=0
    if [ -n "${3:-}" ]; then
        if ! minutes=$(duration_minutes "$3"); then
            echo "Give the pause in minutes or hours, for example 30m or 2h, at most 24h." >&2
            exit 2
        fi
        ends=$(($(date +%s) + minutes * 60))
    fi
    mkdir -p "$PAUSED" 2>/dev/null || exit 1
    echo "$ends" >"$PAUSED/$sid"
    # A turn that is already counting down does not open Anki either.
    rm -f "$SESSIONS/$sid" 2>/dev/null
    if [ "$ends" -eq 0 ]; then
        log "paused $sid until resumed"
        echo "Anki-Break is paused in this chat until you run /anki-break:resume or the chat ends."
    else
        log "paused $sid for $minutes minutes"
        echo "Anki-Break is paused in this chat for $minutes minutes, until $(clock "$ends")."
    fi
}

do_resume() {
    check_skill_args "${1:-}" "${2:-}"
    sid=$2
    if is_paused "$sid"; then
        rm -f "$PAUSED/$sid"
        log "resumed $sid"
        echo "Anki-Break is on again in this chat."
    else
        echo "Anki-Break was not paused in this chat."
    fi
}

do_doctor() {
    # Commands run through the Bash tool get no plugin settings or data path,
    # so the doctor skill passes the data folder as an argument and the
    # settings come from the last start line in the log.
    if [ -n "${1:-}" ] && [ -d "$1" ]; then
        use_folder "$1"
    fi
    echo "Anki-Break doctor"
    if is_mac; then
        echo "system: macOS (supported)"
    else
        echo "system: $(uname -s 2>/dev/null) (not supported, Anki-Break does nothing here)"
    fi
    if find_anki; then
        echo "anki installed: $ANKI_PATH ($ANKI_ID)"
    else
        echo "anki installed: no"
    fi
    if is_mac && [ -n "$ANKI_ID" ] && anki_running; then echo "anki running: yes"; else echo "anki running: no"; fi
    host=$(host_app)
    echo "host app: ${host:-none (Anki-Break only opens Anki for Claude Code started from a terminal or editor app)}"
    if is_mac; then
        echo "front app: $(front_app)"
        echo "idle ms: $(idle_ms)"
    fi
    if disabled; then echo "disabled: yes (ANKI_BREAK_DISABLE is set)"; else echo "disabled: no"; fi
    if [ -z "$DATA" ]; then
        echo "data folder: unknown (run this through /anki-break:doctor)"
        return 0
    fi
    echo "data folder: $DATA"
    last=$(grep ' start ' "$DATA/log" 2>/dev/null | tail -n 1)
    echo "last prompt: ${last:-no prompt seen yet}"
    if valid_session "${2:-}"; then
        if is_paused "$2"; then
            ends=$(cat "$PAUSED/$2")
            if [ "$ends" -eq 0 ]; then
                echo "this chat: paused until /anki-break:resume"
            else
                echo "this chat: paused until $(clock "$ends")"
            fi
        else
            echo "this chat: active"
        fi
    fi
    echo "working sessions: $(working_count)"
    if [ -f "$DATA/launched" ] && is_mac && [ -n "$ANKI_ID" ] && anki_running; then
        echo "anki opened by anki-break: yes"
    else
        echo "anki opened by anki-break: no"
    fi
    echo "last log lines:"
    if [ -f "$DATA/log" ]; then tail -n 10 "$DATA/log"; else echo "(none yet)"; fi
    echo "with when_done=quit, quitting Anki needs macOS Automation permission for your terminal app:"
    echo "System Settings, Privacy and Security, Automation."
}

case "${1:-}" in
    start) do_start ;;
    stop) do_stop ;;
    open-later) do_open_later "${2:-default}" "${3:-}" ;;
    finish) do_finish "${2:-default}" "${3:-}" ;;
    pause) do_pause "${2:-}" "${3:-}" "${4:-}" ;;
    resume) do_resume "${2:-}" "${3:-}" ;;
    doctor) do_doctor "${2:-}" "${3:-}" ;;
    *)
        echo "usage: anki-break.sh start|stop|pause|resume|doctor" >&2
        exit 2
        ;;
esac
exit 0
