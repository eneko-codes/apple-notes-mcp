import Foundation

@testable import NotesMCPCore

/// An in-memory `NoteStore`.
///
/// Every test in this suite runs against this double, so the suite never sends an Apple
/// event and never touches a note the owner wrote. Every fixture below is invented.
final class FakeNoteStore: NoteStore, @unchecked Sendable {

    var availabilityValue: NotesAvailability = .ready
    var accountsValue: [AccountInfo] = []
    var notes: [String: NoteDetail] = [:]

    /// Set to make the next call fail, so the error path is reachable.
    var failure: (any Error)?

    // Recorded so a test can prove what a tool actually asked the store to do.
    private(set) var searchedFolders: [[String]] = []
    private(set) var lastScanCeiling: Int?
    private(set) var created: [NoteDraft] = []
    private(set) var replacedBodies: [(identifier: String, html: String)] = []
    private(set) var moved: [(identifier: String, folder: String)] = []
    private(set) var deleted: [String] = []

    func availability() -> NotesAvailability { availabilityValue }

    func accounts() async throws -> [AccountInfo] {
        if let failure { throw failure }
        return accountsValue
    }

    func search(
        query: String?, folderPaths: [String], account: String?, from: Date?, to: Date?,
        dateField: NoteDateField, limit: Int, scanCeiling: Int
    ) async throws -> NoteSearchPage {
        if let failure { throw failure }
        searchedFolders.append(folderPaths)
        lastScanCeiling = scanCeiling

        // An empty folder list scans nothing. Mirroring that here is the point: a scope
        // that fails open is worse than one that errors, and this is where it would leak.
        guard !folderPaths.isEmpty else { return NoteSearchPage(results: [], total: 0) }

        var matched = notes.values.filter { folderPaths.contains($0.folderPath) }
        if let query = query?.lowercased(), !query.isEmpty {
            matched = matched.filter {
                $0.name.lowercased().contains(query) || $0.plaintext.lowercased().contains(query)
            }
        }
        if let from { matched = matched.filter { $0.modified >= from } }
        if let to { matched = matched.filter { $0.modified <= to } }

        let sorted = matched.sorted { $0.modified > $1.modified }
        return NoteSearchPage(
            results: sorted.prefix(limit).map(\.summary), total: sorted.count,
            hitScanLimit: sorted.count > scanCeiling)
    }

    func fetch(identifier: String, includeHTML: Bool) async throws -> NoteDetail? {
        if let failure { throw failure }
        guard let note = notes[identifier] else { return nil }
        guard includeHTML else {
            return NoteDetail(
                identifier: note.identifier, name: note.name, folderPath: note.folderPath,
                account: note.account, created: note.created, modified: note.modified,
                isLocked: note.isLocked, isShared: note.isShared,
                attachmentCount: note.attachmentCount, plaintext: note.plaintext, html: nil)
        }
        return note
    }

    func attachments(identifier: String) async throws -> [AttachmentInfo] {
        if let failure { throw failure }
        return []
    }

    func create(_ draft: NoteDraft) async throws -> NoteDetail {
        if let failure { throw failure }
        created.append(draft)
        let identifier = "x-coredata://invented/\(created.count)"
        let note = Fixtures.note(
            id: identifier, name: String(draft.bodyHTML.prefix(40)), folder: draft.folderPath,
            text: draft.bodyHTML)
        notes[identifier] = note
        return note
    }

    func replaceBody(identifier: String, html: String) async throws -> NoteDetail {
        if let failure { throw failure }
        replacedBodies.append((identifier: identifier, html: html))
        guard let existing = notes[identifier] else { throw ToolError.storeFailure("gone") }
        let updated = NoteDetail(
            identifier: existing.identifier, name: existing.name,
            folderPath: existing.folderPath, account: existing.account,
            created: existing.created, modified: existing.modified, isLocked: existing.isLocked,
            isShared: existing.isShared, attachmentCount: existing.attachmentCount,
            plaintext: html, html: html)
        notes[identifier] = updated
        return updated
    }

    func move(identifier: String, toFolderPath: String, account: String?) async throws
        -> NoteDetail
    {
        if let failure { throw failure }
        moved.append((identifier: identifier, folder: toFolderPath))
        guard let existing = notes[identifier] else { throw ToolError.storeFailure("gone") }
        return existing
    }

    func delete(identifier: String) async throws -> NoteDetail {
        if let failure { throw failure }
        deleted.append(identifier)
        guard let existing = notes[identifier] else { throw ToolError.storeFailure("gone") }
        notes.removeValue(forKey: identifier)
        return existing
    }
}

// MARK: - Fixtures

enum Fixtures {

    static let now = date(2026, 8, 9, 12, 0)

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Invented throughout. Nothing here is taken from the owner's Notes.
    static func note(
        id: String, name: String, folder: String, text: String, locked: Bool = false,
        modified: Date = now
    ) -> NoteDetail {
        NoteDetail(
            identifier: id, name: name, folderPath: folder, account: "iCloud",
            created: date(2026, 8, 1, 9, 0), modified: modified, isLocked: locked,
            isShared: false, attachmentCount: 0, plaintext: text, html: "<div>\(text)</div>")
    }

    static let accounts: [AccountInfo] = [
        AccountInfo(
            name: "iCloud", identifier: "acct-1",
            folders: [
                FolderInfo(
                    name: "Notes", path: "Notes", identifier: "f-1", account: "iCloud",
                    isShared: false, noteCount: 2),
                FolderInfo(
                    name: "Private", path: "Private", identifier: "f-2", account: "iCloud",
                    isShared: false, noteCount: 1),
            ])
    ]
}
