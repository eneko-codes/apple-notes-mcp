# Manual verification

Everything below runs against **your real Notes**, which is why no agent may run it (see the
hard rule in `CLAUDE.md`). Work through it yourself, in order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-notes-mcp
```

## 0 — Before you start

In Notes, create a folder named `ZZTest` and put three notes in it:

| Note (first line is the name) | Contents | Why |
|---|---|---|
| `ZZ Tides` | two or three lines of text | the normal path |
| `ZZ Long` | a few hundred words | append versus replace |
| `ZZ Sealed` | anything, then lock it with a password | the locked case |

Make sure Notes is running. Delete the whole `ZZTest` folder when you finish.

## 1 — Permission plumbing

| Step | Call | Expected |
|---|---|---|
| 1.1 | Quit Notes, then `notes_search` | Refused, saying Notes is not running — and Notes **does not launch**. |
| 1.2 | Open Notes, then `notes_search` | The Automation dialog appears, quoting the usage description and naming Notes. |
| 1.3 | Approve, then `notes_status` | Granted. |
| 1.4 | Deny instead (System Settings → Privacy & Security → Automation), restart, call again | Refused with the exact pane to re-enable. |

Step 1.1 matters: an application launching itself because a tool was called is a side effect
nobody asked for, and Notes launching can steal focus mid-sentence.

## 2 — Containers

| Step | Call | Expected |
|---|---|---|
| 2.1 | `notes_accounts` | Your accounts, with folder counts. |
| 2.2 | `notes_folders` | Every folder you have, `ZZTest` among them, with its note count — there is no scope setting to narrow this. |

## 3 — Reading

| Step | Call | Expected |
|---|---|---|
| 3.1 | `notes_search` for a word in `ZZ Tides` | Found, newest first by modification date. |
| 3.2 | `note_get` on it | **Plaintext** — no `<div>`, no HTML entities. |
| 3.3 | `note_get` with `html: true` | HTML this time. |
| 3.4 | `note_get` on `ZZ Sealed` | Says the note is **locked**, not that it is empty. |
| 3.5 | `note_get` on an id that does not exist | Says so. |
| 3.6 | `notes_search` with a date range | Filters correctly; a plain day as the upper bound covers that whole day. |
| 3.7 | `note_attachments` on a note with an image | Lists it. |

Step 3.4 is the difference between "there is nothing here" and "you cannot see this".

## 4 — The append/replace gate

This is what the server is designed around.

| Step | Call | Expected |
|---|---|---|
| 4.1 | `update_note` on `ZZ Long` with a body and **no `mode`** | **Refused**, naming the missing mode. The note is untouched — check in Notes. |
| 4.2 | `update_note` with `mode: "append"` | The new text is added; **everything that was there is still there**. |
| 4.3 | `update_note` with `mode: "replace"` | The body is replaced. |
| 4.4 | Check `ZZ Long`'s name after 4.3 | If the first line changed, so did the note's name — Notes derives one from the other. |

Step 4.1 is the important one. If an update without a mode succeeds, stop and fix it: the
whole point is that a long note cannot be destroyed by an omission.

## 5 — The other writes

| Step | Call | Expected |
|---|---|---|
| 5.1 | `create_note` into `ZZTest` | Created; its name is the first line of what you sent. |
| 5.2 | `move_note` into a different folder | Moved. |
| 5.3 | `delete_note` **without** `confirm` | Refused. The note is still in Notes. |
| 5.4 | `delete_note` with `confirm: true` | Gone from the folder, **present in Recently Deleted**. |
| 5.5 | `update_note` on `ZZ Sealed` | Refused — a locked note cannot be written either. |

## 6 — Tags and pinning, which are absent on purpose

| Step | Call | Expected |
|---|---|---|
| 6.1 | Look for a tag tool in `tools/list` | There is none. |
| 6.2 | Read `note_get`'s output for a tagged note | Tags are not reported, and nothing implies they are available. |

Notes' scripting dictionary exposes neither. They need `apple-shortcuts-mcp`. A server that
pretended otherwise would be worse than one that says so.

## 7 — Packaging

| Step | Command | Expected |
|---|---|---|
| 7.1 | `otool -P .build/release/apple-notes-mcp \| grep NSAppleEventsUsageDescription` | Present. |
| 7.2 | `MCPB_SIGN_IDENTITY="Apple Development: …" bash scripts/pack.sh` | Every check passes; the designated-requirement line is not empty. |
| 7.3 | `codesign -dv extension/server/apple-notes-mcp` | `flags=0x0(none)` — never `linker-signed`. |
| 7.4 | Install, restart Claude Desktop | Ten switches appear, one per tool, and no settings screen — there is nothing left to configure. |

## 8 — Clean up

Delete the `ZZTest` folder, then empty Recently Deleted so nothing lingers. Every folder is
reachable by this server now; the per-tool permission switch in Claude Desktop is the only
thing left to decide deliberately.
