<img src=".claude-plugin/icon.png" width="96" alt="agent-courier icon">

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
| Front end, fallback | native macOS AX via Swift, with [cua-driver](https://github.com/trycua/cua) for on-screen window geometry (`ui-*` commands) | Same | None |
| CLI, last resort | `codex exec` | New sessions, and sessions the app never loaded | None |

## Safety

- Never overwrites a draft: if the input box holds anything but its placeholder, it stops and asks.
- The native AX helper requires the full session ID and exact tab title, then checks the tab and draft again before clicking Send. It refuses messages without an identity header.
- If UI sending fails after writing, it restores the previous empty composer only when the same window, tab, and exact text are still present. An `未还原` result means the tab or draft changed; inspect the App before retrying. The Send button is selected from the same final AX snapshot as the active tab.
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
python3 -I $C ui-switch "<exact title>" && python3 -I $C ui-send --file msg.txt --session-id <ID> --expect-tab "<exact title>"
python3 -I $C verify <ID> --text "<snippet>" --since <UTC time>
python3 -I $C wait <ID> --text "<unique delivery snippet>"
python3 -I $C watch <ID>             # stream start / complete / abort / waiting for approval
```

`ui-send` is for existing indexed sessions. Use Computer use or `send --new` to create a session. `find`, `status`, `verify`, `wait`, and `watch` read all rollout segments for one session ID in timestamp order, including files with a `_segment-id` suffix. `wait` anchors to the matching delivery message, even if you start waiting after its turn has ended. A failed or mismatched reply exits nonzero. The offline tests do not prove real Codex UI delivery.

`verify` polls for up to 30 seconds by default because the session log may lag after Send returns. Use `--timeout 0` for a single immediate check.

`send --new` does not set the Codex App title or guarantee a numbered sidebar title. The installed `codex-cli 0.160.0` has no title option on `codex exec` and no CLI rename command; use a supported App session-title tool or rename the new chat in the App, then read the title back before using its number. Do not edit `~/.codex/session_index.jsonl` to rename it. The first `Codex·新建` delivery can still be verified by `wait` after the App auto-generates a title.

**Native AX window binding:** `ui-*` resolves the Codex process by bundle ID, reads that app's own `AXWindows`, and matches one window by position and size to the selected on-screen CuaDriver window. Every tab, sidebar button, composer, Send button, and rollback belongs to that AXWindow. Ambiguous or unmatched windows and controls are refused. Pass `--window-id <ID>` when more than one Codex window is on screen. The older CuaDriver tree can contain duplicate `AXWindow` roots; `ui-*` does not use that tree.

The first real delivery was verified in an isolated Codex test session on 2026-11-05: single-line and multiline text both passed `verify` and `wait`, with the frontmost app unchanged. Swift's `AXValue` readback includes a trailing newline on the empty composer placeholder. The helper clears the composer with an empty string on rollback and checks that Send disappears; writing the placeholder text would create a draft.

`ui-tab`, `ui-switch`, and `ui-send` share a cross-process Codex UI lock in `COURIER_STATE_DIR` to serialize access to the shared Codex window. The lock records the holder PID and command, releases on process exit, and times out after 10 seconds by default (`--lock-timeout <seconds>`). Only courier processes using this version and the same state directory cooperate; direct cua-driver calls and older installed copies do not. The send path also checks that the header receiver number matches the current tab number before writing.

## Requirements

macOS, the Codex desktop app, Python 3.8+ (standard library only), Swift command line tools, and cua-driver for the fallback `ui-*` channel. Optional: Claude desktop app with Computer use, Codex CLI. Tested versions are listed in [PREREQUISITES.md](skills/courier/PREREQUISITES.md).

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `CODEX_HOME` | `~/.codex` | Where Codex keeps session logs |
| `COURIER_STATE_DIR` | `~/.local/state/courier` | CLI-channel logs and Codex UI writer lock |
| `COURIER_AGENTS` | (any valid name) | Comma-separated allowlist of sender names |
| `COURIER_SEND_LABELS` | `发送,Send,送信,Senden,Envoyer,Enviar` | Send-button labels for the native AX channel |

## Development

```bash
python3 -m unittest discover -s tests -v   # offline tests with a fake CODEX_HOME
claude plugin validate --strict .
```

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request, and follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
