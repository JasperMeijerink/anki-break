# Working on Anki-Break

- Read SPEC.md before changing anything. Update it when a decision changes.
- After every change run `sh tests/run.sh`, `TEST_SHELL=dash dash tests/run.sh`, `TEST_SHELL="bash --posix" bash --posix tests/run.sh`, `shellcheck scripts/*.sh tests/*.sh` and `claude plugin validate --strict --profile directory .`.
- Settings only via `userConfig`. The script validates every `CLAUDE_PLUGIN_OPTION_*` value and falls back to defaults.
- State only in `${CLAUDE_PLUGIN_DATA}`, with the cleanup rules in SPEC.md.
- POSIX `sh` only. No apostrophes inside single-quoted strings. No `case` inside `$(...)`.
- The `start` action must print nothing on stdout: it becomes part of Claude's context.
- Bump `version` in `.claude-plugin/plugin.json` for every release. Never set a version in `marketplace.json`.
- The repo is public. Write commit messages and PR descriptions for any reader, without em dashes or semicolons.
