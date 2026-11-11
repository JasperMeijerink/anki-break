#!/bin/sh
# Anki-Break: open Anki while Claude Code works, close it when Claude is done.
#
#   anki-break.sh start            UserPromptSubmit: mark the session as working
#   anki-break.sh stop             Stop and friends: unmark it, send Anki away
#   anki-break.sh doctor [folder]  print a diagnosis, change nothing
#
# Internal actions, run in the background: open-later, finish.
# Hook events pass JSON on stdin. See SPEC.md for the full behaviour.

ANKI_ID="net.ankiweb.dtop"
DEFAULT_DELAY=15
MAX_DELAY=600
IDLE_MS=1500           # focus only moves after this much keyboard and mouse quiet
IDLE_WAIT=60           # seconds to wait for that quiet before giving up
LAUNCH_WAIT=20         # seconds to wait for Anki to come to the front
ACTIVE_MINUTES=120     # working marks older than this are ignored
CLEANUP_MINUTES=1440   # session files older than this are deleted
LOG_LINES=200

SELF=$0
DATA=${CLAUDE_PLUGIN_DATA:-}
SESSIONS="$DATA/sessions"

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
    if [ "$value" = keep ]; then
        echo keep
    else
        echo quit
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

anki_path() {
    # ANKI_BREAK_APP_DIR replaces the standard folders. It exists for the tests.
    if [ -n "${ANKI_BREAK_APP_DIR:-}" ]; then
        set -- "$ANKI_BREAK_APP_DIR"
    else
        set -- /Applications "$HOME/Applications"
    fi
    for dir in "$@"; do
        if [ -d "$dir/Anki.app" ]; then
            printf '%s\n' "$dir/Anki.app"
            return 0
        fi
    done
    # Spotlight finds Anki installed anywhere else.
    mdfind "kMDItemCFBundleIdentifier == '$ANKI_ID'" 2>/dev/null | head -n 1
}

valid_bundle() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$'
}

# lsappinfo needs no permission. It prints "[ NULL ]" for missing values.
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
    lsappinfo info -only pid "$asn" 2>/dev/null | sed -n 's/.*"pid"[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1
}

front_app() {
    asn=$(lsappinfo front 2>/dev/null | grep -v NULL)
    [ -n "$asn" ] || return 0
    lsappinfo info -only bundleid "$asn" 2>/dev/null |
        sed -n 's/.*"CFBundleIdentifier"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1
}

idle_ms() {
    # Time since the last keyboard or mouse input. Needs no permission.
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

lock() {
    tries=0
    while ! mkdir "$DATA/lock" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 15 ]; then
            # A lock that old belongs to a process that died.
            rmdir "$DATA/lock" 2>/dev/null
            tries=0
        fi
        sleep 1
    done
}

unlock() {
    rmdir "$DATA/lock" 2>/dev/null
}

session_from_stdin() {
    input=""
    if [ ! -t 0 ]; then
        input=$(cat)
    fi
    sid=$(printf '%s\n' "$input" |
        sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]\{1,128\}\)".*/\1/p' |
        head -n 1)
    printf '%s\n' "${sid:-default}"
}

# A working mark holds the turn token on line 1 and the host app on line 2.
still_working() {
    [ -f "$SESSIONS/$1" ] && [ "$(sed -n 1p "$SESSIONS/$1" 2>/dev/null)" = "$2" ]
}

working_count() {
    [ -d "$SESSIONS" ] || { echo 0; return 0; }
    find "$SESSIONS" -type f -mmin "-$ACTIVE_MINUTES" | wc -l | tr -d ' '
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
    sid=$(session_from_stdin)
    if [ -z "$DATA" ] || disabled || ! is_mac || [ -z "$(anki_path)" ]; then
        return 0
    fi
    mkdir -p "$SESSIONS" 2>/dev/null || return 0
    find "$SESSIONS" -type f -mmin "+$CLEANUP_MINUTES" -exec rm -f {} + 2>/dev/null
    token="$(date +%s).$$"
    host=$(front_app)
    if ! valid_bundle "$host" || [ "$host" = "$ANKI_ID" ] || [ "$host" = com.apple.loginwindow ]; then
        host=""
    fi
    printf '%s\n%s\n' "$token" "$host" >"$SESSIONS/$sid"
    log "start $sid from ${host:-unknown app} (delay_seconds=$(delay_seconds) when_done=$(when_done))"
    trim_log
    in_background open-later "$sid" "$token"
}

