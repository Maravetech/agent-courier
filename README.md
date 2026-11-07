<img src=".claude-plugin/icon.png" width="96" alt="agent-courier icon">

# agent-courier

[中文说明](README.zh-CN.md)

**Courier (投递)** delivers messages to chosen **Codex or Claude Code sessions** on macOS, confirms delivery from local session logs, and reads the reply. Codex UI delivery runs in the background without stealing your keyboard or mouse focus.

> Unofficial community project. Not affiliated with, endorsed by, or supported by OpenAI or Anthropic. "Codex", "ChatGPT" and "Claude" are trademarks of their respective owners.

## How it works

- **Front end sends.** The agent switches to the target session in the Codex app, writes the message into the input box and presses send, through background macOS Accessibility actions. It works for any session, including a new one.
- **Back end confirms.** The agent reads `~/.codex` session logs directly (read-only), so checking delivery and reading replies costs a few lines of text, not screenshots.
- **Identity tokens.** Every message starts with `【投递】<sender>·<session> → <receiver>·<session>` and every reply reverses the tokens with `【回复】`, so it is clear who sent what to whom.

| Channel | Tool | Reaches | Screenshots |
| --- | --- | --- | --- |
| Front end, primary | Claude Computer use (background `app_*` tools) | Any session in the Codex app, including new ones | One tiny 0.1-scale capture before a write or click |
| Front end, fallback | native macOS AX via Swift, with [cua-driver](https://github.com/trycua/cua) for window ID discovery (`ui-*` commands); the bridge binds the AX window by ID | Same | None |
| CLI, last resort | `codex exec` | New sessions, and sessions the app never loaded | None |
| Claude session send | `claude -p` with one `SendMessage` call | An existing, uniquely numbered Claude Code session | None |

## Safety

- Never overwrites a draft: if the input box holds anything but its placeholder, it stops and asks.
- The native AX helper requires the full session ID and exact tab title, then checks the tab and draft again before clicking Send. It refuses messages without an identity header.
- If UI sending fails after writing, it restores the previous empty composer only when the same window, tab, and exact text are still present. An `未还原` result means the tab or draft changed; inspect the App before retrying. The Send button is selected from the same final AX snapshot as the active tab.
- Background only: no full-screen control, no clipboard, never clicks links.
- Stops and hands back to you on anything about money, credentials, rule changes, irreversible actions, or no progress.

## Optional bird overlay (macOS)

The visual is **off by default**. Run `sh overlay/build.sh`, then `python3 -I skills/courier/scripts/courier.py overlay on` to enable it. Use `overlay off` to stop the renderer and `overlay status` to see the saved and effective settings. The panel checkbox writes the same local setting. `COURIER_OVERLAY=0` or `1` temporarily overrides it. When off, the delivery path skips renderer startup, visual rollout reads and pair writes. The disconnected-link gate still applies.

Rings mark the paired sidebar rows and a dashed line links them. Solid birds mean active, hollow birds mean idle, and gray birds mean disconnected. Open the menu bird to manage pairs. Physical click-through, focus continuity, and following real window movement need fenn's own acceptance.

Build with `sh overlay/build.sh`. The resident process hosts Core Animation layers in SkyLight windows and does not link AppKit. The transparent 18 × 14 pt bird is made entirely from Core Graphics rectangle paths; Core Animation switches its two wing poses and mirrors it for leftward flight. No bird image asset is loaded. A stable Accessibility grant needs a signed install at `~/Applications/courier-overlay.app` with bundle ID `tech.marave.courier-overlay`; this machine has no signing identity, so installation is unverified. Without Accessibility, the bird hides without prompting. The process runs only while pairs exist and exits about three seconds after the last pair disappears. It draws its icon in the same process and opens a separate AppKit pair panel on demand. Icon clicks currently require preexisting Input Monitoring access; without it, no permission is requested and the icon is not clickable. The panel has a visibility switch, Connect/Disconnect controls, and Quit. Launch at Login uses `SMAppService.mainApp` and defaults off; registration is unverified without a signing identity. Disconnect persists in `$COURIER_STATE_DIR/overlay/links.json` and blocks delivery with exit code 5.

Each pair uses one transparent CA window covering the route and its two rings. Its empty event region passes clicks through, and the renderer never moves the pointer; physical click-through and key-window behavior still need desktop acceptance. The AX reader locates sidebar rows: Codex matches five-digit `AXButton` titles under `AXList`; Claude matches four-digit titles under `AXWebArea`, within 320 pt of the left edge and at most 320 pt wide. It deduplicates frames, selects a visible row, then uses the title `AXStaticText` frame to place the bird before the first digit, clamping the ring center inside the window when its left edge would cross the border. Each pair has a straight dashed line, two rings, and a bird in its own color; up to ten visible pairs get ten distinct colors. The bird flies for 2.5 seconds with Core Animation position, wing, and emitter animations. Reduce Motion disables particles. The ten most recently active pairs, including disconnected gray birds, are displayed while other pairs remain listed. AXObserver drives relocation and writes `$COURIER_STATE_DIR/overlay/locate.log`; a pair hides whenever either row is not visible. The visibility switch persists in `$COURIER_STATE_DIR/overlay/config.json`. DSH support is a later phase.

For Claude Computer use, first call `python3 -I skills/courier/scripts/courier.py overlay check --from 'Claude Code·0064' --to 'Codex·00165'`; exit code 5 means stop without sending. Then call `overlay pair --from ... --to ... --state sending` immediately before sending. Codex-to-Codex pairs use `Codex·NNNNN` on both sides. The native App watches Codex rollout files and advances delivery states; `verify`, `wait`, and `watch` also report progress. The Python overlay controller is a one-shot command. `COURIER_OVERLAY=0` turns the visual off but does not bypass a disconnected link.

The on-demand pair panel groups sessions by App and shows titles, direction, peer, status, and activity time. `courier.py overlay list [--json]` uses the same native session catalog. Confirmed archived or missing sessions move to an invalid group and stop rendering; unreadable indexes remain unknown. Cleanup removes only selected invalid pairs and their disconnected links under state.lock.

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

**Codex → Claude Code:** `--app claude find <number or exact title>` → `status <ID> -n 0` → `compose --from-agent Codex --from-session <five-digit number> --to <Claude ID> --file body.txt --out msg.txt` → `--app claude send <Claude ID> --file msg.txt` → `--app claude verify <ID> --text <unique marker>` → `--app claude wait <ID> --text <unique marker>`. The CLI must be signed in to the same account as the Claude desktop App; missing or mismatched account IDs refuse before sending. The SendMessage tool result must contain `success:true` and `msg_id`, and its call must match the complete title and body exactly. Claude's reply header is `【回复】Claude Code·NNNN → Codex·NNNNN`; Claude uses courier to deliver that reply back to Codex. See [SKILL.md](skills/courier/SKILL.md) for the full round trip.

After `locate` finds a new session ID, run `wait-number <ID> --timeout 90` before using its five-digit number. It polls the session index and returns `编号未就绪` if the title is still unnumbered. The first `Codex·新建` delivery remains valid even when the new session has a bootstrap user message before that delivery, provided there was no earlier headed delivery or assistant reply.

`ui-switch` and `ui-send` wait up to 30 seconds for Codex to leave the foreground (`--front-timeout <seconds>` adjusts this). If Codex stays frontmost, they do not switch or write. The native bridge checks again just before AX actions. If Codex comes forward during a switch, the operation stops and attempts to restore the original tab; an unconfirmed restoration is reported explicitly.

`verify` polls for up to 30 seconds by default because the session log may lag after Send returns. Use `--timeout 0` for a single immediate check.

`send --new` does not set the Codex App title or guarantee a numbered sidebar title. The installed `codex-cli 0.160.0` has no title option on `codex exec` and no CLI rename command; use a supported App session-title tool or rename the new chat in the App, then read the title back before using its number. Do not edit `~/.codex/session_index.jsonl` to rename it. The first `Codex·新建` delivery can still be verified by `wait` after the App auto-generates a title.

**Native AX window binding:** `ui-*` resolves the Codex process by bundle ID, reads that app's own `AXWindows`, and matches the selected screen window by WindowServer ID, with a unique geometry fallback. Every current-title read, sidebar button, composer, Send button, and rollback belongs to that AXWindow. Codex 26.1029 exposes the current title as static text in the Chat toolbar rather than an AXRadioButton; the helper cross-checks it against the AXWindow title. Older AXRadioButton layouts remain supported. Missing or conflicting titles and ambiguous windows or controls are refused. Duplicate exact-title sidebar buttons inside the one bound window are allowed; the first is pressed and the resulting title is polled for up to 3 seconds. If the target is absent because the Recent section is collapsed, `ui-switch` expands that section, switches, and restores the folded state before returning success. Failure to restore returns nonzero; an absent button with a ready composer is reported separately from loading timeout. Pass `--window-id <ID>` when more than one Codex window is on screen. The older CuaDriver tree can contain duplicate `AXWindow` roots; `ui-*` never uses that tree to select controls. On cold start it attempts `AXManualAccessibility` and polls for the toolbar and composer. The current App returns AXError -25205 (attribute unsupported); if loading times out, one read-only filtered CuaDriver snapshot primes Electron accessibility, then native AX is retried. A second timeout refuses before writing.

When an idle Codex app temporarily exposes no matching `AXWindows`, the bridge takes one read-only filtered CuaDriver window snapshot before retrying the window binding. Zero matches after that retry still refuse; multiple matches never select a window by guesswork.

The first real delivery was verified in an isolated Codex test session on 2026-11-05: single-line and multiline text both passed `verify` and `wait`, with the frontmost app unchanged. Swift's `AXValue` readback includes a trailing newline on the empty composer placeholder. The helper clears the composer with an empty string on rollback and checks that Send disappears; writing the placeholder text would create a draft.

`ui-tab`, `ui-switch`, and `ui-send` share a cross-process Codex UI lock in `COURIER_STATE_DIR` to serialize access to the shared Codex window. The lock records the holder PID and command, releases on process exit, and times out after 10 seconds by default (`--lock-timeout <seconds>`). Only courier processes using this version and the same state directory cooperate; direct cua-driver calls and older installed copies do not. The send path also checks that the header receiver number matches the current tab number before writing.

The native AX bridge is compiled once with `swiftc` into `~/Library/Caches/agent-courier` and reused by `ui-*` commands. The cache name includes the Swift source SHA-256; a private directory, owner-only file modes, and a binary checksum manifest are checked before reuse. A changed or untrusted cache entry is recompiled, and a compiler/cache failure falls back to interpreting the Swift source. No cached binary is used after a failed integrity check.

On the new-chat home, `ui-tab` refuses with `当前在首页，没有打开会话` when the composer has loaded but no conversation is open. Cold starts without a composer still report a loading timeout. UI exceptions now include their specific safe reason (for example, a lock timeout and holder PID); raw CuaDriver output is hidden because it may contain private window text.

`wait` ignores complete, structured Codex question-answer control envelopes such as `<send_user_message_question_reply>`, as well as Codex environment/external context injections. A new ordinary user message after the delivery still makes the turn `interleaved`. The rollout does not provide a distinct provenance marker for a human message that exactly imitates a control envelope, so this filtering cannot distinguish that rare case.

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
