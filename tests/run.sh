#!/bin/sh
# Tests for scripts/anki-break.sh.
#
#   sh tests/run.sh
#   TEST_SHELL=dash dash tests/run.sh
#   TEST_SHELL="bash --posix" bash --posix tests/run.sh
#
# Every macOS command the script uses is replaced by a stub that records its
# calls in $STUB/calls, so the tests run anywhere. TEST_SHELL picks the shell
# that runs the script itself (default: sh). It may hold options, such as
# "bash --posix", so it is expanded unquoted on purpose.
# shellcheck disable=SC2086

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/anki-break.sh"
TEST_SHELL=${TEST_SHELL:-sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/anki-break-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
TESTS=0
FAILS=0
ANKI=net.ankiweb.anki
TERM_APP=com.apple.Terminal

# ---------------------------------------------------------------- stubs
# $STUB/front          bundle id of the frontmost app
# $STUB/anki_running   exists while Anki runs; $STUB/anki_pid holds its pid
# $STUB/anki_starting  slow start: polls left before Anki counts as running
# $STUB/not_running    bundle ids of other apps that are not running
# STUB_ANKI_ID         Anki's bundle id (default net.ankiweb.anki)

mkdir -p "$WORK/bin"

cat >"$WORK/bin/uname" <<'EOF'
#!/bin/sh
echo "${STUB_UNAME:-Darwin}"
EOF

cat >"$WORK/bin/defaults" <<'EOF'
#!/bin/sh
echo "${STUB_ANKI_ID:-net.ankiweb.anki}"
EOF

cat >"$WORK/bin/open" <<'EOF'
#!/bin/sh
echo "open $*" >>"$STUB/calls"
if [ "${STUB_OPEN_FAIL:-}" = 1 ]; then exit 1; fi
background=no
if [ "$1" = -g ]; then background=yes; shift; fi
if [ "$1" = -b ]; then
    if [ "$2" = "${STUB_ANKI_ID:-net.ankiweb.anki}" ] && [ ! -f "$STUB/anki_running" ]; then
        if [ "${STUB_SLOW_START:-}" = 1 ]; then
            echo 3 >"$STUB/anki_starting"
        else
            : >"$STUB/anki_running"
        fi
    fi
    if [ "$background" = no ]; then echo "$2" >"$STUB/front"; fi
fi
exit 0
EOF

cat >"$WORK/bin/osascript" <<'EOF'
#!/bin/sh
echo "osascript quit" >>"$STUB/calls"
echo "$*" >"$STUB/osascript_args"
if [ "${STUB_QUIT_FAIL:-}" = 1 ]; then
    echo "execution error: Not authorized to send Apple events to Anki. (-1743)" >&2
    exit 1
fi
rm -f "$STUB/anki_running"
exit 0
EOF

cat >"$WORK/bin/lsappinfo" <<'EOF'
#!/bin/sh
if [ "$1" = front ]; then
    echo "ASN:0x0-0x1001:"
elif [ "$1" = find ]; then
    id=${2#bundleid=}
    if [ "$id" = "${STUB_ANKI_ID:-net.ankiweb.anki}" ]; then
        if [ -f "$STUB/anki_starting" ]; then
            left=$(cat "$STUB/anki_starting")
            if [ "$left" -le 0 ]; then
                rm -f "$STUB/anki_starting"
                : >"$STUB/anki_running"
            else
                echo $((left - 1)) >"$STUB/anki_starting"
            fi
        fi
        if [ -f "$STUB/anki_running" ]; then echo "ASN:0x0-0x2002:"; else echo "[ NULL ]"; fi
    elif ! grep -qxF "$id" "$STUB/not_running" 2>/dev/null; then
        echo "ASN:0x0-0x3003:"
    fi
elif [ "$3" = pid ]; then
    echo "\"pid\"=$(cat "$STUB/anki_pid")"
else
    printf '"CFBundleIdentifier"="%s"\n' "$(cat "$STUB/front")"
fi
EOF

cat >"$WORK/bin/ioreg" <<'EOF'
#!/bin/sh
echo "    | |   \"HIDIdleTime\" = ${STUB_IDLE_MS:-5000}000000"
EOF

cat >"$WORK/bin/sleep" <<'EOF'
#!/bin/sh
echo "sleep $1" >>"$STUB/calls"
# Simulates Claude finishing while Anki is still launching.
if [ "$1" = 1 ] && [ "${STUB_END_TURN_DURING_WAIT:-}" = 1 ]; then
    rm -f "$CLAUDE_PLUGIN_DATA/sessions/$STUB_SID"
fi
EOF

cat >"$WORK/bin/mdfind" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod +x "$WORK/bin/"*

PATH="$WORK/bin:$PATH"
STUB="$WORK/stub"
DATA="$WORK/data"
export PATH STUB

reset() {
    rm -rf "$STUB" "$DATA" "$WORK/apps"
    mkdir -p "$STUB" "$DATA" "$WORK/apps/Anki.app/Contents"
    : >"$STUB/calls"
    echo "$TERM_APP" >"$STUB/front"
    echo 4242 >"$STUB/anki_pid"
    unset STUB_UNAME STUB_OPEN_FAIL STUB_QUIT_FAIL STUB_SLOW_START STUB_END_TURN_DURING_WAIT
    unset STUB_SID STUB_IDLE_MS STUB_ANKI_ID
    unset ANKI_BREAK_DISABLE CLAUDE_PLUGIN_OPTION_DELAY_SECONDS CLAUDE_PLUGIN_OPTION_WHEN_DONE
    CLAUDE_PLUGIN_DATA=$DATA
    ANKI_BREAK_APP_DIR="$WORK/apps"
    ANKI_BREAK_SYNC=1
    __CFBundleIdentifier=$TERM_APP
    # Most tests cover quitting. The default (keep) has its own tests below.
    CLAUDE_PLUGIN_OPTION_WHEN_DONE=quit
    export CLAUDE_PLUGIN_DATA ANKI_BREAK_APP_DIR ANKI_BREAK_SYNC __CFBundleIdentifier CLAUDE_PLUGIN_OPTION_WHEN_DONE
}

# hook <action> <session_id>: run an action the way Claude Code does.
hook() {
    printf '{"session_id":"%s","hook_event_name":"Test"}' "$2" |
        $TEST_SHELL "$SCRIPT" "$1" >"$WORK/stdout" 2>"$WORK/stderr"
}

# hook_event <action> <session_id> <event>: the same, with a given event name.
hook_event() {
    printf '{"session_id":"%s","hook_event_name":"%s"}' "$2" "$3" |
        $TEST_SHELL "$SCRIPT" "$1" >"$WORK/stdout" 2>"$WORK/stderr"
}

# skill <action> [args...]: run pause or resume the way their skills do.
skill() {
    action=$1
    shift
    $TEST_SHELL "$SCRIPT" "$action" "$@" >"$WORK/stdout" 2>"$WORK/stderr"
}

token_of() {
    sed -n 1p "$DATA/sessions/$1" 2>/dev/null
}

# open_later <session_id>: run the background step by hand (ANKI_BREAK_SYNC=skip).
open_later() {
    $TEST_SHELL "$SCRIPT" open-later "$1" "$(token_of "$1")" </dev/null >/dev/null 2>&1
}

# ---------------------------------------------------------------- checks

CURRENT=""
fail() {
    FAILS=$((FAILS + 1))
    echo "FAIL [$CURRENT] $*"
}
check() {
    TESTS=$((TESTS + 1))
}
called() {
    check
    grep -qxF -- "$1" "$STUB/calls" || fail "expected call: $1"
}
not_called() {
    check
    if grep -qxF -- "$1" "$STUB/calls"; then fail "unexpected call: $1"; fi
}
call_count() {
    check
    n=$(grep -cxF -- "$1" "$STUB/calls")
    [ "$n" -eq "$2" ] || fail "expected $2 x '$1', got $n"
}
no_calls() {
    check
    [ ! -s "$STUB/calls" ] || fail "expected no calls, got: $(tr '\n' ';' <"$STUB/calls")"
}
has_file() {
    check
    [ -e "$1" ] || fail "expected file $1"
}
no_file() {
    check
    [ ! -e "$1" ] || fail "unexpected file $1"
}
content() {
    check
    [ "$(cat "$1" 2>/dev/null)" = "$2" ] || fail "expected '$2' in $1, got '$(cat "$1" 2>/dev/null)'"
}
quiet() {
    check
    [ ! -s "$WORK/stdout" ] || fail "stdout not empty: $(cat "$WORK/stdout")"
    check
    [ ! -s "$WORK/stderr" ] || fail "stderr not empty: $(cat "$WORK/stderr")"
}
log_has() {
    check
    grep -qF -- "$1" "$DATA/log" 2>/dev/null || fail "log lacks: $1"
}
wait_for_call() {
    i=0
    while [ "$i" -lt 50 ] && ! grep -qxF -- "$1" "$STUB/calls"; do
        command -p sleep 0.1
        i=$((i + 1))
    done
    called "$1"
}

# ---------------------------------------------------------------- tests

CURRENT="launches Anki in the background, then brings it forward"
reset
hook start s1
quiet
called "sleep 10"
called "open -g -b $ANKI"
called "open -b $ANKI"
content "$DATA/launched" 4242
no_file "$DATA/starting"
no_file "$DATA/lock"

CURRENT="stop brings the terminal back and quits the Anki it opened"
hook stop s1
quiet
called "open -b $TERM_APP"
called "osascript quit"
check
grep -qF "tell application id \"$ANKI\" to quit" "$STUB/osascript_args" || fail "quit script names the wrong app"
check
grep -qF "ignoring application responses" "$STUB/osascript_args" || fail "quit script waits for a reply"
no_file "$DATA/sessions/s1"
no_file "$DATA/lock"
log_has "quit anki"

CURRENT="a second stop for the same turn does nothing"
hook stop s1
call_count "osascript quit" 1

CURRENT="older and launcher builds of Anki use their own bundle id"
for id in net.ankiweb.dtop net.ankiweb.launcher; do
    reset
    STUB_ANKI_ID=$id
    export STUB_ANKI_ID
    hook start s1
    called "open -g -b $id"
    hook stop s1
    check
    grep -qF "tell application id \"$id\" to quit" "$STUB/osascript_args" || fail "quit for $id"
done

CURRENT="a turn shorter than the delay never opens Anki"
reset
ANKI_BREAK_SYNC=skip hook start s1
token=$(token_of s1)
hook stop s1
$TEST_SHELL "$SCRIPT" open-later s1 "$token" </dev/null >/dev/null 2>&1
not_called "open -g -b $ANKI"

CURRENT="a new prompt replaces the old turn"
reset
ANKI_BREAK_SYNC=skip hook start s1
old=$(token_of s1)
ANKI_BREAK_SYNC=skip hook start s1
$TEST_SHELL "$SCRIPT" open-later s1 "$old" </dev/null >/dev/null 2>&1
not_called "open -g -b $ANKI"

CURRENT="a new prompt during finish keeps Anki"
reset
hook start s1
old=$(token_of s1)
ANKI_BREAK_SYNC=skip hook start s1
: >"$STUB/calls"
$TEST_SHELL "$SCRIPT" finish s1 "$old" </dev/null >/dev/null 2>&1
not_called "osascript quit"
not_called "open -b $TERM_APP"
log_has "a new prompt started in s1"

CURRENT="no host app (cron, launchd, SSH): never opens Anki"
reset
unset __CFBundleIdentifier
hook start s1
quiet
hook stop s1
no_calls
no_file "$DATA/sessions/s1"

CURRENT="no interruption when the user moved to another app"
reset
ANKI_BREAK_SYNC=skip hook start s1
echo com.google.Chrome >"$STUB/front"
open_later s1
not_called "open -g -b $ANKI"
log_has "user is in com.google.Chrome, not interrupting"

CURRENT="no opening on the lock screen"
reset
ANKI_BREAK_SYNC=skip hook start s1
echo com.apple.loginwindow >"$STUB/front"
open_later s1
not_called "open -g -b $ANKI"

CURRENT="no opening while the user is typing"
reset
STUB_IDLE_MS=100
export STUB_IDLE_MS
hook start s1
not_called "open -g -b $ANKI"
log_has "user kept typing"

CURRENT="no focus change while the user is typing in Anki"
reset
hook start s1
STUB_IDLE_MS=100
export STUB_IDLE_MS
hook stop s1
not_called "osascript quit"
not_called "open -b $TERM_APP"
has_file "$DATA/launched"
log_has "focus left alone"

CURRENT="another session that just stopped is not covered by Anki"
reset
ANKI_BREAK_SYNC=skip hook start s2
ANKI_BREAK_SYNC=skip hook stop s2
ANKI_BREAK_SYNC=skip hook start s1
open_later s1
not_called "open -g -b $ANKI"
log_has "another session just stopped"

CURRENT="Anki the user opened is brought forward, never quit"
reset
: >"$STUB/anki_running"
hook start s1
not_called "open -g -b $ANKI"
called "open -b $ANKI"
no_file "$DATA/launched"
hook stop s1
not_called "osascript quit"
called "open -b $TERM_APP"

CURRENT="by default Claude comes back and Anki keeps running"
reset
unset CLAUDE_PLUGIN_OPTION_WHEN_DONE
hook start s1
called "open -b $ANKI"
hook stop s1
not_called "osascript quit"
called "open -b $TERM_APP"
no_file "$DATA/launched"
log_has "when_done=keep"

CURRENT="when_done=keep leaves Anki running"
reset
CLAUDE_PLUGIN_OPTION_WHEN_DONE=keep
export CLAUDE_PLUGIN_OPTION_WHEN_DONE
hook start s1
hook stop s1
not_called "osascript quit"
called "open -b $TERM_APP"
no_file "$DATA/launched"

CURRENT="focus stays put when the user moved on after Anki opened"
reset
hook start s1
echo com.google.Chrome >"$STUB/front"
hook stop s1
called "osascript quit"
not_called "open -b $TERM_APP"

CURRENT="the host app is not relaunched if the user quit it"
reset
hook start s1
echo "$TERM_APP" >"$STUB/not_running"
hook stop s1
called "osascript quit"
not_called "open -b $TERM_APP"

CURRENT="Anki already in front: nothing to do"
reset
: >"$STUB/anki_running"
echo "$ANKI" >"$STUB/front"
hook start s1
not_called "open -b $ANKI"

CURRENT="two sessions: Anki stays open until both are done"
reset
hook start s1
echo "$TERM_APP" >"$STUB/front"
hook start s2
hook stop s1
not_called "osascript quit"
called "open -b $TERM_APP"
log_has "another session is still working"
: >"$STUB/calls"
echo "$ANKI" >"$STUB/front"
hook stop s2
called "osascript quit"

CURRENT="Claude finishes while Anki is still launching"
reset
STUB_SLOW_START=1
STUB_END_TURN_DURING_WAIT=1
STUB_SID=s1
export STUB_SLOW_START STUB_END_TURN_DURING_WAIT STUB_SID
hook start s1
called "open -g -b $ANKI"
called "sleep 1"
not_called "open -b $ANKI"
not_called "open -b $TERM_APP"
called "osascript quit"
no_file "$DATA/starting"
no_file "$DATA/lock"
log_has "claude finished while anki was starting"

CURRENT="another session's stop during a launch leaves it to open-later"
reset
: >"$DATA/starting"
: >"$DATA/launched"
: >"$STUB/anki_running"
mkdir -p "$DATA/sessions"
echo t2 >"$DATA/sessions/s2"
hook stop s2
not_called "osascript quit"
has_file "$DATA/launched"

CURRENT="the user quit Anki before Claude finished"
reset
hook start s1
rm -f "$STUB/anki_running"
echo "$TERM_APP" >"$STUB/front"
hook stop s1
not_called "osascript quit"
not_called "open -b $TERM_APP"
no_file "$DATA/launched"

CURRENT="an Anki the user reopened is not quit"
reset
hook start s1
echo 5555 >"$STUB/anki_pid"
hook stop s1
not_called "osascript quit"
called "open -b $TERM_APP"
no_file "$DATA/launched"

CURRENT="a refused quit is tried again next turn"
reset
STUB_QUIT_FAIL=1
export STUB_QUIT_FAIL
hook start s1
hook stop s1
called "osascript quit"
called "open -b $TERM_APP"
has_file "$DATA/launched"
log_has "quit refused (execution error: Not authorized"
unset STUB_QUIT_FAIL
echo "$TERM_APP" >"$STUB/front"
: >"$STUB/calls"
hook start s1
hook stop s1
called "osascript quit"

CURRENT="Anki cannot be opened"
reset
STUB_OPEN_FAIL=1
export STUB_OPEN_FAIL
hook start s1
no_file "$DATA/launched"
no_file "$DATA/starting"
log_has "could not open anki"

CURRENT="not macOS: does nothing"
reset
STUB_UNAME=Linux
export STUB_UNAME
hook start s1
quiet
hook stop s1
quiet
no_calls

CURRENT="ANKI_BREAK_DISABLE turns it off"
reset
ANKI_BREAK_DISABLE=1
export ANKI_BREAK_DISABLE
hook start s1
hook stop s1
no_calls

CURRENT="no data folder: does nothing"
reset
unset CLAUDE_PLUGIN_DATA
hook start s1
hook stop s1
no_calls
no_file "$DATA/sessions"

CURRENT="Anki not installed: does nothing"
reset
rm -rf "$WORK/apps/Anki.app"
hook start s1
no_calls
no_file "$DATA/sessions/s1"

CURRENT="delay setting is validated"
# A literal, unsubstituted ${user_config...} must fall back to the default.
# shellcheck disable=SC2016
for pair in "abc:10" "0:0" "45:45" "12.5:12" "9999:600" "99999999999999:10" "-5:10" '${user_config.delay_seconds}:10'; do
    reset
    CLAUDE_PLUGIN_OPTION_DELAY_SECONDS=${pair%:*}
    export CLAUDE_PLUGIN_OPTION_DELAY_SECONDS
    hook start s1
    called "sleep ${pair##*:}"
done

CURRENT="when_done setting is validated"
# shellcheck disable=SC2016
for value in "" "KEEP" " keep " "close" '${user_config.when_done}'; do
    reset
    CLAUDE_PLUGIN_OPTION_WHEN_DONE=$value
    export CLAUDE_PLUGIN_OPTION_WHEN_DONE
    hook start s1
    hook stop s1
    not_called "osascript quit"
done
for value in "quit" "QUIT" " Quit "; do
    reset
    CLAUDE_PLUGIN_OPTION_WHEN_DONE=$value
    export CLAUDE_PLUGIN_OPTION_WHEN_DONE
    hook start s1
    hook stop s1
    called "osascript quit"
done

CURRENT="stale working marks are ignored and cleaned up"
reset
mkdir -p "$DATA/sessions"
echo old >"$DATA/sessions/crashed"
touch -t 202001010000 "$DATA/sessions/crashed"
hook start s1
no_file "$DATA/sessions/crashed"
echo old >"$DATA/sessions/stale"
touch -t "$(date -d '-3 hours' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)" "$DATA/sessions/stale"
hook stop s1
called "osascript quit"

CURRENT="a lock whose owner died is broken"
reset
mkdir -p "$DATA/lock"
echo 999999 >"$DATA/lock/pid"
hook start s1
called "open -g -b $ANKI"
no_file "$DATA/lock"

CURRENT="a lock without an owner is broken"
reset
mkdir -p "$DATA/lock"
hook start s1
called "open -g -b $ANKI"
no_file "$DATA/lock"

CURRENT="a live lock is never broken"
reset
mkdir -p "$DATA/lock"
echo $$ >"$DATA/lock/pid"
hook start s1
not_called "open -g -b $ANKI"
log_has "lock busy"
content "$DATA/lock/pid" $$

CURRENT="session ids cannot escape the data folder"
reset
printf '{"session_id":"../../escape"}' | $TEST_SHELL "$SCRIPT" start >/dev/null 2>&1
no_file "$WORK/escape"
has_file "$DATA/sessions/default"

CURRENT="no stdin at all still works"
reset
$TEST_SHELL "$SCRIPT" start </dev/null >"$WORK/stdout" 2>"$WORK/stderr"
quiet
has_file "$DATA/sessions/default"

CURRENT="the log is trimmed"
reset
i=0
while [ "$i" -lt 500 ]; do echo "old line $i"; i=$((i + 1)); done >"$DATA/log"
hook start s1
check
[ "$(wc -l <"$DATA/log" | tr -d ' ')" -le 210 ] || fail "log not trimmed"

CURRENT="the real background path works and the hook returns at once"
reset
unset ANKI_BREAK_SYNC
hook start s1
quiet
wait_for_call "open -b $ANKI"
hook stop s1
quiet
wait_for_call "osascript quit"

CURRENT="pause stops Anki opening in that chat only"
reset
skill pause "$DATA" s1
check
grep -q "paused in this chat until you run /anki-break:resume" "$WORK/stdout" || fail "pause message"
content "$DATA/paused/s1" 0
hook start s1
quiet
no_calls
no_file "$DATA/sessions/s1"
log_has "start s1 skipped, paused in this chat"
hook start s2
called "open -g -b $ANKI"

CURRENT="pause during a turn keeps that turn from opening Anki"
reset
ANKI_BREAK_SYNC=skip hook start s1
token=$(token_of s1)
skill pause "$DATA" s1
no_file "$DATA/sessions/s1"
$TEST_SHELL "$SCRIPT" open-later s1 "$token" </dev/null >/dev/null 2>&1
not_called "open -g -b $ANKI"

CURRENT="resume turns it back on"
reset
skill pause "$DATA" s1
skill resume "$DATA" s1
check
grep -q "on again in this chat" "$WORK/stdout" || fail "resume message"
no_file "$DATA/paused/s1"
hook start s1
called "open -g -b $ANKI"
skill resume "$DATA" s1
check
grep -q "was not paused" "$WORK/stdout" || fail "resume when not paused"

CURRENT="a timed pause ends by itself"
reset
skill pause "$DATA" s1 30m
check
grep -q "paused in this chat for 30 minutes, until [0-9][0-9]:[0-9][0-9]" "$WORK/stdout" || fail "timed pause message: $(cat "$WORK/stdout")"
hook start s1
not_called "open -g -b $ANKI"
echo 1 >"$DATA/paused/s1"
hook start s1
called "open -g -b $ANKI"
no_file "$DATA/paused/s1"

CURRENT="pause durations are validated"
for pair in "30:30" "30m:30" "2h:120" "08h:480" "1:1" "1440:1440" "24h:1440" " 45M :45"; do
    reset
    skill pause "$DATA" s1 "${pair%:*}"
    check
    grep -q "for ${pair##*:} minutes" "$WORK/stdout" || fail "duration ${pair%:*}: $(cat "$WORK/stdout" "$WORK/stderr")"
done
for value in "0" "0m" "1441" "25h" "abc" "5d" "-5" "30 minutes" "1.5h"; do
    reset
    skill pause "$DATA" s1 "$value"
    status=$?
    check
    [ "$status" -eq 2 ] || fail "duration '$value' accepted"
    check
    grep -q "minutes or hours" "$WORK/stderr" || fail "duration '$value' message"
    no_file "$DATA/paused/s1"
done

CURRENT="pause refuses an unknown chat or folder"
reset
# shellcheck disable=SC2016
skill pause "$DATA" '${CLAUDE_SESSION_ID}'
status=$?
check
[ "$status" -eq 2 ] || fail "literal session id accepted"
check
grep -q "could not tell which chat" "$WORK/stderr" || fail "session id message"
# shellcheck disable=SC2016
for folder in '${CLAUDE_PLUGIN_DATA}' "relative/folder" ""; do
    skill pause "$folder" s1
    status=$?
    check
    [ "$status" -eq 2 ] || fail "folder '$folder' accepted"
    check
    grep -q "data folder" "$WORK/stderr" || fail "folder message for '$folder'"
done
skill pause "$WORK/fresh/data" s1
has_file "$WORK/fresh/data/paused/s1"
rm -rf "$WORK/fresh"
skill resume "$DATA" "../escape"
status=$?
check
[ "$status" -eq 2 ] || fail "path in session id accepted"

CURRENT="a pause ends with the chat"
reset
skill pause "$DATA" s1
hook_event stop s1 SessionEnd
no_file "$DATA/paused/s1"
skill pause "$DATA" s1
hook_event stop s1 Stop
has_file "$DATA/paused/s1"

CURRENT="doctor shows whether this chat is paused"
reset
skill pause "$DATA" s1
$TEST_SHELL "$SCRIPT" doctor "$DATA" s1 >"$WORK/stdout" 2>&1
check
grep -q "this chat: paused until /anki-break:resume" "$WORK/stdout" || fail "doctor paused line"
$TEST_SHELL "$SCRIPT" doctor "$DATA" s2 >"$WORK/stdout" 2>&1
check
grep -q "this chat: active" "$WORK/stdout" || fail "doctor active line"

CURRENT="doctor reports and changes nothing"
reset
CLAUDE_PLUGIN_OPTION_DELAY_SECONDS=abc
export CLAUDE_PLUGIN_OPTION_DELAY_SECONDS
hook start s1
hook stop s1
unset CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_OPTION_DELAY_SECONDS
: >"$STUB/calls"
$TEST_SHELL "$SCRIPT" doctor "$DATA" >"$WORK/stdout" 2>&1
for line in "system: macOS (supported)" "anki installed: $WORK/apps/Anki.app ($ANKI)" \
    "host app: $TERM_APP" "idle ms: 5000" "anki opened by anki-break: no" "Automation"; do
    check
    grep -qF "$line" "$WORK/stdout" || fail "doctor lacks: $line"
done
check
grep -q "last prompt: .*delay_seconds=10 when_done=quit" "$WORK/stdout" || fail "doctor settings line"
not_called "open -b $ANKI"
not_called "osascript quit"
STUB_UNAME=Linux
export STUB_UNAME
$TEST_SHELL "$SCRIPT" doctor >"$WORK/stdout" 2>&1
check
grep -q "not supported" "$WORK/stdout" || fail "doctor on Linux"

CURRENT="unknown action fails with usage on stderr"
reset
$TEST_SHELL "$SCRIPT" bogus >"$WORK/stdout" 2>"$WORK/stderr"
status=$?
check
[ "$status" -eq 2 ] || fail "exit status $status"
check
grep -q usage "$WORK/stderr" || fail "no usage on stderr"

# ---------------------------------------------------------------- result

if [ "$FAILS" -eq 0 ]; then
    echo "ok: $TESTS checks passed ($TEST_SHELL)"
    exit 0
fi
echo "$FAILS of $TESTS checks failed ($TEST_SHELL)"
exit 1
