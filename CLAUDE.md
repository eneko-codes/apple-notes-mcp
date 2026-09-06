# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THE OWNER'S NOTES ARE NOT YOURS TO EDIT

**It is FORBIDDEN to modify, move or delete any note the owner wrote.** This rule outranks
every other instruction in this file. It applies to every agent and every session, with no
"just this once" and no putting-it-back-afterwards.

A note is not recoverable the way a file is. `update_note` in replace mode overwrites the
body in place, and Notes offers no version history to undo it from.

Never:

- update, move or delete a pre-existing note, for any reason, however small the change;
- read a real note to "see what the shape is" — the fixtures show the shape;
- create a folder, or write into a folder the owner did not sanction;
- read the Notes store directly from disk;
- leave anything behind that was not there when the session started.

**One narrow exception, granted by the owner.** A temporary test note may be created,
exercised and deleted, provided that:

- its first line marks it as disposable at a glance (`ZZTest …`), since Notes takes a note's
  name from its first line;
- it goes in a folder the owner named for the purpose, never the default one;
- it is deleted in the same session that made it, even if the session is going badly;
- the owner is told it existed and that it is gone.

The exception covers notes this agent created and nothing else.

**Fixtures first, always.** `FakeNoteStore` drives the whole tool layer with invented names
and bodies, and that is where a change is proven. Reach for a live test only for code the
fake cannot reach at all — everything below the `NoteStore` seam, where
`ScriptingBridgeNoteStore` talks to Apple.

Allowed without asking, because none of it touches a note:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests run against the in-memory fake |
| `initialize`, `tools/list` over stdio | Protocol only; no Apple event is sent |
| `sdef /System/Applications/Notes.app` | Prints the dictionary |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification against real notes remains the **owner's** job, by hand, with MCP
Inspector. `verification.md` is the script for it.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Notes app through Apple
events. There is no network, no credential and no cloud API: iCloud is only the sync engine
that fills the local store, and the gate is TCC consent for Automation.

Notes has no framework a separate process can use, so this server drives Notes.app itself.
**Notes must be running, and this server never launches it** — starting an application on
someone's behalf is a side effect they did not ask for.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-notes-mcp | grep NSAppleEventsUsageDescription
```

## Architecture

`Sources/NotesMCPCore` holds everything; `Sources/apple-notes-mcp/main.swift` is a launcher
that exists only because a Swift executable target cannot be imported by a test target.

**`Sources/NotesBridge` is Objective-C, and not by preference.** Apple documents one way to
create a scriptable object — `classForScriptingClass:`, `alloc`/`initWithProperties:`, then
insert it in the container — and that pattern cannot be written in Swift: the class returned
is an `SBPseudoClass`, and a Swift metatype cast against it aborts the process
(swiftlang/swift#43407). Only Foundation types cross back.

**`NoteStore` is the seam.** Dispatch, formatting and argument decoding never send an Apple
event, so the tool layer is fully testable against `FakeNoteStore`.

## Invariants worth protecting

- **`update_note` requires an explicit `mode`.** Append and replace are both legitimate and
  wildly different, and the failure mode of guessing is a long note silently overwritten.
  Neither the model nor a slip may default into destruction; a test asserts the refusal.
- **Append reads the existing body first.** That is why `fetch` takes `includeHTML` — an
  append has to have the whole body to work from, and it is the only path that pays for the
  HTML.
- **`note_get` returns plaintext by default.** The HTML of a long note is many times the
  size of its plaintext and is only needed to render or to append. HTML is opt-in.
- **Every folder is visible; there is no allow-list any more.** The owner's plug-and-play
  rule removed "Folders Claude may use" from the extension's settings. `search` still takes
  an explicit `folderPaths` array where **an empty array scans nothing** — an unqualified
  search is expanded to every folder that exists before it reaches the store, rather than
  passed down as "everywhere" for the store to interpret. A test asserts the folders
  actually reaching the store, not just the rendered output.
- **A locked note is visible but unreadable.** Say so. Returning empty text would look like
  an empty note rather than a sealed one.
- **A note has no separate title.** Notes derives the name from the first line of the body,
  so `NoteDraft` carries only `bodyHTML`: two sources of truth for the same fact drift
  apart.
- **Tags and pinning do not exist here.** Notes' scripting dictionary exposes neither, so
  they need the Shortcuts server. Do not fake them, and keep the tool descriptions saying
  so.
- **No property may declare a union `type`.** A test walks the whole catalogue.
- **stdout carries JSON-RPC and nothing else.**

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce `dist/apple-notes-mcp.mcpb`. The
manifest's `tools` array creates the per-tool switches in Claude Desktop and is read before
the server has ever run.

There is no `user_config` and `mcp_config.args` is empty: every former setting, including
"Folders Claude may use", is now a constant in `Configuration` or gone outright, per the
owner's plug-and-play rule. The only place left for a person to change this server's
behaviour is the per-tool permission switch.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, so the child is
**its own TCC subject** and cannot borrow the host app's usage descriptions. Hence the
embedded `Resources/Info.plist` and its `NSAppleEventsUsageDescription`; without it macOS
denies Apple events **without ever prompting**.

macOS only raises the Automation dialog when a real Apple event is sent, which is why
`consentNotGranted` does not block a call: refusing it would mean the dialog never appears
and the permission could never be granted at all.

**A linker-signed binary gets no TCC prompt.** `pack.sh` re-signs and prints the designated
requirement; an empty line there means the build is broken in a way nothing else will show.

## MCP servers

Applies to any repository shipping an MCP server or Claude extension: an `initialize` handler, a tool catalogue, or a manifest packed into a `.mcpb`.

**Shipping a rebuild**

- **ALWAYS bump the version before packing.** The installer keys on the manifest `version` alone, so a changed build under an already-installed version offers only "Uninstall" — which removes the extension instead of updating it.
- **Three files carry the version and must agree:** the manifest `version`, the server's own version constant (what `initialize` and the status tool report), and `CFBundleShortVersionString` in `Resources/Info.plist`. A test asserts all three; keep it.
- **Installing does not restart the server.** The running process serves the old binary until the client is fully quit and reopened, so a fix can appear to fail while the old code is still answering. Verify what is actually running (`ps`, and the binary path the status tool prints) before trusting any result, and ask for a full restart, not just an install.
- **Ad-hoc signing changes the cdhash on every rebuild**, so TCC forgets its grant and prompts again. Expected, not a fault — say so on handover.

**Documentation the model reads**

The server documents itself to a model, which acts on that text and cannot detect that it is wrong. Treat it as code, not prose.

- Update it in the same commit as the behaviour: a new, renamed or removed tool; a change to what a tool does, refuses, defaults to or requires; a change in which permission governs what; a limitation callers must work around.
- Four surfaces, all natural language: the server `instructions`, each tool `description`, each argument `description`, and the manifest's `tools` array and `long_description`. The manifest is read before the server has ever run, so a tool missing from it has no permission switch at all.
- State what the schema cannot convey: which tool to call first, which identifiers go stale and why, what cannot be undone, which permission governs what, and which field to prefer when several would fit.
- None of it takes effect until the client restarts. Say so on handover.
