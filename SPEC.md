# Anki-Break specification

The source of truth for what the plugin does. Update it when a decision changes.

## Purpose

Turn the time spent waiting for Claude into flashcard reviews. When Claude has been working for a while, Anki opens. When Claude is done, or needs the user, Anki goes away and the user is back in the app they started from.

## Platform

- macOS only. Claude Code must run on the same Mac as Anki desktop: the terminal, an IDE or the desktop app's Code tab.
- On any other system, and in cloud sessions, every hook exits at once and does nothing.
- iOS is out of scope: Claude Code does not run there, and iOS apps cannot open and close each other.

## Components

| Component | What it does |
|---|---|
| `hooks/hooks.json` | Calls `scripts/anki-break.sh` on the events below. Shell form, `timeout` 10 s. |
| `scripts/anki-break.sh` | POSIX `sh` script. Public actions `start`, `stop`, `doctor`. Background actions `open-later`, `finish`. |
| `skills/doctor/SKILL.md` | `/anki-break:doctor`, user-invoked only (`disable-model-invocation: true`). Runs `doctor` and explains the result. |
| `skills/pause/SKILL.md` | `/anki-break:pause [duration]`, user-invoked only. Pauses Anki-Break in the current chat. |
| `skills/resume/SKILL.md` | `/anki-break:resume`, user-invoked only. Ends the pause in the current chat. |

No agents or MCP servers.

## Events

| Event | Action | Why |
|---|---|---|
| `UserPromptSubmit` | `start` | Claude starts working |
| `Stop` | `stop` | Claude is done |
| `StopFailure` | `stop` | The turn ended on an API error |
| `PermissionRequest` | `stop` | A permission dialog appears |
| `Notification` matching `permission_prompt\|elicitation_dialog\|agent_needs_input\|idle_prompt` | `stop` | Claude needs the user. `idle_prompt` also cleans up after an Esc, which fires no `Stop`. |
| `PreToolUse` matching `AskUserQuestion\|ExitPlanMode` | `stop` | Claude is about to ask the user something |
| `SessionEnd` | `stop` | The session is gone |

`UserPromptSubmit` also fires for `claude -p`, `/loop` and scheduled runs. The host-app rules below keep Anki from opening for runs without a terminal or editor behind them, and when the user is in another app. `ANKI_BREAK_DISABLE=1` turns the plugin off entirely.

## Anki and the host app

Anki's bundle id changed over time: `net.ankiweb.dtop` up to 25.06, `net.ankiweb.launcher` for the 25.07 to 25.09 launcher builds, and `net.ankiweb.anki` from 26.05 (Briefcase builds). The script finds `Anki.app` (Applications folders, then Spotlight for any of the three ids) and reads the id from its `Info.plist`. The launcher builds start Anki as a second process, so focus handling there may be less reliable. That is untested.

The host app is the app Claude Code runs in, taken from `__CFBundleIdentifier`, which macOS passes to the shells of Terminal, iTerm, VS Code and other apps. Cron jobs, launchd jobs and SSH sessions do not have it, so Anki never opens for them.

## Behaviour

Every hook returns at once and prints nothing: stdout of a `UserPromptSubmit` hook would become part of Claude's context, and `SessionEnd` hooks get 1.5 seconds. Waiting, opening and quitting happen in a background process (output redirected). A `mkdir` lock serialises the steps that read and change state.

**Focus rule.** Focus only moves after at least 1.5 seconds without keyboard or mouse input (HIDIdleTime from `ioreg`, no permission needed). Moving focus while the user types sends the keys to the wrong window: grading cards in Anki, or answering a Claude dialog. If the user keeps typing for 60 seconds, Anki-Break leaves the focus alone.

**start**
1. Exit at once unless `CLAUDE_PLUGIN_DATA` is set, `ANKI_BREAK_DISABLE` is unset, the system is macOS, Anki is installed and there is a host app.
2. Write this session's working mark with a new turn token.
3. Start `open-later` in the background.

**open-later** (background)
1. Wait `delay_seconds`. Stop if the turn token has changed or is gone.
2. Stop if another session stopped in the last 60 seconds: it may be waiting for the user, and Anki should not cover it.
3. Wait for the focus rule. If the user keeps typing, skip this turn.
4. Under the lock: stop if the turn is over, if Anki is already in front, or if the frontmost app is not the host app (the user moved on, or the screen is locked). Forget a launch whose Anki is gone. If Anki is not running, note that Anki-Break launches it (`launched`) and that a launch is in progress (`starting`).
5. A running Anki is brought forward at once (`open -b`). A new one is launched without activating it (`open -g -b`), so a slow start never takes the keyboard. Wait up to 30 seconds for it to run, save its pid in `launched`, and wait for the focus rule again.
6. Under the lock: clear `starting`. If the turn ended during the launch, run `finish` for this turn. Otherwise, if the user is idle and still in the host app, bring Anki forward.

**stop**
1. Read this session's turn token, then remove the mark. Without a token (a turn Anki-Break did not start, or a second stop for the same turn) do nothing more.
2. Record the time of this stop in `stops/<session_id>`.
3. Start `finish` for this session and token in the background.

