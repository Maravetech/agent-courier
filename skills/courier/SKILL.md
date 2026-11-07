---
name: courier
description: >-
  Courier (投递): send a headed message to a chosen Codex desktop-app or Claude Code session,
  confirm delivery in its local session log, and wait for a headed reply. Codex UI sending uses
  background accessibility without stealing focus; Codex-to-Claude sending uses one Claude CLI
  SendMessage call with account and target checks. Use for "投递给 Codex", "发给 Claude Code 会话",
  or checking a session's delivery and reply.
---

# Courier

**One line**: the front end sends (UI or CLI); the back end reads the target session log to confirm; repeat until the task is done.

First time? Go through [`PREREQUISITES.md`](PREREQUISITES.md) and run its self-check before delivering anything real.

## Helper script

`C=<this skill's dir>/scripts/courier.py`, run as `python3 -I $C …`.

| Command | What it does | Exit codes |
| --- | --- | --- |
| `compose --from-agent <name> --from-session <number> --to <ID>` (or `--new`) `--file <body> --out <file>` | Adds the delivery header and the reply requirement | 0 / 2 invalid |
| `find <number or title>` | List matching sessions: ID, title, log path | 0 / 1 none |
| `locate --text <snippet> --since <time>` | Find a session by message text (use after creating a new session in the UI) | 0 / 1 none |
| `wait-number <ID> [--timeout 90]` | Poll the exact new Codex session until its title begins with a unique five-digit number and a space | 0 ready / 2 conflict / 3 timeout |
| `status <ID>` | Is a turn running, plus the last few messages | 0 / 1 / 2 ambiguous |
| `verify <ID> --text <snippet> --since <time> [--timeout 30]` | Poll for delivery proof in the log (default 30 seconds; `--timeout 0` checks once) | 0 delivered / 1 not |
| `wait <ID> --text <unique delivery snippet>` | Wait for the first turn end after that delivery; check the reply header | 0 verified / 1 failed / 2 ambiguous / 3 timeout |
| `watch <ID> [<ID> …] --since <time>` | One-shot wake when any listed session ends a turn | 0 ended / 3 timeout |
| `watch <ID> --stream` | Continuously print start, complete, abort, and approval-wait changes | 0 on bounded timeout |
| `overlay pair --from 'Claude Code·0007' --to 'Codex·00159' --state sending` | Start the optional click-through bird overlay before a Computer use send | 0 (visual failure never blocks delivery) |
| `overlay check --from 'Claude Code·0007' --to 'Codex·00159'` | Gate a Computer use send against a disconnected pair | 0 allowed / 5 disconnected |
| `overlay on` / `overlay off` / `overlay status` | Save or read the optional visual setting (default off). Status shows the saved and effective values | 0 success |
| `overlay list [--json]` | Read the same session pairs shown by the panel | 0 listed |
| `ui-tab` / `ui-switch <exact title>` / `ui-send --file <body> --session-id <ID> --expect-tab <exact title>` | Fallback front end for an existing session; use `--window-id <ID>` on each command when multiple Codex windows are on screen | `ui-send`: 0 clicked / 2 refused / 1 no send button |
| `--app claude <find\|status\|verify\|wait\|watch\|locate\|compose>` | Claude desktop session records (`~/.claude/projects`) | as above |
| `--app claude send <full local CLI session ID> --file <body>` | Address one Claude Desktop session by its account-scoped `local_…` ID through one `claude -p` / `SendMessage` call; a running target may queue the message | 0 accepted, then verify / 2 refused / 5 uncertain |
| `send <ID> --file <body>` or `send --new --file <body>` | CLI fallback via `codex exec` | 0 submitted / 4 session held by the app |

Session numbers can repeat. **Always act on the session ID.**

The back end is read-only and can read every session: open in the app, not open, or archived. Only the CLI `send` is limited by write locks.

## Identity tokens (required)

Every message starts with a delivery header naming sender and receiver as `<App or Agent>·<session number>`:

```
【投递】Claude Code·0007 → Codex·00159
```

Every reply must start with the reverse:

```
【回复】Codex·00159 → Claude Code·0007
```

