---
name: resume
description: Turn Anki-Break back on in this chat after /anki-break:pause.
disable-model-invocation: true
allowed-tools:
  - Bash(sh ${CLAUDE_PLUGIN_ROOT}/scripts/anki-break.sh resume *)
  - Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/anki-break.sh" resume *)
---

# Resume Anki-Break in this chat

Run:

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/anki-break.sh" resume "${CLAUDE_PLUGIN_DATA}" "${CLAUDE_SESSION_ID}"
```

If a value in the command still reads literally `${...}`, do not guess it. Tell the user that Anki-Break could not tell which chat this is, and that restarting Claude Code fixes that.

Then pass on the one line the script prints, and do nothing else in this turn.
