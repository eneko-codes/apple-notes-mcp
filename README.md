<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-notes-mcp icon">
</p>

# apple-notes-mcp

A local MCP server, written in Swift, exposing the macOS **Notes** app to Claude through
Apple events. It ships as a Claude extension.

Notes has no framework a separate process can use, so this server drives Notes.app itself
through Apple events. Notes must be running, and this server
never launches it: starting an app on your behalf is a side effect you did not ask for.
There is no network, no credential and no cloud API; iCloud is only the sync engine that
fills the local store, and the gate is macOS **Automation** consent.

Not affiliated with or endorsed by Apple Inc.

## Requirements

- macOS 15 or later
- Swift 6.0 or later (Xcode 26 ships it)
- A code signing identity. Ad-hoc works, but every rebuild then asks for permission
  again — see [Signing](#signing-and-why-it-is-not-optional).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `notes_status` | read | Reports whether Notes is running, whether this server may automate it, and what limits are in force. Reads no notes. |
| `notes_accounts` | read | The Notes accounts — iCloud, On My Mac, an Exchange account — in name order, with how many folders each holds. Paged with `limit` and `offset`. |
| `notes_folders` | read | The folders, ordered by account, then path, with their note count and the path to address each by. Nested folders read `Parent/Child`. Paged with `limit` and `offset`. |
| `notes_search` | read | Finds notes by text, folder, account and date (`from_date`, `to_date`). Returns one line per note with its id, the most recently modified first — never the note's contents. Paged with `limit` and `offset`. |
| `note_get` | read | One note's folder, dates and attachment count, then a window of its text: `character_offset` and `max_characters`. Plain text by default; `html=true` for markup. |
| `note_attachments` | read | What is attached to one note, the first added first: name, dates, a URL attachment's link, and the `cid:` reference it appears under in the note's HTML. Paged with `limit` and `offset`. |
| `create_note` | write | Adds a new note to a folder. |
| `update_note` | write | Changes a note's content. `mode` is required: `append` or `replace`. |
| `move_note` | write | Moves a note into a different folder. Content is untouched. |
| `delete_note` | **destructive** | Deletes a note. Requires `confirm: true`. The receipt repeats the start of the text it removed. |

## Frameworks and APIs

Notes ships no framework an external process can use, so everything here is an Apple event.

| Used | For | Reference |
|---|---|---|
| ScriptingBridge — `SBApplication`, `SBElementArray`, `SBApplicationDelegate` | Every read and write | [ScriptingBridge](https://developer.apple.com/documentation/scriptingbridge) |
| `AEDeterminePermissionToAutomateTarget` | Checking Automation consent without sending an event | [Apple Events](https://developer.apple.com/documentation/coreservices/apple_events) |
| AppKit — `NSWorkspace`, `NSRunningApplication` | Whether Notes is installed, and whether it is running | [AppKit](https://developer.apple.com/documentation/appkit) |
| `NSAppleEventsUsageDescription` | The consent string macOS shows | [Information Property List](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription) |

Notes' dictionary (`sdef /System/Applications/Notes.app`) holds four classes — `account`,
`folder`, `note`, `attachment` — and two commands, `show` and `open note location`. Both
commands only drive the UI, so neither is exposed.

## The rules worth knowing before you use it

**`note_get` returns plain text by default.** The same note as HTML is several times
larger for no extra meaning, so HTML is opt-in — pass `html=true` only when the markup
itself matters: before an append, or to see which images are embedded.

**`update_note` requires an explicit `mode`, with no default.** `append` adds text to the
end and keeps everything already there; `replace` **discards the whole note** and writes
the new text instead. Notes keeps no version history a script can reach, so a long note
replaced by a short one cannot be undone from here. If you are editing something that
already exists, read it with `note_get` first and prefer `append` unless replacing it was
actually the point. `create_note` and `update_note` take the body as HTML — plain text
works, but newlines in it are ignored, so wrap each line in `<div>…</div>` or end it with
`<br>`.

**A note has no separate title.** Notes derives a note's name from the first line of its
body, so there is no title argument anywhere in this server. Renaming a note means
replacing it with a body whose first line is the new one.

**A password-protected note is reported as locked, not as empty.** Its text cannot be read
by any tool here, `notes_search` never matches `query` against it, and no write tool will
touch one — `update_note` and `delete_note` both refuse it outright, because neither could
honestly say what it changed.

**Tags, pinned state and checklist state do not exist here.** Notes' scripting dictionary
exposes none of them, so this server cannot read or set them. No tool description implies
otherwise.

**Every folder is reachable; there is no allow-list.** `notes_search` still takes an
explicit `folder` argument, and an unqualified search is expanded to every folder that
exists before it reaches Notes — never passed down as "everywhere" for Notes to interpret.
Each folder goes to Notes with its account, because two accounts routinely both have a
`Notes`: a `folder` that several accounts have is searched in each of them unless `account`
names one, and the rows then say which account a note is in.

**Searches are slow, and bounded on purpose.** Notes.app itself walks the library and
ships each result back over the Apple event boundary, so an unfiltered search over a large
library is genuinely slow. A search looks at no more than a ceiling of notes (500) and for
no longer than 45 seconds, and says so in the first lines of the result when it stops
early — a truncated answer never comes back looking like a complete one. Notes it never
looked at are not in the result, and the most recent of the notes it did look at is not
necessarily the most recent in the library: narrow by `folder`, `from_date` or `to_date`
and search again.

## How much a result holds

No result is longer than 40,000 characters, and a call with no optional argument returns
about 10,000 or less. Whatever a result leaves out is said in its first lines, in a fixed
wording, with the arguments that return the rest.

| Tool | With no optional argument | The rest |
|---|---|---|
| `notes_accounts` | 50 accounts, by name | `limit` (up to 200), `offset` |
| `notes_folders` | 100 folders, by account, then path | `limit` (up to 300), `offset` |
| `notes_search` | 25 notes, newest modification first | `limit` (up to 100), `offset`; `from_date` and `to_date`, both inclusive |
| `note_get` | the first 10,000 characters of the text | `character_offset`, `max_characters` (up to 30,000) |
| `note_attachments` | 20 attachments, first added first | `limit` (up to 100), `offset` |
| `delete_note` | the first 10,000 characters of the text it removed | nothing: read the note with `note_get` first if the whole text has to be kept |

`Showing 1–25 of 312 notes. Pass offset=25 for the next page.` is what a page says;
`Text: characters 1–10000 of 52000. Pass character_offset=10000 for the rest.` is what a
window says. A title longer than 60 characters is clipped in a search row, and the result
says so. A size or a count outside its range is moved to the nearest allowed value and the
result says which was used; a value of the wrong type, a day that does not exist and a
range that ends before it starts are refused.

A call that has not finished after 120 seconds is answered with an error and abandoned.
For a tool that reads, nothing was changed. For a tool that writes, the Apple event may
already have reached Notes, so the error says to look before trying again.

**Renamed in 2.0.0.** `notes_search` takes `from_date` and `to_date` where it took `from`
and `to`, and `note_get` takes `max_characters` where it took `text_limit`. The old names
are no longer read.

## Install

### 1. Build the bundle

```bash
security find-identity -v -p codesigning   # copy the 40-character hash of an Apple Development or Developer ID Application identity
MCPB_SIGN_IDENTITY="<identity hash>" ./scripts/pack.sh
```

Pass the hash, not the certificate's name: `pack.sh` prints the identity it signs with,
and the name is yours.

That builds an arm64 (Apple silicon only) release binary, signs it, checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-notes-mcp.mcpb`. It fails loudly rather than shipping a bundle that
would silently refuse to work.

### 2. Install it

Open `dist/apple-notes-mcp.mcpb` with Claude. Then **quit Claude Desktop completely and
reopen it** — reinstalling does not replace a server process that is already running, and
the old one keeps answering.

### 3. Grant the permission

Open Notes first; the server will not launch it for you.

Call `notes_status`. It reports the permission state via
`AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`, so it never sends a
real Apple event and is always safe to call first when something is failing.

Then call any tool that actually reads notes — `notes_accounts` is a good first one.
macOS raises *"apple-notes-mcp wants to control Notes"*. Approve it, and the grant appears
under System Settings → Privacy & Security → Automation
(Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Automatización).

The binary is **its own privacy subject**: Claude Desktop launches MCP servers through
`Contents/Helpers/disclaimer`, so the child cannot inherit the host app's usage
descriptions. Sending Apple events needs `NSAppleEventsUsageDescription`, embedded at link
time in `Resources/Info.plist`.

If no dialog ever appears:

```bash
otool -P extension/server/apple-notes-mcp | grep NSAppleEventsUsageDescription
```

### Signing, and why it is not optional

`swift build` leaves a signature the linker generated, flagged `linker-signed`. macOS
treats that as signed by nobody: it produces **no designated requirement**, so there is
nothing to anchor a permission to except the binary's cdhash — and every rebuild changes
that. Worse, a linker-signed binary never gets a consent dialog at all; the request
returns with the status still "not determined".

Signing with a real certificate produces a requirement anchored to the bundle identifier
and the certificate instead:

```
designated => identifier "codes.eneko.apple-notes-mcp" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

That survives rebuilds. `pack.sh` prints the requirement on every build, so a silent
regression to ad-hoc is visible immediately.

**Changing certificate re-prompts once.** The requirement quotes the certificate, so
moving between ad-hoc, Apple Development and Developer ID each costs one fresh round of
consent.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="<Developer ID Application hash>" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires.
`pack.sh` applies `Resources/entitlements.plist` automatically when that file is present —
this repository does not currently ship one, so a hardened build here has not been
verified against a live Automation grant. A hardened build that sends Apple events needs
the `com.apple.security.automation.apple-events` entitlement; add it before shipping one.

## Tool switches

Plug and play: there is nothing to configure. Every folder is reachable. `Configuration`
parses `--scan-ceiling` (how many notes a search looks at), `--text-limit` (how many
characters `note_get` returns when `max_characters` is not passed) and `--search-limit`
(the page of `notes_search` when `limit` is not passed), but the extension's
`mcp_config.args` is empty, so as installed the defaults are what you get — they apply only
if you run the binary yourself with your own arguments. `notes_status` reports the values in
force.

Every tool can be turned on and off individually, because the bundle declares them all in
its manifest. That is where policy lives — not in this code. Turning off `create_note`,
`update_note`, `move_note` and `delete_note` leaves a strictly read-only server.

**Reinstalling may reset the switches.** Check them after every install.

## Manual registration instead

```json
{
  "mcpServers": {
    "Apple Notes": {
      "command": "/absolute/path/to/apple-notes-mcp/.build/release/apple-notes-mcp"
    }
  }
}
```

You lose the per-tool switches. Do not do both at once: two registrations under the same
display name collide, and `notes_status` prints the binary path precisely so you can tell
which one answered.

## Implementation note: why the Apple events are in Objective-C

Every Apple event this project sends lives in the `NotesBridge` Objective-C target. Apple
documents exactly one way to create
a scriptable object — ask the application for the class with `classForScriptingClass:`,
`alloc`/`initWithProperties:` it, then insert it in the container's element array — and
that pattern **cannot be written in Swift**. The class that comes back is an
`SBPseudoClass`; it inherits from `NSObject`, not `SBObject`, and a Swift metatype cast
against it aborts the process rather than returning nil
([swiftlang/swift#43407][sr795], open since 2016).

In Objective-C none of it arises. Only Foundation types cross back into Swift — no
ScriptingBridge object escapes `NotesBridge.m`. Policy — how a search matches, where it
stops, which folder a note is really in — stays in Swift, where the tests can reach it.

[sr795]: https://github.com/swiftlang/swift/issues/43407

## Known limits

- **Tags, pinning and checklist state are not exposed**, and cannot be — Notes' scripting
  dictionary has no property for any of them.
- **Password-protected notes are read-only in the strictest sense: unreadable.** No tool
  here can see their text, search their text, or write to them at all.
- **A note cannot move between accounts.** iCloud and On My Mac are separate stores;
  `move_note` refuses a cross-account move rather than attempting a copy.
- **Search stops at a scan ceiling and at a time budget** (`notes_status` reports both)
  because Notes, not this process, does the walking. A truncated result says so first.
- **The receipt of a deletion holds only the start of a long note's text.** The note is
  gone by then, so the rest cannot be read through this server.
- **Attachments are listed, not fetched.** Saving one to disk needs a filesystem scope
  this server does not have.
- **Identifiers are not durable across a resync.** Look a note up again with
  `notes_search` rather than reusing an id from an earlier conversation.

## Development

```bash
swift build
swift test
```

The tests run entirely against an in-memory fake (`FakeNoteStore`) with Notes closed. They need no
permissions and never touch a real note — see `CLAUDE.md`, whose first section is the rule
that makes that non-negotiable.

Manual verification against a live Notes library is the owner's job.

## Licence

MIT.
