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

    // MARK: Containers

    public func accounts(_ accounts: [AccountInfo]) -> String {
        guard !accounts.isEmpty else { return "No Notes accounts found." }
        let width = accounts.map(\.name.count).max() ?? 0
        var lines = accounts.map { account -> String in
            let count = account.folders.count
            return "  \(Self.pad(account.name, to: width))  \(count) folder"
                + (count == 1 ? "" : "s")
        }
        lines.append("")
        lines.append(
            "Accounts are separate stores: a note cannot be moved from one to another.")
        lines.append("Call notes_folders for the folder paths inside them.")
        return lines.joined(separator: "\n")
    }

    public func folders(_ folders: [FolderInfo]) -> String {
        guard !folders.isEmpty else { return "No folders found." }

        let width = folders.map(\.path.count).max() ?? 0
        var lines: [String] = []
        var currentAccount: String?
        for folder in folders {
            if folder.account != currentAccount {
                if currentAccount != nil { lines.append("") }
                lines.append(folder.account)
                currentAccount = folder.account
            }
            var line = "  " + Self.pad(folder.path, to: width)
            line += "  \(folder.noteCount) note" + (folder.noteCount == 1 ? "" : "s")
            if folder.isShared { line += "  shared" }
            lines.append(line)
        }
        lines.append("")
        lines.append("Pass a path exactly as shown as 'folder'.")
        return lines.joined(separator: "\n")
    }

    // MARK: Notes

    public func searchResults(_ page: NoteSearchPage, describing scope: String) -> String {
        guard !page.results.isEmpty else {
            var text = "No notes match \(scope)."
            if page.hitScanLimit {
                text +=
                    "\n\nThe scan ceiling was reached before every folder was walked, so"
                    + "\nmatches may exist that were never looked at. Narrow by folder or date."
            }
            return text
        }

        let dateWidth = page.results.map { stamp($0.modified, withYear: true).count }.max() ?? 0
        let folderWidth = min(page.results.map(\.folderPath.count).max() ?? 0, 28)

        var lines = ["\(page.total) note\(page.total == 1 ? "" : "s") · \(scope)"]
        for note in page.results {
            var line = note.isLocked ? "🔒 " : "   "
            line += Self.pad(stamp(note.modified, withYear: true), to: dateWidth)
            line += "  " + Self.pad(Self.clip(note.folderPath, to: folderWidth), to: folderWidth)
            line += "  " + Self.clip(Self.displayName(note.name), to: 60)
            lines.append(line + "  id=\(note.identifier)")
        }

        if page.results.count < page.total {
            lines.append(
                "…\(page.total - page.results.count) more matched · raise 'limit' to see them")
        }
        if page.hitScanLimit {
            // A ceiling that goes unmentioned reads as "this is everything".
            lines.append(
                "⚠ Scan ceiling reached before every folder was walked — more may exist.")
        }
        lines.append("Dates are modification dates. 🔒 marks a locked note: its text is unreadable.")
        return lines.joined(separator: "\n")
    }

    /// One note in full. `text` is already truncated by the caller, which is where the
    /// limit lives so the policy stays testable.
    public func detail(_ note: NoteDetail, text: String, truncated: Bool, isHTML: Bool) -> String {
        var output = Self.displayName(note.name) + "\n"
        output += Self.block([
            ("folder", "\(note.account) / \(note.folderPath)"),
            ("created", stamp(note.created, withYear: true)),
            ("modified", stamp(note.modified, withYear: true)),
            ("attachments", note.attachmentCount > 0 ? "\(note.attachmentCount)" : nil),
            ("shared", note.isShared ? "yes" : nil),
            ("locked", note.isLocked ? "yes — password protected" : nil),
            ("id", note.identifier),
        ])

        if note.isLocked {
            // Returning an empty body here would read as an empty note, which is a
            // different and much more misleading fact than "this is locked".
            output += """


                This note is password protected. Notes lists it but will not give its text
                to a script, so there is nothing to show — the note is not empty. Unlock it
                in Notes.app to read it there.
                """
            return output
        }

        output += "\n\n" + text
        if truncated {
            output += "\n\n[Cut at \(text.count) characters. Raise 'text_limit' to read more.]"
        }
        if !isHTML {
            output += "\n\n[Plain text. Pass html=true for the markup.]"
        }
        return output
    }

    public func attachments(_ attachments: [AttachmentInfo], of note: NoteDetail) -> String {
        guard !attachments.isEmpty else {
            return "'\(Self.displayName(note.name))' has no attachments."
        }
        var lines = [
            "\(attachments.count) attachment\(attachments.count == 1 ? "" : "s") on "
                + "'\(Self.displayName(note.name))'"
        ]
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
        lines.append("")
        lines.append("Attachments are listed only; this server cannot save them to disk.")
        return lines.joined(separator: "\n")
    }

    // MARK: Write receipts

    public func created(_ note: NoteDetail) -> String {
        var output = "Created '\(Self.displayName(note.name))'.\n"
        output += Self.block([
            ("folder", "\(note.account) / \(note.folderPath)"),
            ("created", stamp(note.created, withYear: true)),
            ("id", note.identifier),
        ])
        return output
    }

    /// Says how the note changed size, because that is the one number that shows a
    /// replace did what was intended — or that it did not.
    public func updated(_ note: NoteDetail, mode: UpdateMode, previousLength: Int) -> String {
        let now = note.plaintext.count
        var output = "Updated '\(Self.displayName(note.name))' (\(mode.rawValue)).\n"
        output += Self.block([
            ("folder", "\(note.account) / \(note.folderPath)"),
            ("text length", "\(previousLength) → \(now) characters"),
            ("modified", stamp(note.modified, withYear: true)),
            ("id", note.identifier),
        ])
        if mode == .replace {
            output += "\n\nThe previous content is gone; this server cannot bring it back."
        }
        return output
    }

    public func moved(_ note: NoteDetail, from previousFolder: String) -> String {
        var output = "Moved '\(Self.displayName(note.name))'.\n"
        output += Self.block([
            ("from", previousFolder),
            ("to", "\(note.account) / \(note.folderPath)"),
            ("id", note.identifier),
        ])
        return output
    }

    /// The receipt is the only record left of something this server cannot undo, so it
    /// repeats the note's text rather than just its title.
    public func deleted(_ note: NoteDetail) -> String {
        var output = "Deleted '\(Self.displayName(note.name))'. This server cannot undo it.\n"
        output += Self.block([
            ("folder", "\(note.account) / \(note.folderPath)"),
            ("created", stamp(note.created, withYear: true)),
            ("modified", stamp(note.modified, withYear: true)),
            ("attachments", note.attachmentCount > 0 ? "\(note.attachmentCount)" : nil),
            ("id", note.identifier),
        ])
        output += "\n\nThe text it held:\n\n" + note.plaintext
        return output
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
            ("scan ceiling", "\(configuration.scanCeiling) notes"),
            ("text limit", "\(configuration.textLimit) characters"),
            ("default results", "\(configuration.searchLimit)"),
        ])
        if state != .ready {
            text += "\n\n" + ToolError.availabilityMessage(state)
        }
        return text
    }
}