do_open_later() {
    sid=$1
    token=$2
    sleep "$(delay_seconds)"
    still_working "$sid" "$token" || return 0
    if ! wait_until_idle; then
        log "user kept typing, anki stays closed this turn"
        return 0
    fi
    host=$(sed -n 2p "$SESSIONS/$sid" 2>/dev/null)

    lock
    if ! still_working "$sid" "$token"; then
        unlock
        return 0
    fi
    front=$(front_app)
    if [ "$front" = "$ANKI_ID" ] || [ "$front" = com.apple.loginwindow ]; then
        unlock
        return 0
    fi
    if [ -n "$host" ] && [ "$front" != "$host" ]; then
        log "user is in $front, not interrupting"
        unlock
        return 0
    fi
    if ! anki_running; then
        : >"$DATA/launched"
    fi
    : >"$DATA/starting"
    unlock

    if ! open -b "$ANKI_ID" 2>/dev/null; then
        log "could not open anki"
        rm -f "$DATA/starting"
        if [ ! -s "$DATA/launched" ]; then rm -f "$DATA/launched"; fi
        return 0
    fi
    log "opened anki for $sid"

    # Anki can take a few seconds to show its window.
    waited=0
    while [ "$waited" -lt "$LAUNCH_WAIT" ] && [ "$(front_app)" != "$ANKI_ID" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [ -f "$DATA/launched" ] && [ ! -s "$DATA/launched" ]; then
        anki_pid >"$DATA/launched"
    fi

    lock
    rm -f "$DATA/starting"
    if still_working "$sid" "$token"; then
        unlock
        return 0
    fi
    unlock
    # Claude finished while Anki was starting: send it away again.
    log "claude finished while anki was starting"
    do_finish "$host"
}

do_stop() {
    sid=$(session_from_stdin)
    [ -n "$DATA" ] || return 0
    host=$(sed -n 2p "$SESSIONS/$sid" 2>/dev/null)
    rm -f "$SESSIONS/$sid" 2>/dev/null
    if disabled || ! is_mac; then
        return 0
    fi
    in_background finish "$host"
}

do_finish() {
    host=$1
    if [ -f "$DATA/starting" ]; then
        # open-later is still waiting for Anki and finishes the job then.
        return 0
    fi
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

    lock
    others=$(working_count)
    front=$(front_app)
    if [ "$others" -eq 0 ] && [ -f "$DATA/launched" ]; then
        saved=$(cat "$DATA/launched" 2>/dev/null)
        current=$(anki_pid)
        if [ -z "$current" ] || [ "$(when_done)" = keep ]; then
            # The user quit Anki already, or wants it to stay.
            rm -f "$DATA/launched"
        elif [ "$idle" = yes ]; then
            # Only quit the Anki we opened, not one the user reopened since.
            if [ -z "$saved" ] || [ "$saved" = "$current" ]; then
                quit_anki
            fi
            rm -f "$DATA/launched"
        fi
        # Still typing: keep the flag, so a later stop can quit it.
    elif [ "$others" -gt 0 ]; then
        log "another session is still working, anki stays open"
    fi
    if [ "$front" = "$ANKI_ID" ] && [ "$idle" = yes ]; then
        bring_back "$host"
    fi
    unlock
}

do_doctor() {
    # Commands run through the Bash tool get no plugin settings or data path,
    # so the doctor skill passes the data folder as an argument and the
    # settings come from the last start line in the log.
    if [ -n "${1:-}" ] && [ -d "$1" ]; then
        DATA=$1
        SESSIONS="$DATA/sessions"
    fi
    echo "Anki-Break doctor"
    if is_mac; then
        echo "system: macOS (supported)"
    else
        echo "system: $(uname -s 2>/dev/null) (not supported, Anki-Break does nothing here)"
    fi
    path=$(anki_path 2>/dev/null)
    echo "anki installed: ${path:-no}"
    if is_mac && anki_running; then echo "anki running: yes"; else echo "anki running: no"; fi
    if disabled; then echo "disabled: yes (ANKI_BREAK_DISABLE is set)"; else echo "disabled: no"; fi
    if [ -z "$DATA" ]; then
        echo "data folder: unknown (run this through /anki-break:doctor)"
        return 0
    fi
    echo "data folder: $DATA"
    last=$(grep ' start ' "$DATA/log" 2>/dev/null | tail -n 1)
    echo "last prompt: ${last:-no prompt seen yet}"
    echo "working sessions: $(working_count)"
    if [ -f "$DATA/launched" ]; then echo "anki opened by anki-break: yes"; else echo "anki opened by anki-break: no"; fi
    echo "last log lines:"
    if [ -f "$DATA/log" ]; then tail -n 10 "$DATA/log"; else echo "(none yet)"; fi
    echo "quitting Anki needs macOS Automation permission for your terminal app:"
    echo "System Settings, Privacy and Security, Automation."
}

case "${1:-}" in
    start) do_start ;;
    stop) do_stop ;;
    open-later) do_open_later "${2:-default}" "${3:-}" ;;
    finish) do_finish "${2:-}" ;;
    doctor) do_doctor "${2:-}" ;;
    *)
        echo "usage: anki-break.sh start|stop|doctor" >&2
        exit 2
        ;;
esac
exit 0