- Generate with `compose`. Never write the header by hand. `compose` also appends the reply requirement.
- `send` and `ui-send` refuse a body without a header (exit 2).
- `wait` returns nonzero on an aborted turn, missing reply, or wrong reply header. Stop and resolve the mismatch before continuing.
- Codex's structured answer to an async user question and its environment/external context injections do not count as a new user turn for `wait`; an ordinary new message still does.
- The receiver number comes from the leading digits of the session title, otherwise the first 8 characters of the ID. A new session's first delivery can use `Codex·新建`; after `locate`, run `wait-number <ID>` and use the assigned number for later deliveries. `wait` accepts `新建` only for the first headed delivery before any assistant reply, even if a bootstrap user message precedes it.

## Pick a channel

| Channel | When | Who can use it |
| --- | --- | --- |
| **Front end, primary**: Claude Computer use `mcp__computer-use__app_*` | Codex app is running; any session, including a new one | Claude sessions with Computer use on |
| **Front end, fallback**: native macOS AX via Swift (`ui-*` commands), with cua-driver for window ID discovery | No Computer use, or it is unavailable | Any agent with a shell, on a Mac with cua-driver installed and authorized |
| CLI, last resort: `send` | No front-end tool, or the Codex app is closed | Any agent with a shell. Only reaches new sessions and sessions the app never loaded |

Why the CLI can't be primary: while the Codex app runs, it holds the write lock on **every** session it has loaded this run, not just the visible one. `send <ID>` then exits 4. Without a front-end tool, fall back to `send --new` and say in the body which session it was meant for.

## One delivery round

| Step | Action | Pass when |
| --- | --- | --- |
| 1 Locate | `find` → ID | Exactly one |
| 2 State check | `status <ID> -n 1` | For Codex UI sending, wait until idle. Claude Desktop `SendMessage` accepts a running target and may queue delivery |
| 3 Mark time | `date -u +%Y-%m-%dT%H:%M:%SZ` → SINCE | — |
| 4 Compose | `compose … --out body.txt` | Exit 0 |
| 5 Send | Front end (below) or `send` | — |
| 6 Verify | `verify <ID> --text <snippet> --since SINCE` | Exit 0. This is the only proof of delivery |
| 7 Wait | `wait <ID> --text <unique delivery snippet> --timeout 900` | Final reply, reply header ✅ |

### Round-trip acceptance

A delivery is complete only when the **originating session** receives the reply read back by `wait`: the sender sends a headed message, `verify` confirms a user message in the target session, and `wait` confirms a normal turn end with the exact reverse `【回复】` header. Return the `wait` result and reply to the originating session; a successful click or `verify` alone is not a completed round trip. If `wait` fails, report the failure in the originating session and do not claim a reply.

### Codex → Claude Code round trip

1. `--app claude find <four-digit number or exact title>` and `status <ID> -n 0`: find the full CLI session ID of one numbered local Claude Desktop session and inspect its state. Send requires that full ID; a number or title alone is refused because remote and local sessions can share names. A running target is allowed; the message may queue until its next tool call.
2. `--app claude compose --from-agent Codex --from-session <five-digit Codex number> --to <Claude ID> --file body.txt --out msg.txt`. Use a unique marker in the body.
3. `--app claude send <Claude ID> --file msg.txt`. It checks the CLI login, desktop/CLI account IDs, the target metadata under the current desktop account, and the disconnected-pair gate without printing credentials. It passes the metadata's `local_…` session ID to one `SendMessage` call and checks the exact `to` and `message` plus the Claude Desktop route receipt. The direct desktop route has no `msg_id`; exit 0 means accepted, not delivered. A CLI error or uncertain receipt is nonzero. Do not retry before `verify`.
4. `--app claude verify <Claude ID> --text <unique marker> --since <SINCE>`, then `--app claude wait <Claude ID> --text <unique marker>`. Claude's SendMessage inbox appears as a peer user record; the helper unwraps it for these checks. A successful `wait` requires `【回复】Claude Code·NNNN → Codex·NNNNN` as the first line of Claude's final reply.
5. For an explicit return delivery, Claude uses `compose` to wrap its reply in a new `【投递】Claude Code·NNNN → Codex·NNNNN` message and sends it with courier's Codex front end. The originating Codex session checks `verify` for that return message; if it answers, Claude can `wait` on that new delivery. A bare `【回复】` cannot be passed to `ui-send`, which requires a delivery header. The initial `--app claude wait` already lets the Codex sender read Claude's answer directly from Claude's record.

