#!/bin/sh
# Tests for scripts/anki-break.sh.
#
#   sh tests/run.sh        (also: dash tests/run.sh, bash --posix tests/run.sh)
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
ANKI=net.ankiweb.dtop
TERM_APP=com.apple.Terminal

# ---------------------------------------------------------------- stubs
# $STUB/front          bundle id of the frontmost app
# $STUB/anki_running   exists while Anki runs; $STUB/anki_pid holds its pid
# $STUB/not_running    bundle ids of apps that are not running
# $STUB/front_pending  slow start: polls left before Anki reaches the front

mkdir -p "$WORK/bin"

cat >"$WORK/bin/uname" <<'EOF'
#!/bin/sh
echo "${STUB_UNAME:-Darwin}"
EOF

cat >"$WORK/bin/open" <<'EOF'
#!/bin/sh
echo "open $*" >>"$STUB/calls"
if [ "${STUB_OPEN_FAIL:-}" = 1 ]; then exit 1; fi
if [ "$1" = -b ]; then
    if [ "$2" = net.ankiweb.dtop ]; then
        : >"$STUB/anki_running"
        if [ "${STUB_SLOW_START:-}" = 1 ]; then
            echo 3 >"$STUB/front_pending"
            exit 0
        fi
    fi
    echo "$2" >"$STUB/front"
fi
exit 0
EOF

cat >"$WORK/bin/osascript" <<'EOF'
#!/bin/sh
echo "osascript quit" >>"$STUB/calls"
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
    if [ "$id" = net.ankiweb.dtop ]; then
        if [ -f "$STUB/anki_running" ]; then echo "ASN:0x0-0x2002:"; else echo "[ NULL ]"; fi
    elif ! grep -qxF "$id" "$STUB/not_running" 2>/dev/null; then
        echo "ASN:0x0-0x3003:"
    fi
elif [ "$3" = pid ]; then
    echo "\"pid\"=$(cat "$STUB/anki_pid")"
else
    if [ -f "$STUB/front_pending" ]; then
        left=$(cat "$STUB/front_pending")
        if [ "$left" -le 0 ]; then
            rm -f "$STUB/front_pending"
            echo net.ankiweb.dtop >"$STUB/front"
        else
            echo $((left - 1)) >"$STUB/front_pending"
        fi
    fi
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
# Simulates Claude finishing while Anki is still starting.
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
    mkdir -p "$STUB" "$DATA" "$WORK/apps/Anki.app"
    : >"$STUB/calls"
    echo "$TERM_APP" >"$STUB/front"
    echo 4242 >"$STUB/anki_pid"
    unset STUB_UNAME STUB_OPEN_FAIL STUB_QUIT_FAIL STUB_SLOW_START STUB_END_TURN_DURING_WAIT STUB_SID STUB_IDLE_MS
    unset ANKI_BREAK_DISABLE CLAUDE_PLUGIN_OPTION_DELAY_SECONDS CLAUDE_PLUGIN_OPTION_WHEN_DONE
    CLAUDE_PLUGIN_DATA=$DATA
    ANKI_BREAK_APP_DIR="$WORK/apps"
    ANKI_BREAK_SYNC=1
    export CLAUDE_PLUGIN_DATA ANKI_BREAK_APP_DIR ANKI_BREAK_SYNC
}

# hook <action> <session_id>: run an action the way Claude Code does.
hook() {
    printf '{"session_id":"%s","hook_event_name":"Test"}' "$2" |
        $TEST_SHELL "$SCRIPT" "$1" >"$WORK/stdout" 2>"$WORK/stderr"
}

