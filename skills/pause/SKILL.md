---
name: pause
description: Pause Anki-Break in this chat, so Anki does not open while Claude works here. Optionally for a set time, such as 30m or 2h. Other chats are not affected.
argument-hint: "[duration, e.g. 30m or 2h]"
disable-model-invocation: true
allowed-tools:
  - Bash(sh ${CLAUDE_PLUGIN_ROOT}/scripts/anki-break.sh pause *)
  - Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/anki-break.sh" pause *)
---

# Pause Anki-Break in this chat

Run the command below. If the user gave a duration, add it as one more argument at the end, but only when it is a number of minutes or hours in one of these forms: `30`, `30m` or `2h` (at most 24 hours). If they gave anything else, ask for a duration in that form and run nothing.

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/anki-break.sh" pause "${CLAUDE_PLUGIN_DATA}" "${CLAUDE_SESSION_ID}"
```

If a value in the command still reads literally `${...}`, do not guess it. Tell the user that Anki-Break could not tell which chat this is, and that restarting Claude Code fixes that.

Then pass on the one line the script prints, and do nothing else in this turn.
