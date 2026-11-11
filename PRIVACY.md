# Privacy

Anki-Break collects nothing, sends nothing and never reads your Anki collection.

## What it runs

A POSIX shell script, `scripts/anki-break.sh`, runs on your Mac when Claude Code fires a hook event. It uses these macOS commands:

- `open`, to open Anki and to bring your terminal app back
- `lsappinfo`, to see which app is in front and whether Anki is running
- `ioreg`, to see how long ago you last typed or moved the mouse (only the time, never what you typed)
- `mdfind`, to find Anki when it is not in the Applications folder
- `defaults`, to read Anki's bundle id from the app
- `osascript`, only to send Anki the standard quit command

## What it stores

In the plugin's data folder, which Claude Code deletes when you uninstall the plugin:

- one small file per working Claude session, holding a turn token made of the time and a process id, deleted when the turn ends or after 24 hours at the latest
- one small file per session with the time of its last stop, deleted after 24 hours
- a flag with Anki's process id while an Anki that Anki-Break opened is running
- a log of its own actions, trimmed to the last 200 lines whenever it passes 400

## What it sends

Nothing. Anki-Break makes no network connections.

## Questions

Open an issue at https://github.com/JasperMeijerink/anki-break/issues.
