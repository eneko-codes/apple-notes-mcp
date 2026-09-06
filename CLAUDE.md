# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify, move, or delete an existing note. Test notes may be created but must be clearly named `TESTING: ...` (in the first line, since Notes takes the title from it) and cleaned up when done.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Notes app through Apple events. No network, no credential, no cloud API — iCloud is only the sync engine, gated by TCC consent for Automation. Notes must already be running; this server never launches it.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-notes-mcp | grep NSAppleEventsUsageDescription
```