# open_later <session_id>: run the background step by hand (ANKI_BREAK_SYNC=skip).
open_later() {
    $TEST_SHELL "$SCRIPT" open-later "$1" "$(sed -n 1p "$DATA/sessions/$1")" </dev/null >/dev/null 2>&1
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
no_calls() {
    check
    [ ! -s "$STUB/calls" ] || fail "expected no calls, got: $(tr '\n' ';' <"$STUB/calls")"
}
has_file() {
    check
    [ -f "$1" ] || fail "expected file $1"
}
no_file() {
    check
    [ ! -e "$1" ] || fail "unexpected file $1"
}
content() {
    check
    [ "$(cat "$1" 2>/dev/null)" = "$2" ] || fail "expected '$2' in $1, got '$(cat "$1" 2>/dev/null)'"
}
host_of() {
    check
    [ "$(sed -n 2p "$DATA/sessions/$1" 2>/dev/null)" = "$2" ] || fail "expected host '$2' for $1"
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

# ---------------------------------------------------------------- tests

CURRENT="opens Anki after the delay and prints nothing"
reset
hook start s1
quiet
called "sleep 15"
called "open -b $ANKI"
content "$DATA/launched" 4242
host_of s1 "$TERM_APP"
no_file "$DATA/starting"
no_file "$DATA/lock"

CURRENT="stop quits the Anki it opened and brings the terminal back"
hook stop s1
quiet
called "osascript quit"
called "open -b $TERM_APP"
no_file "$DATA/launched"
no_file "$DATA/sessions/s1"
no_file "$DATA/lock"

CURRENT="a turn shorter than the delay never opens Anki"
reset
ANKI_BREAK_SYNC=skip hook start s1
token=$(sed -n 1p "$DATA/sessions/s1")
hook stop s1
$TEST_SHELL "$SCRIPT" open-later s1 "$token" </dev/null >/dev/null 2>&1
not_called "open -b $ANKI"
not_called "osascript quit"

CURRENT="a new prompt replaces the old turn"
reset
ANKI_BREAK_SYNC=skip hook start s1
old=$(sed -n 1p "$DATA/sessions/s1")
ANKI_BREAK_SYNC=skip hook start s1
$TEST_SHELL "$SCRIPT" open-later s1 "$old" </dev/null >/dev/null 2>&1
not_called "open -b $ANKI"

CURRENT="no interruption when the user moved to another app"
reset
ANKI_BREAK_SYNC=skip hook start s1
echo com.google.Chrome >"$STUB/front"
open_later s1
not_called "open -b $ANKI"
log_has "user is in com.google.Chrome, not interrupting"

CURRENT="no opening while the user is typing"
reset
STUB_IDLE_MS=100
export STUB_IDLE_MS
hook start s1
not_called "open -b $ANKI"
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

CURRENT="no opening on the lock screen"
reset
ANKI_BREAK_SYNC=skip hook start s1
echo com.apple.loginwindow >"$STUB/front"
open_later s1
not_called "open -b $ANKI"

CURRENT="Anki the user opened is never quit, only sent to the back"
reset
: >"$STUB/anki_running"
hook start s1
called "open -b $ANKI"
no_file "$DATA/launched"
hook stop s1
not_called "osascript quit"
called "open -b $TERM_APP"

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
host_of s1 ""

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
called "open -b $TERM_APP"

CURRENT="Claude finishes while Anki is still starting"
reset
STUB_SLOW_START=1
STUB_END_TURN_DURING_WAIT=1
STUB_SID=s1
export STUB_SLOW_START STUB_END_TURN_DURING_WAIT STUB_SID
hook start s1
called "open -b $ANKI"
called "sleep 1"
called "osascript quit"
called "open -b $TERM_APP"
no_file "$DATA/starting"
no_file "$DATA/launched"
no_file "$DATA/lock"
log_has "claude finished while anki was starting"

CURRENT="a stop during the launch leaves the closing to open-later"
reset
: >"$DATA/starting"
: >"$DATA/launched"
: >"$STUB/anki_running"
echo "$ANKI" >"$STUB/front"
hook stop s1
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

CURRENT="Automation permission refused: the terminal still comes back"
reset
STUB_QUIT_FAIL=1
export STUB_QUIT_FAIL
hook start s1
hook stop s1
called "osascript quit"
called "open -b $TERM_APP"
log_has "quit refused (execution error: Not authorized"

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
no_file "$DATA/sessions/s1"

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
for pair in "abc:15" "0:0" "45:45" "12.5:12" "9999:600" "99999999999999:15" "-5:15" '${user_config.delay_seconds}:15'; do
    reset
    CLAUDE_PLUGIN_OPTION_DELAY_SECONDS=${pair%:*}
    export CLAUDE_PLUGIN_OPTION_DELAY_SECONDS
    hook start s1
    called "sleep ${pair##*:}"
done

CURRENT="when_done setting is validated"
for value in "KEEP" " keep "; do
    reset
    CLAUDE_PLUGIN_OPTION_WHEN_DONE=$value
    export CLAUDE_PLUGIN_OPTION_WHEN_DONE
    hook start s1
    hook stop s1
    not_called "osascript quit"
done
# shellcheck disable=SC2016
for value in "" "close" '${user_config.when_done}'; do
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

CURRENT="a stale lock does not block forever"
reset
mkdir -p "$DATA/lock"
hook start s1
called "open -b $ANKI"
no_file "$DATA/lock"

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

CURRENT="doctor reports and changes nothing"
reset
CLAUDE_PLUGIN_OPTION_DELAY_SECONDS=abc
export CLAUDE_PLUGIN_OPTION_DELAY_SECONDS
hook start s1
hook stop s1
unset CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_OPTION_DELAY_SECONDS
: >"$STUB/calls"
$TEST_SHELL "$SCRIPT" doctor "$DATA" >"$WORK/stdout" 2>&1
check
grep -q "system: macOS (supported)" "$WORK/stdout" || fail "doctor system line"
check
grep -q "last prompt: .*delay_seconds=15 when_done=quit" "$WORK/stdout" || fail "doctor settings line"
check
grep -q "anki installed: $WORK/apps/Anki.app" "$WORK/stdout" || fail "doctor anki line"
check
grep -q "Automation" "$WORK/stdout" || fail "doctor permission hint"
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
