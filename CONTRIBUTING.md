# Contributing

Thanks for helping. This project is small and stays small on purpose.

## Requirements

- macOS for real delivery tests; the unit tests run anywhere.
- Python 3.8 or newer. Standard library only: no third-party packages.

## Setup

```bash
git clone https://github.com/Maravetech/agent-courier.git
cd agent-courier
python3 --version
```

There is no install step for development.

## Run the tests

```bash
python3 -m unittest discover -s tests -v
```

The tests are offline and use a fake `CODEX_HOME`. They never touch your real `~/.codex`. Tests must pass before a pull request is opened. A behavior change without a test is not ready.

If you change the plugin manifests, also run:

```bash
claude plugin validate --strict .
```

## Layout

| Path | Role |
| --- | --- |
| `skills/courier/SKILL.md` | The skill: when to use it and the step-by-step procedure. |
| `skills/courier/PREREQUISITES.md` | Permissions, sign-in and self-check for users. |
| `skills/courier/scripts/courier.py` | CLI: find sessions, compose headers, send, verify, wait. |
| `.claude-plugin/` | Claude Code plugin and marketplace manifests. |
| `install.sh` | Links the skill into other agents' skill folders. |
| `tests/` | Offline unit tests. |

## Change rules

- Never steal focus. Front-end sending stays background-only: no full-screen control, no clipboard, no link clicks.
- Never overwrite a draft. If the input box holds anything but its placeholder, stop and ask.
- Session logs are read-only. Never write to `~/.codex`.
- Keep the identity header on every message and reply.
- Money, credentials, rule changes and irreversible actions always hand back to a human.
- New behavior needs a test that fails before the change and passes after it.

## Pull requests

- One topic per pull request.
- Describe what changed, why, and how it was verified.
- Include the test command and its result.
- Update `README.md`, `README.zh-CN.md` and `PREREQUISITES.md` together when install steps, commands or variables change.
- Do not commit credentials, tokens, personal paths, session logs or state files.

## License

Contributions are accepted under the MIT license. See [LICENSE](LICENSE).
