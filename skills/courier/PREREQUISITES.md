# Courier: prerequisites and permissions

Check every item, in order. **Tested** means verified by hand on the environment below. **Untested** means not verified yet.

## 1. Tested environment

| Item | Version |
| --- | --- |
| OS | macOS 27.0.1 (26A434) |
| Codex desktop app | 26.1029.61003 (also tested 26.1027.61615), bundle id `com.openai.codex` (the app bundle is `ChatGPT.app`) |
| Codex CLI | codex-cli 0.160.0 |
| Claude desktop app | 4.16336.0 (Code tab) |
| cua-driver | 0.5.0 (optional, for the fallback channel) |
| Python | 3.9.6, standard library only |
| Swift | Apple Swift 6.4 (`swift --version`), for native AX fallback |

Other versions may work but are untested. Codex 26.1029 replaced the AXRadioButton tab with Chat toolbar static text. Re-run the self-check (section 7) after an App update. A cold start has only fixture coverage: the running App was not restarted for this review.

## 2. Required for Codex destination channels

| # | Item | How to check or set up |
| --- | --- | --- |
| 1 | macOS | The front end relies on the macOS Accessibility API. Windows and Linux are unsupported (untested: the back end may work there; the front end won't) |
| 2 | Codex desktop app installed and signed in | You can chat in the app |
| 3 | Read access to `~/.codex/` | `sessions/`, `archived_sessions/`, `session_index.jsonl`. **If your agent runs in a container or sandbox, mount `~/.codex`**, or the back end sees nothing. Set `CODEX_HOME` if yours lives elsewhere |
| 4 | Python 3.8+ | `python3 --version` |
| 5 | The skill is installed | As a Claude Code plugin (see README), or `./install.sh` to link it into other agents' skill folders |
| 6 | Sender names | Any name of letters, digits, spaces, `.`, `_` or `-`, up to 40 characters. Set `COURIER_AGENTS="Claude Code,Codex"` to allow only listed names |

## 3. Front end, primary: Claude Computer use

| # | Item | How | If skipped |
| --- | --- | --- | --- |
| 1 | Turn on Computer use in the Claude desktop app | Claude → Settings → This computer → Computer use (off by default) | No `mcp__computer-use__*` tools |
| 2 | Grant Claude **Accessibility** and **Screen Recording** | macOS prompts when you turn it on; otherwise System Settings → Privacy & Security | Screenshots and input fail |
| 3 | Choose **background** control | In the Computer use settings. This skill uses only `app_*` background tools | Full-screen mode takes the screen from the user |
| 4 | **Start a new Claude session after turning it on** | Tools load at session start. A running session won't pick them up (tested) | Tools missing |
| 5 | Approve Codex once per session | The first delivery calls `request_access` for `com.openai.codex` only. Approve it | Every `app_*` call is refused |
| 6 | Keep the Codex app running, not minimized, on the current Space | Use `app_bring_to_current_space` if needed. It doesn't take focus | Clicks and writes are refused |
| 7 | No clipboard grant and no full-screen control needed | Writes use whole-field AXValue replacement | — |

## 4. Front end, fallback: native AX plus cua-driver

| # | Item | How |
| --- | --- | --- |
| 1 | Install trycua's CuaDriver | See the cua project. Tested with 0.5.0 |
| 2 | Grant CuaDriver its own **Accessibility** and **Screen Recording** | `cua-driver permissions grant` |
| 3 | Daemon running | `cua-driver status` |
| 4 | Swift command line tools available | `swift --version`; native AX bridge imports AppKit and ApplicationServices |
| 5 | Accessibility permission for the shell running Swift | `swift -e 'import ApplicationServices; print(AXIsProcessTrusted())'` must print `true` |

Without cua-driver, agents lacking Computer use can only use the CLI channel, which reaches new sessions only.

## 5. CLI, last resort

| # | Item | How |
| --- | --- | --- |
| 1 | Codex CLI installed and signed in | `codex --version`. `codex login` is the user's own step. Agents must not sign in for the user |
| 2 | The agent may run `codex` and use the network | Allow both in the agent's sandbox |
| 3 | Know the write lock | While the Codex app runs, it holds the write lock on **all** sessions it has loaded, not only the visible one. `send <ID>` then exits 4. The CLI reaches new sessions (`send --new`) and sessions the app never loaded |
| 4 | Sandbox level | `send` uses `-s workspace-write` by default; pass `--sandbox read-only` to tighten |

State and logs go to `$COURIER_STATE_DIR` (default `~/.local/state/courier`).

## 6. Claude Code session send

For `--app claude send`, install the Claude Code CLI and sign in as the same account currently used in Claude Desktop. The command checks `claude auth status --json` and compares only the account identifiers in desktop `config.json` and CLI `.claude.json`; it refuses missing or mismatched IDs and authentication override environment variables. Do not provide tokens or passwords to courier. The target must be an existing local desktop session with a unique four-digit title prefix; it may be running because `SendMessage` can queue. Pass its full CLI session ID; titles and numbers alone are refused because local and remote sessions can share them. Courier checks the target's `local_…` address under the current desktop account and the Claude Desktop route receipt. Exit 0 means accepted; only `verify` confirms arrival in the destination log, and `wait` confirms the reply. The CLI process needs network access for `SendMessage`.

## 7. Not supported

- Codex cloud tasks, or Codex on another machine. Session logs live only in the local `~/.codex`.
- A Codex turn waiting on a human approval: `wait` times out, and the user must approve in the app.
- Codex app closed and no Codex CLI installed: no Codex destination channel works.

## 8. Self-check after installing

1. `python3 -I scripts/courier.py find <any session title>` lists the session.
2. Create a test session: compose a body with `compose --new` that asks for the expected `【回复】` header and a unique marker.
3. Send it through Computer use or `send --new`, then `locate --text <snippet>` → `verify` → `wait <ID> --text <snippet>`. For native AX, first locate an existing idle test session and use its full ID and exact title. Request a reply whose first line is the expected `【回复】` header; `wait` requires that header, so a bare 「收到」 fails by design.
4. The frontmost app never changes during the run. Return Codex to the page the user was on.
