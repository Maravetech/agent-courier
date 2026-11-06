---
name: courier
description: >-
  Courier (投递): send a message into a chosen Codex desktop-app session, confirm delivery by reading the
  session log, wait for the reply, and keep the task going with follow-ups. Front end: write the Codex input box
  and press send through background accessibility tools, without stealing the user's focus (works for any
  session, including new ones). Back end: read ~/.codex session logs directly, never screenshots.
  Use when the user says "send this to Codex session 00xxx", "tell Codex to continue", "check what Codex did",
  "投递给 Codex", or "发到 codex 的 session".
---

# Courier

**One line**: the front end sends (UI or CLI); the back end reads the session log to confirm; repeat until the task is done.

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
| `ui-tab` / `ui-switch <exact title>` / `ui-send --file <body> --session-id <ID> --expect-tab <exact title>` | Fallback front end for an existing session; use `--window-id <ID>` on each command when multiple Codex windows are on screen | `ui-send`: 0 clicked / 2 refused / 1 no send button |
| `--app claude <find\|status\|verify\|wait\|watch\|locate\|compose>` | Read-only Claude desktop session back end (`~/.claude/projects`) | as above |
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
- The receiver number comes from the leading digits of the session title, otherwise the first 8 characters of the ID. A new session's first delivery can use `Codex·新建`; after `locate`, run `wait-number <ID>` and use the assigned number for later deliveries. `wait` accepts `新建` only for the first headed delivery before any assistant reply, even if a bootstrap user message precedes it.

## Pick a channel

| Channel | When | Who can use it |
| --- | --- | --- |
| **Front end, primary**: Claude Computer use `mcp__computer-use__app_*` | Codex app is running; any session, including a new one | Claude sessions with Computer use on |
| **Front end, fallback**: native macOS AX via Swift (`ui-*` commands), with cua-driver for window bounds | No Computer use, or it is unavailable | Any agent with a shell, on a Mac with cua-driver installed and authorized |
| CLI, last resort: `send` | No front-end tool, or the Codex app is closed | Any agent with a shell. Only reaches new sessions and sessions the app never loaded |

Why the CLI can't be primary: while the Codex app runs, it holds the write lock on **every** session it has loaded this run, not just the visible one. `send <ID>` then exits 4. Without a front-end tool, fall back to `send --new` and say in the body which session it was meant for.

## One delivery round

| Step | Action | Pass when |
| --- | --- | --- |
| 1 Locate | `find` → ID | Exactly one |
| 2 Idle check | `status <ID> -n 1` | `回合：空闲` (idle). If running, `wait` first. Don't interrupt |
| 3 Mark time | `date -u +%Y-%m-%dT%H:%M:%SZ` → SINCE | — |
| 4 Compose | `compose … --out body.txt` | Exit 0 |
| 5 Send | Front end (below) or `send` | — |
| 6 Verify | `verify <ID> --text <snippet> --since SINCE` | Exit 0. This is the only proof of delivery |
| 7 Wait | `wait <ID> --text <unique delivery snippet> --timeout 900` | Final reply, reply header ✅ |

### Round-trip acceptance

A delivery is complete only when the **originating session** receives the reply read back by `wait`: the sender sends a headed message, `verify` confirms a user message in the target session, and `wait` confirms a normal turn end with the exact reverse `【回复】` header. Return the `wait` result and reply to the originating session; a successful click or `verify` alone is not a completed round trip. If `wait` fails, report the failure in the originating session and do not claim a reply.

### Front end with Computer use

