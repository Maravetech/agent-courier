# Security

agent-courier drives another app's UI on your Mac through the Accessibility API and reads local Codex session logs. Before installing:

- Read `skills/courier/SKILL.md` and `scripts/courier.py`. Plugins run with your user privileges.
- The script never reads or prints credentials and never sends data off your machine. The CLI channel runs `codex exec`, which talks to OpenAI as the Codex CLI normally does.
- Grant Accessibility and Screen Recording only to apps you trust (Claude, CuaDriver).

Report vulnerabilities privately through GitHub's "Report a vulnerability" on this repository.