The CLI process is a model intermediary: the helper checks its tool arguments after the call, so a malformed call may already have run. It never retries automatically. Use the destination log readback to confirm the actual delivery.

Destinations are desktop Apps only: Codex binds `com.openai.codex` and its native window; Claude send resolves a local Claude Desktop session. Browser extensions, web ChatGPT/Codex, and remote or cloud Claude sessions are not delivery targets. DSH delivery uses CrossLab's `codex-relay` / `claude-relay`, addressed to a DSH App session; courier does not send to DSH.

### Front end with Computer use

1. `request_access` for `com.openai.codex` only. Use background `app_*` tools only. No `request_full_control`, no clipboard, no link clicks.
2. `app_ax_find` searches **the last screenshot**. Before every click or write, take `app_screenshot` at scale 0.1 (tiny, still returns element indices). After a click, wait about 1.5 s for the UI to switch, then screenshot again.
3. Switch session: `app_ax_find title_contains=<title>` → `app_click` with `element_index`. Never reuse old coordinates: the sidebar shifts when sessions are added. Confirm the target from the tab title. `app_list_windows` titles can lag, and so can screenshots, so read the tab via `app_zoom` or cua-driver.
4. Write: `app_ax_find role=AXTextArea` gives the index and the placeholder (its title, which depends on language and page). `app_type` with `overwrite_existing: true`. **The replaced text returned must equal the placeholder**, a trailing newline allowed. Anything else is the user's draft: write it back exactly and stop to ask.
5. Send: run `overlay check --from '<sender token>' --to '<Codex recipient token>'` before writing or pressing Send. Exit 5 means the pair is disconnected. For supported numbered Claude Code/Codex senders, run `overlay pair --from '<sender token>' --to '<Codex recipient token>' --state sending` immediately before `app_key combo=return` on the input's `element_index`. The visual hook is optional. Verify delivery from the log.
6. New session: click the new-chat button (found via `app_ax_find`), write, press return, then `locate --text <snippet> --since SINCE` to get the ID. Next run `wait-number <ID> --timeout 90` and do not address the session by number until it returns 0. If it times out, report `编号未就绪`.
7. If Codex is frontmost, wait up to 30 seconds for it to leave the foreground. If it stays frontmost, stop without switching or writing. If it comes forward during a switch, stop and restore the original view only when safe to identify; report when restoration cannot be confirmed.

### Front end with native AX (fallback, no screenshots)

`ui-switch` and `ui-send` wait up to 30 seconds for Codex to leave the foreground; `--front-timeout <seconds>` changes the limit. If Codex stays in front, they refuse without switching or writing. The bridge checks again immediately before pressing or writing, and stops if Codex becomes frontmost during a switch; it attempts to return to the original tab when the tab and input remain safe to identify.

The foreground guard reads `NSWorkspace.frontmostApplication` first. If that read fails, it checks whether any active cua-driver process has Codex's exact bundle ID. Multiple active processes of another App do not block delivery; a known frontmost Codex App does.

`ui-switch "<exact title>"` → `ui-send --file body.txt --session-id <ID> --expect-tab "<exact title>"`. The helper addresses existing indexed sessions only. It gets the visible window ID from cua-driver and checks its owner PID and on-screen state directly with `CGWindowListCopyWindowInfo`. The Swift bridge resolves the ID of each native `AXWindows` element through a runtime-loaded private macOS Accessibility symbol and requires exactly one match. If that symbol is unavailable, it falls back to comparing the fresh WindowServer bounds with AX position and size; multiple matches refuse. If no AX window matches after an idle period, one read-only filtered CuaDriver window snapshot wakes accessibility before a single binding retry; no match on retry refuses. Every control is found inside the matched window. Unmatched windows, missing or conflicting current titles, and ambiguous composer or Send controls cause refusal. Codex 26.1029 reads the current title from Chat toolbar static text and cross-checks the AXWindow title; older AXRadioButton layouts remain supported. Duplicate exact-title sidebar buttons within the bound window are allowed, with a 3-second post-click title poll. If the target is absent and the unique Recent section is collapsed, `ui-switch` expands it, finds the target, switches, then collapses it and rechecks the target title before reporting success. If the section cannot be restored, switching returns nonzero and the caller must not send. A ready composer with no target button reports `目标会话按钮不存在（侧栏分区可能折叠）`, separate from a loading timeout. It never uses the ambiguous cua-driver AX tree for control selection and never AXPresses the input field. At cold start it tries AXManualAccessibility, polls for content, and if needed takes one filtered, read-only CuaDriver snapshot to wake Electron accessibility before retrying native AX. `ui-tab`, `ui-switch`, and `ui-send` share a cross-process UI lock.

