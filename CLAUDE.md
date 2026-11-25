# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify, move or delete an existing note.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real Notes library, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own note and work on that; failing that, ask the owner to make a throwaway one; failing that, work on a copy. Touching what the owner made is the last resort, has to have been named in the ask, and has to be undoable. Anything you are allowed to create must be clearly named `TESTING: ...` (in the first line, since Notes takes the title from it) and removed in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Notes app through Apple events. No network, no credential, no cloud API — iCloud is only the sync engine, gated by TCC consent for Automation. Notes must already be running; this server never launches it. **No third-party dependency**: `Package.swift` lists none, and the MCP protocol (JSON-RPC over stdio) is `MCPServer.swift` over Foundation. Adding a package needs the owner's say-so.

**`MCPServer.swift`, `Value.swift`, `ToolStandard.swift` and the tests `MCPProtocolTests.swift` and `ToolStandardTests.swift` are copied unchanged into every one of the owner's MCP servers** (the test files differ only in their `@testable import`). A change to one is made to every copy in the same piece of work; never let a copy drift.

`ToolStandard.swift` holds what every tool here must keep to: the longest result, description and error, the time a call may take, the fixed wording of each notice that says what a result left out (`Notice`), and the guard `MCPServer.swift` passes every result through. A tool bounds its own result and says how to get the rest; the guard only catches the one that forgot.

## Apple technology

Notes ships no framework an external process can use, so everything is an Apple event. [ScriptingBridge](https://developer.apple.com/documentation/scriptingbridge) — `SBApplication`, `SBElementArray` — for every read and write; `AEDeterminePermissionToAutomateTarget` ([Apple Events](https://developer.apple.com/documentation/coreservices/apple_events)) to check consent without sending an event; [AppKit](https://developer.apple.com/documentation/appkit) `NSWorkspace`/`NSRunningApplication` to see whether the app is there and running. Consent key: [`NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription).

## Native surface not used

`sdef /System/Applications/Notes.app` is the authority on what is possible here. Check it before proposing a tool.

- `show` and `open note location` — both only drive the UI.
- The application's `selection`, `default account` and `default folder`.
- Tags, pinned state and checklist state appear in no class at all: the dictionary cannot express them, so no tool can read or set them. Do not add one that claims to.

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

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary
holds any other architecture. A universal build doubles the bundle for an architecture
macOS 26 is the last release to support. Do not add an x86_64 slice back.

**How a tool keeps to the tool standard here.** Sizes are constants in `ToolCatalog` (the three a command-line flag can change are in `Configuration`), and the schemas, the descriptions and the instructions quote them by interpolation, never as literals; `extension/manifest.json` and `README.md` cannot, so `PackageTests` holds the manifest's figures to the constants. `Arguments.int` moves a size or a count into its range and collects the sentence that says so in `notices`; a value of the wrong type, a day that does not exist and a range that ends before it starts are refused. A listing (`notes_accounts`, `notes_folders`, `notes_search`, `note_attachments`) sorts every row into an order it states, with no ties, then goes through `ToolStandard.page`, which puts the notices and the page's position before the data; `notes_search` builds the same page itself, because it has two more things to say first: that the scan stopped early (`Notice.scanStopped`, `Notice.partial`) and that a title on the page was clipped (`Notice.clipped`). `note_get` windows the note's text with `ToolStandard.window`, and `delete_note` repeats only the start of the text it removed; both render through `ToolStandard.fitting`, so no tool leans on the guard. An error repeats a caller's text, a note's title or a folder's path only through `ToolStandard.echo`. `BoundsTests` holds every bound, notice and length to this: a new listing takes `limit` and `offset` through `Arguments.page` and gets an entry in its `listings`.

**Time.** Notes answers one Apple event after another, so three things bound a call. Scripting Bridge waits about a minute for the reply to one event (its default; this server does not change it). `notes_search` stops walking once `NoteTools.scanBudget` has passed since the call began, and returns what it has with `Notice.partial`; the bridge checks the clock between events. A search names each folder by its account and its path together, never by the path alone: two accounts routinely both have a `Notes`. `NoteTools.handle` answers any call that has not finished after `NoteTools.defaultTimeout` with an error, and abandons the work: an Apple event already sent cannot be taken back, so the error for a write says the change may still have been made.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.
