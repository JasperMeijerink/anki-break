# Contributing

Bug reports and ideas are welcome as issues. Please include the output of `/anki-break:doctor`.

## Development setup

Load the plugin straight from your checkout:

```bash
claude --plugin-dir /path/to/anki-break
```

Run `/reload-plugins` in an open session to pick up changes.

Run the tests, which replace every macOS command with a stub, so they work on any system:

```bash
sh tests/run.sh
```

```bash
TEST_SHELL=dash dash tests/run.sh
```

```bash
shellcheck scripts/*.sh tests/*.sh
```

Validate the manifests the way CI does:

```bash
claude plugin validate --strict --profile directory .
```

To try a branch the way users install it, before it is merged:

```bash
claude plugin marketplace add "JasperMeijerink/anki-break#<branch>"
```

```bash
claude plugin install anki-break@anki-break
```

Remove the marketplace and add it again without `#<branch>` afterwards, or it stays pinned to that branch.

## Manual test on a Mac

The automated tests cannot open a real Anki. Before a release, set `delay_seconds` to 3 in `/config` and check:

1. A long prompt ("count slowly to 30 using the Bash tool, one sleep per number") opens Anki after the delay.
2. When Claude finishes and you pause, Anki quits and the terminal comes back. The first time, macOS asks for Automation permission.
3. A quick question ("what is 2 + 2?") never opens Anki.
4. Typing in the terminal while the delay runs out keeps Anki closed until you pause.
5. A permission prompt mid-turn sends Anki away.
6. An Anki you opened yourself comes back to the front during a turn but is not quit.
7. `/anki-break:doctor` shows the last prompt and the log.

## Layout

```
.claude-plugin/plugin.json       manifest, settings and directory listing metadata
.claude-plugin/marketplace.json  makes this repo its own marketplace
hooks/hooks.json                 the hook events
scripts/anki-break.sh            everything the hooks do
skills/doctor/SKILL.md           /anki-break:doctor
tests/run.sh                     tests with stubbed macOS commands
assets/icon.svg                  directory icon
SPEC.md                          what the plugin does and why
```

## Design notes

- **Hooks return at once.** `UserPromptSubmit` stdout would become part of Claude's context, and `SessionEnd` hooks get 1.5 seconds. All waiting, opening and quitting runs in a detached background process.
- **Focus only moves when you are idle.** A switch while you type sends keys to the wrong window, which can grade cards or answer a Claude dialog.
- **No AppleScript except the quit.** `lsappinfo` and `ioreg` need no permission. Only quitting Anki sends an Apple event, so macOS asks once.
- **Only quit what we opened.** The `launched` flag holds Anki's pid, and an Anki the user opened or reopened is never quit.
- **No settings beyond two.** Everything else follows from the hooks.

## Releases

1. Bump `version` in `.claude-plugin/plugin.json`. Do not set a version in `marketplace.json`. Installed copies only update when this number changes.
2. Run the tests, shellcheck and `claude plugin validate --strict --profile directory .`.
3. Do the manual test above on a Mac.
4. Merge to `main`.
