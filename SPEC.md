# Anki-Break specification

The source of truth for what the plugin does. Update it when a decision changes.

## Purpose

Turn the time spent waiting for Claude into flashcard reviews. When Claude has been working for a while, Anki opens. When Claude is done, or needs the user, Anki goes away and the user is back in the app they started from.

## Platform

- macOS only in v1. Claude Code must run on the same Mac as Anki desktop: the terminal, an IDE or the desktop app's Code tab.
- On any other system, and in cloud sessions, every hook exits at once and does nothing.
- iOS is out of scope: Claude Code does not run there, and iOS apps cannot open and close each other.

## Components

| Component | What it does |
|---|---|
| `hooks/hooks.json` | Calls `scripts/anki-break.sh` on the events below. Shell form, `timeout` 10 s. |
| `scripts/anki-break.sh` | POSIX `sh` script. Public actions `start`, `stop`, `doctor`. Background actions `open-later`, `finish`. |
| `skills/doctor/SKILL.md` | `/anki-break:doctor`, user-invoked only (`disable-model-invocation: true`). Runs `doctor` and explains the result. |

No agents, MCP servers or other skills.

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

`UserPromptSubmit` also fires for `claude -p`, `/loop` and scheduled runs. The host-app rule below keeps Anki from opening when the user is not at the app that sent the prompt. `ANKI_BREAK_DISABLE=1` turns the plugin off for scripted runs.

## Behaviour

Every hook returns at once and prints nothing: stdout of a `UserPromptSubmit` hook would become part of Claude's context, and `SessionEnd` hooks get 1.5 seconds. Waiting, opening and quitting happen in a background process (output redirected). A `mkdir` lock serialises the steps that read and change state.

**Focus rule.** Focus only moves after at least 1.5 seconds without keyboard or mouse input (HIDIdleTime from `ioreg`, no permission needed). Moving focus while the user types sends the keys to the wrong window: grading cards in Anki, or answering a Claude dialog. If the user keeps typing for 60 seconds, Anki-Break leaves the focus alone.

**start**
1. Exit at once unless `CLAUDE_PLUGIN_DATA` is set, `ANKI_BREAK_DISABLE` is unset, the system is macOS and Anki is installed.
2. Write this session's working mark: a new turn token, and the host app (the frontmost app, unless it is Anki or the lock screen).
3. Start `open-later` in the background.

**open-later** (background)
1. Wait `delay_seconds`. Stop if the turn token has changed or is gone.
2. Wait for the focus rule. If the user keeps typing, skip this turn.
3. Under the lock: stop if the turn is over, if Anki or the lock screen is in front, or if the frontmost app is not the host app (the user moved on to something else). Note whether Anki-Break is launching Anki (`launched`), and mark the launch as in progress (`starting`).
4. Open Anki (`open -b net.ankiweb.dtop`) and wait up to 20 seconds for it to reach the front. Save the pid of an Anki that Anki-Break launched.
5. Under the lock: clear `starting`. If the turn ended during the launch, run `finish` now.

**stop**
1. Read the host app from this session's working mark, then remove the mark.
2. Start `finish` in the background.

**finish** (background)
1. If a launch is in progress, leave everything to `open-later`.
2. If Anki is not in front and Anki-Break did not launch it, there is nothing to do.
3. Wait for the focus rule.
4. Under the lock:
   - If no other session is working (marks younger than 2 hours) and Anki-Break launched Anki: quit it when `when_done` is `quit`, the user is idle and Anki's pid still matches. Forget the launch, unless the user was still typing.
   - If another session is still working, Anki stays open.
   - If Anki is in front and the user is idle, bring the host app back, but only if it is still running.

Anki that the user opened themselves is never quit, only sent to the back.

**doctor** (takes the data folder as an argument, because commands run through the Bash tool get no plugin variables)
Prints the system, whether Anki is installed and running, the settings logged at the last prompt, the working sessions, the last log lines and how to grant the Automation permission. Changes nothing.

## Settings (`userConfig`)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `delay_seconds` | number, 0 to 600 | 15 | How long Claude must be working before Anki opens. Short answers then never open Anki. |
| `when_done` | string | `quit` | `quit`: close Anki when Claude is done, if Anki-Break opened it. `keep`: leave Anki running in the background (no cold start or sync each turn). |

The script reads them from `CLAUDE_PLUGIN_OPTION_DELAY_SECONDS` and `CLAUDE_PLUGIN_OPTION_WHEN_DONE`, validates them and falls back to the defaults on anything else. No `options` list, per the directory rules. `ANKI_BREAK_DISABLE=1` in the environment turns the plugin off for that Claude Code process.

## State

All state lives in `${CLAUDE_PLUGIN_DATA}`. Without it, the hooks do nothing.

- `sessions/<session_id>`: turn token and host app while that session is working
- `launched`: present while an Anki that Anki-Break opened is running, holds its pid
- `starting`: present while a launch is in progress
- `lock`: the lock directory
- `log`: one line per action, trimmed to the last 200 lines when it passes 400

Working marks older than 2 hours are ignored. Files in `sessions/` older than 24 hours are deleted on each `start`. A lock older than about 15 seconds is broken. Nothing is written anywhere else.

## macOS commands used

- `open -b <bundle id>`: open or activate Anki, bring the host app back.
- `lsappinfo`: frontmost app, whether an app is running, Anki's pid. No permission needed.
- `ioreg -c IOHIDSystem`: time since the last input. No permission needed.
- `mdfind`: find Anki outside the Applications folders.
- `osascript`: only to quit Anki, with the standard quit event and without waiting for a reply. macOS asks once per host app (Terminal, iTerm, VS Code ...) for Automation permission. When denied, Anki stays open in the background, the host app still comes back, and the log records the error.

## Non-goals

- Reopening Anki after the user answers a permission prompt mid-turn. It reopens on the next prompt.
- Showing cards inside Claude Code (other plugins do that through AnkiConnect).
- Windows and Linux in v1.

## Name

"Anki" is a trademark of Ankitects. The README says the plugin is not affiliated with Anki, and the icon is original. The name may change before a directory submission.

## Tests

`tests/run.sh` runs every action against stub `uname`, `open`, `osascript`, `lsappinfo`, `ioreg`, `sleep` and `mdfind` commands, and checks the calls made and the state left behind. It runs under `sh`, `dash` and `bash --posix`, and on macOS in CI. Nothing has been tested with a real Anki yet.