1. `request_access` for `com.openai.codex` only. Use background `app_*` tools only. No `request_full_control`, no clipboard, no link clicks.
2. `app_ax_find` searches **the last screenshot**. Before every click or write, take `app_screenshot` at scale 0.1 (tiny, still returns element indices). After a click, wait about 1.5 s for the UI to switch, then screenshot again.
3. Switch session: `app_ax_find title_contains=<title>` → `app_click` with `element_index`. Never reuse old coordinates: the sidebar shifts when sessions are added. Confirm the target from the tab title. `app_list_windows` titles can lag, and so can screenshots, so read the tab via `app_zoom` or cua-driver.
4. Write: `app_ax_find role=AXTextArea` gives the index and the placeholder (its title, which depends on language and page). `app_type` with `overwrite_existing: true`. **The replaced text returned must equal the placeholder**, a trailing newline allowed. Anything else is the user's draft: write it back exactly and stop to ask.
5. Send: `app_key combo=return` on the input's `element_index`. "Unverified" is normal. Step 6 is the proof.
6. New session: click the new-chat button (found via `app_ax_find`), write, press return, then `locate --text <snippet> --since SINCE` to get the ID. Next run `wait-number <ID> --timeout 90` and do not address the session by number until it returns 0. If it times out, report `编号未就绪`.
7. If the user is working in Codex right now (Codex frontmost), ask before switching. Return the view to where the user was when done.

### Front end with native AX (fallback, no screenshots)

`ui-switch` and `ui-send` wait up to 30 seconds for Codex to leave the foreground; `--front-timeout <seconds>` changes the limit. If Codex stays in front, they refuse without switching or writing. The bridge checks again immediately before pressing or writing, and stops if Codex becomes frontmost during a switch; it attempts to return to the original tab when the tab and input remain safe to identify.

`ui-switch "<exact title>"` → `ui-send --file body.txt --session-id <ID> --expect-tab "<exact title>"`. The helper addresses existing indexed sessions only. It gets the visible window geometry from cua-driver, then resolves the Codex process by bundle ID and matches a unique native `AXWindows` element by position and size. Every control is found inside that window. Unmatched windows, missing or conflicting current titles, and ambiguous composer or Send controls cause refusal. Codex 26.1029 reads the current title from Chat toolbar static text and cross-checks the AXWindow title; older AXRadioButton layouts remain supported. Duplicate exact-title sidebar buttons within the bound window are allowed, with a 3-second post-click title poll. If the target is absent and the unique Recent section is collapsed, `ui-switch` expands it, finds the target, switches, then collapses it and rechecks the target title before reporting success. If the section cannot be restored, switching returns nonzero and the caller must not send. A ready composer with no target button reports `目标会话按钮不存在（侧栏分区可能折叠）`, separate from a loading timeout. It never uses the ambiguous cua-driver AX tree for control selection and never AXPresses the input field. At cold start it tries AXManualAccessibility, polls for content, and if needed takes one filtered, read-only CuaDriver snapshot to wake Electron accessibility before retrying native AX. `ui-tab`, `ui-switch`, and `ui-send` share a cross-process UI lock.

The native bridge is `scripts/codex_ax.swift`, using only macOS AppKit and ApplicationServices. It reads the body from stdin, writes with `AXValue`, checks the full multiline value and current tab, then AXPresses the unique Send button. If failure occurs after writing but before a successful press, it clears only its own unchanged composer in the same tab and reports `已还原`. An empty composer may expose a placeholder plus newline as AXValue; clearing uses an empty string and checks that Send disappears. If the target or draft changed, `未还原` requires manual inspection. Verify every delivery and reply from rollout records.

### Loop rules (mandatory)

- Act on and reply to a message only when it starts with `【投递】`. **A `【回复】` never triggers an automatic reply**: it goes back to the original sender, who decides the next step.
- At most 5 deliveries per task and per session pair. Stop after two rounds with no progress.
- Never deliver into a session that is running a turn (`status` not idle). Wait for it to return to idle.
- One writer per app at a time: finish switch, write and send before anyone else touches the same window. `ui-send` checks the tab and the draft every time.
- Anything about money, credentials, changing rules or guardrails, live services, or irreversible actions: stop both sides and ask the user.

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
