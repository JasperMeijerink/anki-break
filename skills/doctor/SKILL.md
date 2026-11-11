---
name: doctor
description: Check why Anki-Break does or does not open Anki. Shows the system, whether Anki is installed and running, the settings at the last prompt, working sessions and recent log lines.
disable-model-invocation: true
allowed-tools:
  - Bash(sh ${CLAUDE_PLUGIN_ROOT}/scripts/anki-break.sh doctor *)
  - Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/anki-break.sh" doctor *)
---

# Anki-Break doctor

Run the diagnosis. It only reads, it changes nothing:

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/anki-break.sh" doctor "${CLAUDE_PLUGIN_DATA}"
```

If either path above still reads literally `${CLAUDE_PLUGIN_ROOT}` or `${CLAUDE_PLUGIN_DATA}`, the script is `../../scripts/anki-break.sh` relative to the directory this SKILL.md was read from. Run it with only `doctor` and no folder argument.

Then tell the user, in a few short lines, what the output means and what to do. Match the output to the first row that applies:

| Output | Meaning and fix |
|---|---|
| `system:` is not macOS | Anki-Break only works when Claude Code runs on the same Mac as Anki. Cloud sessions and other systems are skipped on purpose. |
| `anki installed: no` | Install Anki desktop from apps.ankiweb.net into the Applications folder. |
| `disabled: yes` | `ANKI_BREAK_DISABLE` is set in the environment Claude Code was started from. Unset it and restart Claude Code. |
| `settings at the last prompt: no prompt seen yet` | The hooks have not run. Run `/reload-plugins` or start a new session, and check `/plugin` for errors. |
| The log shows `start` lines but never `opened anki` | Claude finished before the delay ran out. Lower `delay_seconds` in `/config`, or give Claude a longer task to test. |
| The log shows `quit refused` | macOS blocked the quit. Open System Settings, Privacy and Security, Automation, and allow your terminal app to control Anki. Until then Anki stays open in the background. |
| `working sessions` is above 0 while nothing runs | A session ended without a stop. The mark is ignored after 6 hours and deleted after 24. |

Do not change any files or settings yourself. If nothing in the table fits, show the last log lines and suggest opening an issue at https://github.com/JasperMeijerink/anki-break/issues.