**finish** (background)
1. If a launch is in progress, leave everything to `open-later`.
2. Forget a launch whose Anki is gone. If Anki is not in front and Anki-Break did not launch it, there is nothing to do.
3. Wait for the focus rule.
4. Under the lock: stop if a launch started meanwhile, or if this session already started a newer turn (a queued prompt). If no other session is working (marks younger than 2 hours) and Anki-Break launched Anki, plan to quit it when `when_done` is `quit` and the user is idle. With `keep`, forget the launch. If another session is still working, Anki stays open.
5. After the lock: if Anki is in front and the user is idle, bring the host app back, if it is still running. Then send the quit.

The `launched` flag stays until that Anki process is gone, so a refused or slow quit is tried again on the next turn.

Anki that the user opened themselves is never quit, only sent to the back.

**pause** (from `/anki-break:pause`, which passes the data folder and the session id, because commands run through the Bash tool get no plugin variables)
1. Refuse with a message on stderr and exit code 2 when the folder does not exist, the session id is not 1 to 128 letters, digits, `_` or `-` (for example a literal `${CLAUDE_SESSION_ID}`), or the duration is not `30`, `30m` or `2h` style, between 1 minute and 24 hours.
2. Write `paused/<session_id>`: the end time in epoch seconds, or 0 for "until resumed".
3. Remove this session's working mark, so a turn that is already counting down does not open Anki.
4. Print one line saying how long the pause lasts.

A paused session's `start` does nothing, and `open-later` stops when it finds the pause. A timed pause ends by itself. A pause also ends when the chat ends (`SessionEnd`).

**resume** (same arguments): remove the pause file and say whether the chat was paused.

**doctor** (takes the data folder and, from the skill, the session id as arguments, because commands run through the Bash tool get no plugin variables)
Prints the system, whether Anki is installed and running, the settings logged at the last prompt, whether the current chat is paused, the working sessions, the last log lines and how to grant the Automation permission. Changes nothing.

## Settings (`userConfig`)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `delay_seconds` | number, 0 to 600 | 10 | How long Claude must be working before Anki opens. Short answers then never open Anki. |
| `when_done` | string | `keep` | `keep`: switch back to the host app and leave Anki running in the background, so it opens at once next time, with no cold start or sync each turn. `quit`: also close Anki, if Anki-Break opened it. |

The script reads them from `CLAUDE_PLUGIN_OPTION_DELAY_SECONDS` and `CLAUDE_PLUGIN_OPTION_WHEN_DONE`, validates them and falls back to the defaults on anything else. No `options` list, per the directory rules. `ANKI_BREAK_DISABLE=1` in the environment turns the plugin off for that Claude Code process.

## State

All state lives in `${CLAUDE_PLUGIN_DATA}`. Without it, the hooks do nothing.

- `sessions/<session_id>`: the turn token while that session is working
- `stops/<session_id>`: the time of that session's last stop
- `paused/<session_id>`: the end of that session's pause in epoch seconds, or 0 until resumed
- `launched`: present while an Anki that Anki-Break opened may still run, holds its pid
- `starting`: present while a launch is in progress
- `lock/pid`: the lock directory and its owner's pid
- `log`: one line per action, trimmed to the last 200 lines when it passes 400

Working marks older than 2 hours are ignored. Files in `sessions/` and `stops/` older than 24 hours are deleted on each `start`. A pause file is deleted when its time is up, when the chat ends, on resume, or after 7 days for a chat that never ended. The lock is broken only when its owner process is gone (or never wrote its pid), and a waiter gives up after two minutes. Nothing is written anywhere else.

## macOS commands used

- `open -g -b <id>`: launch Anki without activating it. `open -b <id>`: bring Anki or the host app forward.
- `defaults read <Anki.app>/Contents/Info CFBundleIdentifier`: Anki's bundle id.
- `lsappinfo`: frontmost app, whether an app is running, Anki's pid. No permission needed.
- `ioreg -c IOHIDSystem`: time since the last input. No permission needed.
- `mdfind`: find Anki outside the Applications folders.
- `osascript`: only to quit Anki when `when_done` is `quit`, with the standard quit event and without waiting for a reply. macOS asks once per host app (Terminal, iTerm, VS Code ...) for Automation permission. When denied, Anki stays open in the background, the host app still comes back, and the log records the error.

## Non-goals

- Reopening Anki after the user answers a permission prompt mid-turn. It reopens on the next prompt.
- Showing cards inside Claude Code (other plugins do that through AnkiConnect).
- Windows and Linux.

## Name

"Anki" is a trademark of Ankitects. The README says the plugin is not affiliated with Anki, and the icon is original.

## Tests

`tests/run.sh` runs every action against stub `uname`, `defaults`, `open`, `osascript`, `lsappinfo`, `ioreg`, `sleep` and `mdfind` commands, including one run through the real detached background path, and checks the calls made and the state left behind. It runs under `sh`, `dash` and `bash --posix`, and on macOS in CI. Releases are also checked by hand on a real Mac (see CONTRIBUTING.md).