The native bridge is `scripts/codex_ax.swift`, using only macOS AppKit and ApplicationServices. It reads the body from stdin, writes with `AXValue`, checks the full multiline value and current tab, then AXPresses the unique Send button. If failure occurs after writing but before a successful press, it clears only its own unchanged composer in the same tab and reports `已还原`. An empty composer may expose a placeholder plus newline as AXValue; clearing uses an empty string and checks that Send disappears. If the target or draft changed, `未还原` requires manual inspection. Verify every delivery and reply from rollout records.

The first `ui-*` call compiles the bridge with `swiftc` into a private, source-hashed cache under `~/Library/Caches/agent-courier`; later calls reuse it after file mode and checksum checks. If compilation or cache validation cannot complete, the command interprets the Swift source. This avoids repeated Swift compiler memory peaks while preserving a source fallback.

If `ui-tab` reports `当前在首页，没有打开会话`, the new-chat home is loaded and no session is selected; open the intended session through an authorized front end before sending. A cold-start loading timeout is a separate refusal. `ui-*` errors include a specific safe reason, while raw CuaDriver diagnostics remain hidden because they may contain window text.

### Loop rules (mandatory)

- Act on and reply to a message only when it starts with `【投递】`. **A `【回复】` never triggers an automatic reply**: it goes back to the original sender, who decides the next step.
- At most 5 deliveries per task and per session pair. Stop after two rounds with no progress.
- For Codex UI delivery, never write into a session running a turn (`status` not idle). Claude Desktop `SendMessage` can address a running Claude session; use `verify` and `wait` to observe queued delivery and its reply.
- One writer per app at a time: finish switch, write and send before anyone else touches the same window. `ui-send` checks the tab and the draft every time.
- Anything about money, credentials, changing rules or guardrails, live services, or irreversible actions: stop both sides and ask the user.

## Optional delivery bird (macOS)

The bird defaults off. After `sh overlay/build.sh`, run `python3 -I "$C" overlay on` to enable it, `overlay off` to close it, or `overlay status` to read the setting. The panel's display checkbox uses the same `overlay/config.json` under the courier state directory. `COURIER_OVERLAY=0` or `1` overrides the setting for a command without saving it. Disconnect still blocks delivery with exit 5 when the bird is off.

The rings mark the paired sidebar rows, the dashed line connects them, and the bird flies on delivery and reply. Solid means active, hollow means idle, and gray means disconnected. Click the menu bird to list pairs by App, connect or disconnect an existing pair, or clean invalid pairs. The icon needs existing Input Monitoring access. The bird needs Accessibility to locate rows. Ask fenn to verify physical click-through, focus continuity, and following real window movement before treating those as accepted.

## Follow-up loop

| Final reply | Do |
| --- | --- |
| Step done, more to do | Compose the next message, back to step 2 |
| Wrong or under-evidenced | Send it back: what is wrong, what to add (method, evidence, causal chain) |
| Asks about money, credentials, changing rules or guardrails, or needs the user's decision | **Stop** and relay the question to the user |
| Wants to restart live services or take an irreversible action | Stop and ask the user |
| Two rounds with no progress, or five rounds sent | Stop and report |

## Why it is cheap and fast

- The back end reads JSONL: a few lines of text per check, no images.
- Native AX inspection (`ui-tab`) uses no images. With Computer use, the only image is a 0.1-scale capture before a write or click.
- The CLI channel never touches the UI.

## Report format

Include the session ID, the `verify` line and a short summary of the reply. If you couldn't get something, say so. Never guess.
