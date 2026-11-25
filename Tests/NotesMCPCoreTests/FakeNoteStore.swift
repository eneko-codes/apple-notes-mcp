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
    var attachmentsValue: [String: [AttachmentInfo]] = [:]

    /// Set to make the next call fail, so the error path is reachable.
    var failure: (any Error)?

    /// Set to make a search run out of time after looking at this many notes.
    var timeRunsOutAfter: Int?

    /// Set to make every call wait on it, as an Apple event that Notes never answers would.
    var blocker: DispatchSemaphore?

    // Recorded so a test can prove what a tool actually asked the store to do.
    private(set) var searchedFolders: [[String]] = []
    private(set) var lastScanCeiling: Int?
    private(set) var lastTimeBudget: Duration?
    private(set) var created: [NoteDraft] = []
    private(set) var replacedBodies: [(identifier: String, html: String)] = []
    private(set) var moved: [(identifier: String, folder: String)] = []
    private(set) var deleted: [String] = []

    /// What every call does first: wait if a test blocked the store, fail if one asked.
    private func enter() throws {
        blocker?.wait()
        if let failure { throw failure }
    }

    func availability() -> NotesAvailability { availabilityValue }

    func accounts() async throws -> [AccountInfo] {
        try enter()
        return accountsValue
    }

    /// Walks the notes in identifier order, which stands in for the order Notes hands
    /// them over in: fixed, and unrelated to their dates. Like the real store it applies
    /// the dates first, stops at the ceiling, and only then matches the text.
    func search(
        query: String?, folders: [FolderInfo], from: Date?, to: Date?,
        dateField: NoteDateField, scanCeiling: Int, timeBudget: Duration
    ) async throws -> NoteScan {
        try enter()
        searchedFolders.append(folders.map(\.path))
        lastScanCeiling = scanCeiling
        lastTimeBudget = timeBudget

        // An empty folder list scans nothing. Mirroring that here is the point: a scope
        // that fails open is worse than one that errors, and this is where it would leak.
        guard !folders.isEmpty else { return NoteScan(matches: [], scanned: 0) }

        func date(_ note: NoteDetail) -> Date { dateField == .created ? note.created : note.modified }
        // One folder at a time, as the real walk goes, so a folder named twice is walked
        // twice and one never named is never walked.
        let candidates = folders.flatMap { folder in
            notes.values
                .filter { $0.folderPath == folder.path && $0.account == folder.account }
                .filter { from == nil || date($0) >= from! }
                .filter { to == nil || date($0) <= to! }
                .sorted { $0.identifier < $1.identifier }
        }

        let outOfTime = timeRunsOutAfter.map { $0 < min(candidates.count, scanCeiling) } ?? false
        let scanned = Array(candidates.prefix(min(scanCeiling, timeRunsOutAfter ?? .max)))
        var matched = scanned
        if let query = query?.lowercased(), !query.isEmpty {
            matched = matched.filter {
                $0.name.lowercased().contains(query) || $0.plaintext.lowercased().contains(query)
            }
        }
        // Shuffled, because the order of a result is the tool layer's to decide.
        return NoteScan(
            matches: matched.reversed().map(\.summary), scanned: scanned.count,
            hitScanLimit: !outOfTime && candidates.count > scanCeiling, reachedTimeLimit: outOfTime)
    }

    func fetch(identifier: String, includeHTML: Bool) async throws -> NoteDetail? {
        try enter()
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
        try enter()
        return attachmentsValue[identifier] ?? []
    }

    func create(_ draft: NoteDraft) async throws -> NoteDetail {
        try enter()
        created.append(draft)
        let identifier = "x-coredata://invented/\(created.count)"
        let note = Fixtures.note(
            id: identifier, name: String(draft.bodyHTML.prefix(40)), folder: draft.folderPath,
            text: draft.bodyHTML)
        notes[identifier] = note
        return note
    }

    func replaceBody(identifier: String, html: String) async throws -> NoteDetail {
        try enter()
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
        try enter()
        moved.append((identifier: identifier, folder: toFolderPath))
        guard let existing = notes[identifier] else { throw ToolError.storeFailure("gone") }
        return existing
    }

    func delete(identifier: String) async throws -> NoteDetail {
        try enter()
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
        account: String = "iCloud", created: Date = date(2026, 8, 1, 9, 0), modified: Date = now
    ) -> NoteDetail {
        NoteDetail(
            identifier: id, name: name, folderPath: folder, account: account,
            created: created, modified: modified, isLocked: locked,
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

// MARK: - Calling a tool

struct ToolResult {
    var text: String
    var isError: Bool
}

/// One `tools/call` against a store, the way the server makes it.
func call(
    _ name: String, _ arguments: [String: Value] = [:], store: FakeNoteStore,
    configuration: Configuration = Configuration(), timeout: Duration = NoteTools.defaultTimeout
) async -> ToolResult {
    let tools = NoteTools(
        store: store, calendar: Fixtures.calendar, configuration: configuration, timeout: timeout)
    let output = await tools.handle(.init(name: name, arguments: arguments))
    return ToolResult(text: output.text, isError: output.isError)
}
