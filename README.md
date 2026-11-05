# agent-courier

[中文说明](README.zh-CN.md)

**Courier (投递)** lets one AI agent deliver a message into a chosen session of the **Codex desktop app** on macOS, confirm delivery from the session log, read the reply, and keep the task going, all **without stealing your keyboard or mouse focus**.

> Unofficial community project. Not affiliated with, endorsed by, or supported by OpenAI or Anthropic. "Codex", "ChatGPT" and "Claude" are trademarks of their respective owners.

## How it works

- **Front end sends.** The agent switches to the target session in the Codex app, writes the message into the input box and presses send, through background macOS Accessibility actions. It works for any session, including a new one.
- **Back end confirms.** The agent reads `~/.codex` session logs directly (read-only), so checking delivery and reading replies costs a few lines of text, not screenshots.
- **Identity tokens.** Every message starts with `【投递】<sender>·<session> → Codex·<session>` and every reply with `【回复】Codex·<session> → <sender>·<session>`, so it is always clear who sent what to whom.

| Channel | Tool | Reaches | Screenshots |
| --- | --- | --- | --- |
| Front end, primary | Claude Computer use (background `app_*` tools) | Any session in the Codex app, including new ones | One tiny 0.1-scale capture before a write or click |
| Front end, fallback | [cua-driver](https://github.com/trycua/cua) accessibility calls (`ui-*` commands) | Same | None |
| CLI, last resort | `codex exec` | New sessions, and sessions the app never loaded | None |

## Safety

- Never overwrites a draft: if the input box holds anything but its placeholder, it stops and asks.
- Checks the active tab before sending, and refuses messages without an identity header.
- Background only: no full-screen control, no clipboard, never clicks links.
- Stops and hands back to you on anything about money, credentials, rule changes, irreversible actions, or no progress.

## Install

**Claude Code** (plugin):

```bash
claude plugin marketplace add Maravetech/agent-courier
claude plugin install agent-courier@courier-marketplace
```

**Any agent via [skills.sh](https://skills.sh)** (Vercel `skills` CLI, Node 22.20+):

```bash
npx skills add Maravetech/agent-courier --skill courier -g          # pick agents interactively
npx skills add Maravetech/agent-courier --skill courier -g -a codex -y
```

**Other agents** (Codex, OpenClaw, Hermes, …) that read skill folders:

```bash
git clone https://github.com/Maravetech/agent-courier
cd agent-courier && ./install.sh          # links skills/courier into ~/.agents/skills etc.
./install.sh --check                      # verify only
```

Then go through **[PREREQUISITES.md](skills/courier/PREREQUISITES.md)** item by item: macOS permissions, turning on Computer use, approving Codex access, the CLI sign-in, and a self-check. Don't skip it.

## Quick example

```bash
C=skills/courier/scripts/courier.py
python3 -I $C find 00159                                  # get the session ID
python3 -I $C compose --from-agent "Claude Code" --from-session 0007 \
  --to <ID> --file body.txt --out msg.txt                 # add identity header
# send msg.txt via Computer use, or the fallback:
python3 -I $C ui-switch "00159" && python3 -I $C ui-send --file msg.txt --expect-tab "00159"
python3 -I $C verify <ID> --text "<snippet>" --since <UTC time>
python3 -I $C wait <ID> --since <UTC time>
```

## Requirements

macOS, the Codex desktop app, Python 3.8+ (standard library only). Optional: Claude desktop app with Computer use, cua-driver, Codex CLI. Tested versions are listed in [PREREQUISITES.md](skills/courier/PREREQUISITES.md).

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `CODEX_HOME` | `~/.codex` | Where Codex keeps session logs |
| `COURIER_STATE_DIR` | `~/.local/state/courier` | CLI-channel logs |
| `COURIER_AGENTS` | (any valid name) | Comma-separated allowlist of sender names |
| `COURIER_SEND_LABELS` | `发送,Send,送信,Senden,Envoyer,Enviar` | Send-button labels for the cua-driver channel |

## Development

```bash
python3 -m unittest discover -s tests -v   # offline tests with a fake CODEX_HOME
claude plugin validate --strict .
```

## License

[MIT](LICENSE)
