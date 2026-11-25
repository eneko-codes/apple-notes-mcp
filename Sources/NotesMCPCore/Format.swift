import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func clip(_ text: String, to width: Int) -> String {
        guard text.count > width else { return text }
        return String(text.prefix(width - 1)) + "…"
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// Hand-rolled so output does not change shape with the machine's locale.
    func stamp(_ date: Date, withYear: Bool = false) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let month = parts.month.map { Self.months[($0 - 1) % 12] } ?? "???"
        let base = String(format: "%02d %@", parts.day ?? 0, month)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return withYear ? "\(base) \(parts.year ?? 0), \(time)" : "\(base) \(time)"
    }

    /// A note with no title of its own still needs something to print.
    static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(untitled)" : trimmed
    }

    /// A note's title as a heading or a receipt shows it. A title is the first line of the
    /// note and can be as long as that line, so it is clipped here; the whole of it is in
    /// the text `note_get` returns.
    static func heading(_ name: String) -> String {
        clip(displayName(name), to: ToolCatalog.headingWidth)
    }

    /// The notice a result carries when `heading` shows less than the whole title, or none.
    static func headingNotices(_ name: String) -> [String] {
        guard displayName(name).count > ToolCatalog.headingWidth else { return [] }
        return [
            Notice.clipped(field: "Title", width: ToolCatalog.headingWidth, tool: ToolCatalog.getName)
        ]
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// What an empty page says when rows exist but the offset skipped all of them.
    static let nothingAtThisOffset = "\n\n  (nothing at this offset)"

    // MARK: Containers

    /// `accounts` is the page to show; `matching` counts every account.
    public func accounts(_ accounts: [AccountInfo], matching: Int) -> String {
        guard matching > 0 else { return "No Notes accounts found." }
        var text = "Accounts: \(matching), ordered by name. They are separate stores: a note"
        text += " cannot be moved from one to another. notes_folders lists the folder paths"
        text += " inside them."
        guard !accounts.isEmpty else { return text + Self.nothingAtThisOffset }

        let width = accounts.map(\.name.count).max() ?? 0
        return text + "\n\n" + accounts.map { account in
            "  \(Self.pad(account.name, to: width))  \(Self.plural(account.folders.count, "folder"))"
        }.joined(separator: "\n")
    }

    /// The widest a path is padded to, so that one long path does not widen every row.
    private static let pathColumn = 40

    /// `folders` is the page to show; `matching` counts every folder the filter let through.
    public func folders(_ folders: [FolderInfo], matching: Int) -> String {
        guard matching > 0 else { return "No folders found." }
        var text = "Folders: \(matching), ordered by account, then path."
        text += " Pass a path exactly as shown as 'folder'."
        guard !folders.isEmpty else { return text + Self.nothingAtThisOffset }

        let width = min(folders.map(\.path.count).max() ?? 0, Self.pathColumn)
        var lines: [String] = []
        var currentAccount: String?
        for folder in folders {
            if folder.account != currentAccount {
                lines.append("")
                lines.append(folder.account)
                currentAccount = folder.account
            }
            var line = "  " + Self.pad(folder.path, to: width)
            line += "  " + Self.plural(folder.noteCount, "note")
            if folder.isShared { line += "  shared" }
            lines.append(line)
        }
        return text + "\n" + lines.joined(separator: "\n")
    }

    // MARK: Notes

    /// `notes` is the page to show; `matching` counts every note that matched among those
    /// the search looked at. `scope` says what was searched, in the caller's own terms.
    public func searchResults(_ notes: [NoteSummary], matching: Int, describing scope: String)
        -> String
    {
        guard matching > 0 else { return "No notes match \(scope)." }
        var text = "\(Self.plural(matching, "note")) · \(scope)"
        text += " · ordered by modification date, newest first, then id."
        guard !notes.isEmpty else { return text + Self.nothingAtThisOffset }
        if notes.contains(where: \.isLocked) {
            text += "\n🔒 marks a locked note: its text cannot be read, so only its title was searched."
        }

        // The account is named only when the page spans more than one: then a path alone
        // does not say which folder a note is in.
        let spansAccounts = Set(notes.map(\.account)).count > 1
        func place(_ note: NoteSummary) -> String {
            spansAccounts ? "\(note.account) / \(note.folderPath)" : note.folderPath
        }
        let dateWidth = notes.map { stamp($0.modified, withYear: true).count }.max() ?? 0
        let folderWidth = min(notes.map { place($0).count }.max() ?? 0, Self.pathColumn)
        return text + "\n\n" + notes.map { note in
            var line = note.isLocked ? "🔒 " : "   "
            line += Self.pad(stamp(note.modified, withYear: true), to: dateWidth)
            line += "  " + Self.pad(place(note), to: folderWidth)
            line += "  " + Self.clip(Self.displayName(note.name), to: ToolCatalog.titleWidth)
            return line + "  id=\(note.identifier)"
        }.joined(separator: "\n")
    }

    /// Whether a row of `notes_search` would show less than the whole of this title.
    static func titleIsClipped(_ note: NoteSummary) -> Bool {
        displayName(note.name).count > ToolCatalog.titleWidth
    }

    /// One note, with a window of its text. `characterOffset` and `maxCharacters` window
    /// `text`, the one part with no natural bound; the caller renders through
    /// `ToolStandard.fitting`, so `maxCharacters` may be less than what was asked.
    public func detail(
        _ note: NoteDetail, text: String, isHTML: Bool, characterOffset: Int, maxCharacters: Int,
        notices: [String]
    ) -> String {
        var notices = notices + Self.headingNotices(note.name)
        var rows: [(String, String?)] = [
            ("folder", "\(note.account) / \(note.folderPath)"),
            ("created", stamp(note.created, withYear: true)),
            ("modified", stamp(note.modified, withYear: true)),
            ("attachments", note.attachmentCount > 0 ? "\(note.attachmentCount)" : nil),
            ("shared", note.isShared ? "yes" : nil),
            ("locked", note.isLocked ? "yes — password protected" : nil),
            ("id", note.identifier),
        ]

        if note.isLocked {
            // Returning an empty body here would read as an empty note, which is a
            // different and much more misleading fact than "this is locked".
            let output = Self.heading(note.name) + "\n" + Self.block(rows) + """


                This note is password protected. Notes lists it but will not give its text
                to a script, so there is nothing to show — the note is not empty. Unlock it
                in Notes.app to read it there.
                """
            return ToolStandard.withNotices(notices, output)
        }

        let window = ToolStandard.window(
            of: text, characterOffset: characterOffset, maxCharacters: maxCharacters,
            label: isHTML ? "HTML" : "Text")
        if let position = window.notice { notices.append(position) }
        // Before the text, because it says what the text is not: the other form of the note.
        rows.append((
            "showing",
            isHTML
                ? "HTML, \(text.count) characters"
                : "plain text, \(text.count) characters; html=true returns the markup"
        ))
        return ToolStandard.withNotices(
            notices, Self.heading(note.name) + "\n" + Self.block(rows) + "\n\n" + window.text)
    }

    /// `attachments` is the page to show; `matching` counts every attachment of the note.
    public func attachments(_ attachments: [AttachmentInfo], matching: Int, of note: NoteDetail)
        -> String
    {
        guard matching > 0 else { return "'\(Self.heading(note.name))' has no attachments." }
        var text = "\(Self.plural(matching, "attachment")) on '\(Self.heading(note.name))',"
        text += " ordered by date added, then id."
        text += " They are listed only; this server cannot save them to disk."
        guard !attachments.isEmpty else { return text + Self.nothingAtThisOffset }

        var lines: [String] = []
        for attachment in attachments {
            lines.append("")
            lines.append("  " + Self.displayName(attachment.name))
            lines.append(
                Self.block([
                    ("added", stamp(attachment.created, withYear: true)),
                    ("modified", stamp(attachment.modified, withYear: true)),
                    ("url", attachment.url),
                    ("in html as", attachment.contentIdentifier),
                    ("shared", attachment.isShared ? "yes" : nil),
                    ("id", attachment.identifier),
                ]))
        }
        return text + "\n" + lines.joined(separator: "\n")
    }

    // MARK: Write receipts

    public func created(_ note: NoteDetail) -> String {
        var output = "Created '\(Self.heading(note.name))'.\n"
        output += Self.block([
            ("folder", "\(note.account) / \(note.folderPath)"),
            ("created", stamp(note.created, withYear: true)),
            ("id", note.identifier),
        ])
        return ToolStandard.withNotices(Self.headingNotices(note.name), output)
    }

    /// Says how the note changed size, because that is the one number that shows a
    /// replace did what was intended — or that it did not.
    public func updated(_ note: NoteDetail, mode: UpdateMode, previousLength: Int) -> String {
        let now = note.plaintext.count
        var output = "Updated '\(Self.heading(note.name))' (\(mode.rawValue)).\n"
        output += Self.block([
            ("folder", "\(note.account) / \(note.folderPath)"),
            ("text length", "\(previousLength) → \(now) characters"),
            ("modified", stamp(note.modified, withYear: true)),
            ("id", note.identifier),
        ])
        if mode == .replace {
            output += "\n\nThe previous content is gone; this server cannot bring it back."
        }
        return ToolStandard.withNotices(Self.headingNotices(note.name), output)
    }

    public func moved(_ note: NoteDetail, from previousFolder: String) -> String {
        var output = "Moved '\(Self.heading(note.name))'.\n"
        output += Self.block([
            ("from", previousFolder),
            ("to", "\(note.account) / \(note.folderPath)"),
            ("id", note.identifier),
        ])
        return ToolStandard.withNotices(Self.headingNotices(note.name), output)
    }

    /// What a receipt says when it repeats only the start of a deleted note's text. The
    /// standard's window notice would name an argument for the rest, and there is none: a
    /// second call cannot read a note that is gone.
    static func deletedTextNotice(shown: Int, total: Int) -> String {
        "Text: characters 1–\(shown) of \(total). The rest is not in this receipt, and this "
            + "server cannot read a deleted note. Notes.app may still hold it in Recently Deleted."
    }

    /// The receipt is the only record left of something this server cannot undo, so it
    /// repeats the start of the note's text rather than just its title. `textWidth` is how
    /// much of it; the caller renders through `ToolStandard.fitting`. A title clipped in
    /// the first line needs no notice of its own: it is the first line of that text.
    public func deleted(_ note: NoteDetail, textWidth: Int) -> String {
        var output = "Deleted '\(Self.heading(note.name))'. This server cannot undo it.\n"
        output += Self.block([
            ("folder", "\(note.account) / \(note.folderPath)"),
            ("created", stamp(note.created, withYear: true)),
            ("modified", stamp(note.modified, withYear: true)),
            ("attachments", note.attachmentCount > 0 ? "\(note.attachmentCount)" : nil),
            ("id", note.identifier),
        ])
        let shown = String(note.plaintext.prefix(textWidth))
        output += "\n\nThe text it held:\n\n" + shown
        let total = note.plaintext.count
        guard shown.count < total else { return output }
        return ToolStandard.withNotices(
            [Self.deletedTextNotice(shown: shown.count, total: total)], output)
    }

    // MARK: Status

    public func status(
        _ state: NotesAvailability, binaryPath: String, configuration: Configuration
    ) -> String {
        let headline: String
        switch state {
        case .ready: headline = "Notes: RUNNING, automation permitted."
        case .notInstalled: headline = "Notes: NOT INSTALLED."
        case .notRunning: headline = "Notes: NOT RUNNING."
        case .automationDenied: headline = "Notes automation: DENIED."
        case .consentNotGranted: headline = "Notes automation: not requested yet."
        }

        var text = headline + "\n\n"
        // The effective configuration: a limit that never reached the process is
        // otherwise invisible.
        text += Self.block([
            ("binary", binaryPath),
            ("target", ScriptingBridgeNoteStore.bundleIdentifier),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("folders", "every folder is reachable"),
            ("scan ceiling", "\(configuration.scanCeiling) notes in one notes_search"),
            ("scan time", "\(NoteTools.scanBudget.components.seconds) seconds in one notes_search"),
            ("time limit", "\(NoteTools.defaultTimeout.components.seconds) seconds for any call"),
            ("default max_characters", "\(configuration.textLimit) in note_get"),
            ("default limit", "\(configuration.searchLimit) in notes_search"),
        ])
        if state != .ready {
            text += "\n\n" + ToolError.availabilityMessage(state)
        }
        return text
    }
}
