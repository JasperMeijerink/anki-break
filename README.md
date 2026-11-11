# Anki-Break

Turn waiting for Claude into flashcard time. Anki-Break is a Claude Code plugin for macOS: when Claude has been working for 15 seconds, Anki opens. When Claude is done or needs you, you are switched back to your terminal, and Anki waits in the background for the next turn.

Anki-Break is not affiliated with or endorsed by Anki or Ankitects.

## Why

Agents make you wait: twenty seconds here, three minutes there. That is the perfect length for a few reviews, but switching apps by hand means you either never start or forget to come back. Anki-Break does the switching for you.

## How it works

- You send a prompt. If Claude is still working after the delay (15 seconds by default), Anki opens, as long as you are not typing and are still in the app you prompted from.
- Claude finishes, asks you something or needs permission. As soon as you pause, your terminal comes back to the front. Anki stays open in the background, ready for the next turn. Anki-Break can also quit Anki instead (see Settings).
- Quick answers never open Anki at all.
- An Anki you opened yourself is never quit, only sent to the back.
- Focus only moves after 1.5 seconds without typing, so your keys never land in the wrong window.
- With several Claude sessions, Anki stays open until the last one is done. A session that needs you still brings its terminal back, and Anki does not open over a session that stopped in the last minute.
- Runs without a terminal or editor behind them, such as cron jobs or SSH sessions, never open Anki.

## Requirements

- macOS, with Claude Code running on the same Mac: in a terminal, an IDE, or the Code tab of the Claude desktop app. It does nothing in cloud sessions or on other systems, and it cannot work on iOS.
- Anki desktop from [apps.ankiweb.net](https://apps.ankiweb.net), in Applications or anywhere Spotlight can find it. Current releases (26.x) and releases up to 25.06 are supported. The 25.07 to 25.09 launcher builds should work but are untested.
- No Anki add-ons. AnkiConnect is not needed.

## Install

In a Claude Code session:

```text
/plugin install anki-break --marketplace JasperMeijerink/anki-break
```

From your shell:

```bash
claude plugin marketplace add JasperMeijerink/anki-break
```

```bash
claude plugin install anki-break@anki-break
```

In the Claude desktop app, open **Customize > Plugins**, add the marketplace `JasperMeijerink/anki-break`, then add the Anki-Break plugin itself. Adding only the marketplace installs nothing. The plugin loads in your next new session.

Start a new session, or run `/reload-plugins`, after installing.

### Quitting Anki needs one macOS permission

By default Anki-Break only switches windows, which needs no permission. If you set `when_done` to `quit`, then the first time Anki-Break quits Anki, macOS asks whether your terminal app (Terminal, iTerm, VS Code, ...) may control Anki. Click **OK**. If you click **Don't Allow**, Anki stays open in the background after each turn. You can allow it later in **System Settings > Privacy & Security > Automation**.

## Settings

Change these in `/config`, under the plugin's options:

| Setting | Default | What it does |
|---|---|---|
| `delay_seconds` | `15` | How long Claude must be working before Anki opens, from 0 to 600. |
| `when_done` | `keep` | `keep` switches back to your terminal and leaves Anki running in the background, so it is there at once next time. `quit` also closes Anki when Claude is done, if Anki-Break opened it. |

To turn Anki-Break off for one Claude Code process, start it with `ANKI_BREAK_DISABLE=1 claude`. Scheduled and cron runs are already skipped, but this also covers `claude -p` started from a terminal.

## Command

`/anki-break:doctor` checks why Anki does or does not open. It shows whether Anki is found, the settings at your last prompt, working sessions and the recent log, and explains what to do.

## Examples

1. You ask Claude to refactor a module. After 15 seconds Anki opens and you do a few reviews. Claude finishes, you pause, and your terminal is back in front, with Anki waiting behind it.
2. You ask a quick question and Claude answers in five seconds. Anki never opens.
3. Halfway through a task, Claude asks permission to run the tests. Anki goes away so you can answer. It opens again after your next prompt.
4. You were reading docs in your browser while Claude worked. Anki does not interrupt you.
5. You already had Anki open. It comes to the front while Claude works and goes back afterwards, without being quit.
6. Two Claude sessions are working. Anki stays open until both are done.

## What it runs and stores

- It runs a POSIX shell script on Claude Code's hook events, plus the macOS commands `open`, `lsappinfo`, `ioreg`, `mdfind`, `defaults` and, only when `when_done` is `quit`, `osascript`.
- It stores a few small state files and a short log in the plugin's data folder. Session files are deleted after 24 hours, and the log keeps its last 200 to 400 lines. Claude Code deletes the folder when you uninstall the plugin.
- It makes no network connections and never reads your Anki collection. See [PRIVACY.md](PRIVACY.md).

## Troubleshooting

Run `/anki-break:doctor` first. Common causes:

**Anki never opens.** Claude finished before the delay ran out, you were typing, you were in another app, or Claude Code is not running on your Mac. The doctor's "host app" line must name your terminal or editor. Lower `delay_seconds` to try it out.

**Anki does not quit.** That is the default: `when_done` is `keep`. With `quit`, check the Automation permission above. Anki-Break also leaves an Anki you opened yourself open, and does nothing while you keep typing.

**Every quit triggers a sync.** With `when_done` set to `quit`, that is Anki's "sync on close" setting. The default, `keep`, avoids it.

**Anki opened while I was typing.** It should wait for a pause of 1.5 seconds. Please open an issue with the doctor output.

## Status

Version 0.1. The script is tested with stubbed macOS commands in CI on macOS and Linux, under `sh`, `dash` and `bash`. It has not been tried on a real Mac with Anki yet. Reports are very welcome.

Known limits: after you answer a permission prompt in the middle of a turn, Anki opens again only after your next prompt. Windows and Linux are not supported.

## Uninstall

```bash
claude plugin uninstall anki-break@anki-break
```

```bash
claude plugin marketplace remove anki-break
```

## Alternatives

Other Anki plugins for Claude Code show cards inside the terminal through AnkiConnect, for example [medan](https://github.com/avlihachev/medan) and [anki-claude-mod](https://github.com/hbkse/anki-claude-mod). Anki-Break switches to the real Anki app instead, with nothing to set up inside Anki.

## Feedback

Bugs and ideas: [open an issue](https://github.com/JasperMeijerink/anki-break/issues). See [CONTRIBUTING.md](CONTRIBUTING.md) for the development setup.

## License

[MIT](LICENSE)
