# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify, move or delete an existing note.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real Notes library, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own note and work on that; failing that, ask the owner to make a throwaway one; failing that, work on a copy. Touching what the owner made is the last resort, has to have been named in the ask, and has to be undoable. Anything you are allowed to create must be clearly named `TESTING: ...` (in the first line, since Notes takes the title from it) and removed in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Notes app through Apple events. No network, no credential, no cloud API — iCloud is only the sync engine, gated by TCC consent for Automation. Notes must already be running; this server never launches it.

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
