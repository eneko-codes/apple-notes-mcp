import AppKit
import Foundation
import NotesBridge

/// `NoteStore` backed by the real Notes app, driven through Apple events.
///
/// Nothing here reads the notes database directly: every read is Notes doing the work and
/// handing back the result. That is why Notes has to be running, and why everything is
/// bounded — an unbounded walk over a large library will appear to hang.
///
/// The Apple events themselves live in the `NotesBridge` Objective-C target; see its
/// header for why they cannot live in Swift. What stays here is the mapping between
/// Notes' loose dictionaries and this server's value types, plus the decisions the bridge
/// deliberately does not make: how a query matches, in what order results come back, and
/// which folder a note is really in.
public struct ScriptingBridgeNoteStore: NoteStore {
    public static let bundleIdentifier = "com.apple.Notes"

    public init() {}

    // MARK: Availability

    public func availability() -> NotesAvailability {
        guard
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) != nil
        else { return .notInstalled }

        // "Not running" is checked before consent, and the order matters. Consent is
        // reported as pending until the first Apple event, and that event would launch
        // Notes — starting an app on the owner's behalf is exactly the side effect this
        // server refuses to have. Answering `.notRunning` first keeps the refusal ahead of
        // the launch.
        guard NotesBridge.isNotesRunning else { return .notRunning }

        switch Self.automationPermission() {
        case OSStatus(errAEEventNotPermitted): return .automationDenied
        case OSStatus(errAEEventWouldRequireUserConsent): return .consentNotGranted
        case OSStatus(procNotFound): return .notRunning
        default: return .ready
        }
    }

    /// Asks TCC whether this process may drive Notes, **without sending a real event and
    /// without raising a dialog** (`askUserIfNeeded: false`). That is what lets
    /// `notes_status` be honest about permissions while reading no notes at all.
    static func automationPermission() -> OSStatus {
        var target = AEAddressDesc()
        let identifier = Data(bundleIdentifier.utf8)
        let created = identifier.withUnsafeBytes { bytes in
            AECreateDesc(typeApplicationBundleID, bytes.baseAddress, bytes.count, &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    }

    private func guardAvailability() throws {
        let state = availability()
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }
    }

    /// The bridge reports failures as `NSError`; the tool layer speaks `ToolError`.
    private func storeFailure(_ error: Error) -> ToolError {
        .storeFailure(error.localizedDescription)
    }

    private func isNoteMissing(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == NotesBridgeErrorDomain
            && failure.code == NotesBridgeError.noteNotFound.rawValue
    }

    // MARK: Accounts and folders

    public func accounts() async throws -> [AccountInfo] {
        try guardAvailability()
        let raw: [[String: Any]]
        do { raw = try NotesBridge.accounts() } catch { throw storeFailure(error) }

        return raw.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let folders = (entry["folders"] as? [[String: Any]] ?? []).compactMap {
                folder -> FolderInfo? in
                guard let path = folder["path"] as? String else { return nil }
                return FolderInfo(
                    name: folder["name"] as? String ?? path,
                    path: path,
                    identifier: folder["id"] as? String ?? "",
                    account: name,
                    isShared: folder["shared"] as? Bool ?? false,
                    noteCount: folder["noteCount"] as? Int ?? 0)
            }
            return AccountInfo(
                name: name, identifier: entry["id"] as? String ?? "", folders: folders)
        }
    }

    // MARK: Search

    public func search(
        query: String?, folderPaths: [String], account: String?, from: Date?, to: Date?,
        dateField: NoteDateField, limit: Int, scanCeiling: Int
    ) async throws -> NoteSearchPage {
        try guardAvailability()
        // An empty folder list means nothing was in scope. Treating it as "everywhere"
        // would turn a restriction into its opposite.
        guard !folderPaths.isEmpty else {
            return NoteSearchPage(results: [], total: 0, hitScanLimit: false)
        }

        let page: [String: Any]
        do {
            page = try NotesBridge.scanFolderPaths(
                folderPaths, inAccount: account, from: from, to: to,
                useCreationDate: dateField == .created,
                // Plaintext is one more Apple event per note, so it is only fetched when
                // there is a query to match it against.
                needsText: query?.isEmpty == false,
                maxScan: scanCeiling)
        } catch { throw storeFailure(error) }

        let scanned = page["scanned"] as? Int ?? 0
        var matches: [NoteSummary] = []
        for raw in page["notes"] as? [[String: Any]] ?? [] {
            guard let identifier = raw["id"] as? String, !identifier.isEmpty else { continue }
            let name = raw["name"] as? String ?? ""
            let isLocked = raw["passwordProtected"] as? Bool ?? false

            if let needle = query, !needle.isEmpty {
                // A locked note's plaintext comes back empty, so it can only ever match on
                // its title — which is the honest outcome, not a silent miss.
                let plaintext = raw["plaintext"] as? String ?? ""
                guard
                    name.localizedCaseInsensitiveContains(needle)
                        || plaintext.localizedCaseInsensitiveContains(needle)
                else { continue }
            }

            matches.append(
                NoteSummary(
                    identifier: identifier,
                    name: name,
                    folderPath: raw["folderPath"] as? String ?? "",
                    account: raw["account"] as? String ?? "",
                    created: raw["creationDate"] as? Date ?? .distantPast,
                    modified: raw["modificationDate"] as? Date ?? .distantPast,
                    isLocked: isLocked,
                    isShared: raw["shared"] as? Bool ?? false))
        }

        matches.sort { $0.modified > $1.modified }
        return NoteSearchPage(
            results: Array(matches.prefix(limit)), total: matches.count,
            hitScanLimit: scanned >= scanCeiling)
    }

    // MARK: One note

    public func fetch(identifier: String, includeHTML: Bool) async throws -> NoteDetail? {
        try guardAvailability()

        let raw: [String: Any]
        do {
            raw = try NotesBridge.note(withIdentifier: identifier, includeHTML: includeHTML)
        } catch where isNoteMissing(error) {
            // Not a failure: a note can be deleted or resynchronised between two calls,
            // which is ordinary. The tool layer turns nil into its own "search again".
            return nil
        } catch {
            throw storeFailure(error)
        }
        return try await detail(from: raw, identifier: identifier, includeHTML: includeHTML)
    }

    public func attachments(identifier: String) async throws -> [AttachmentInfo] {
        try guardAvailability()
        let raw: [[String: Any]]
        do {
            raw = try NotesBridge.attachmentsOfNote(withIdentifier: identifier)
        } catch { throw storeFailure(error) }

        return raw.map { entry in
            let url = entry["url"] as? String ?? ""
            return AttachmentInfo(
                identifier: entry["id"] as? String ?? "",
                name: entry["name"] as? String ?? "",
                contentIdentifier: entry["contentIdentifier"] as? String ?? "",
                url: url.isEmpty ? nil : url,
                created: entry["creationDate"] as? Date ?? .distantPast,
                modified: entry["modificationDate"] as? Date ?? .distantPast,
                isShared: entry["shared"] as? Bool ?? false)
        }
    }

    /// Turns the bridge's dictionary into a `NoteDetail`, resolving the containing folder
    /// to a path.
    ///
    /// The bridge reports the folder by id and name only. Turning that into a path needs
    /// the whole account tree, and doing it here rather than inside the bridge keeps the
    /// bridge thin — it is the part no test can reach.
    private func detail(from raw: [String: Any], identifier: String, includeHTML: Bool)
        async throws -> NoteDetail
    {
        let folderID = raw["folderID"] as? String ?? ""
        let folderName = raw["folderName"] as? String ?? ""
        var folderPath = folderName
        var account = ""
        for entry in try await accounts() {
            if let folder = entry.folders.first(where: {
                !folderID.isEmpty && $0.identifier == folderID
            }) {
                folderPath = folder.path
                account = entry.name
                break
            }
        }

        return NoteDetail(
            identifier: raw["id"] as? String ?? identifier,
            name: raw["name"] as? String ?? "",
            folderPath: folderPath,
            account: account,
            created: raw["creationDate"] as? Date ?? .distantPast,
            modified: raw["modificationDate"] as? Date ?? .distantPast,
            isLocked: raw["passwordProtected"] as? Bool ?? false,
            isShared: raw["shared"] as? Bool ?? false,
            attachmentCount: raw["attachmentCount"] as? Int ?? 0,
            plaintext: raw["plaintext"] as? String ?? "",
            html: includeHTML ? (raw["body"] as? String ?? "") : nil)
    }

    // MARK: Writes

    /// Reads a note back after a write, so a receipt describes what Notes ended up with
    /// rather than what was asked for.
    private func reread(_ identifier: String) async throws -> NoteDetail {
        guard let note = try await fetch(identifier: identifier, includeHTML: false) else {
            throw ToolError.notFound(identifier: identifier)
        }
        return note
    }

    public func create(_ draft: NoteDraft) async throws -> NoteDetail {
        try guardAvailability()
        let identifier: String
        do {
            identifier = try NotesBridge.createNote(
                inFolderPath: draft.folderPath, inAccount: draft.account,
                bodyHTML: draft.bodyHTML)
        } catch { throw storeFailure(error) }
        return try await reread(identifier)
    }

    public func replaceBody(identifier: String, html: String) async throws -> NoteDetail {
        try guardAvailability()
        do {
            try NotesBridge.replaceBodyHTML(html, ofNoteWithIdentifier: identifier)
        } catch where isNoteMissing(error) {
            throw ToolError.notFound(identifier: identifier)
        } catch {
            throw storeFailure(error)
        }
        return try await reread(identifier)
    }

    public func move(identifier: String, toFolderPath: String, account: String?) async throws
        -> NoteDetail
    {
        try guardAvailability()
        do {
            try NotesBridge.moveNote(
                withIdentifier: identifier, toFolderPath: toFolderPath, inAccount: account)
        } catch where isNoteMissing(error) {
            throw ToolError.notFound(identifier: identifier)
        } catch {
            throw storeFailure(error)
        }
        return try await reread(identifier)
    }

    public func delete(identifier: String) async throws -> NoteDetail {
        try guardAvailability()
        // Read first: once it is gone there is nothing left to describe, and the receipt
        // for something irreversible is the only record the caller gets.
        let doomed = try await reread(identifier)
        do {
            try NotesBridge.deleteNote(withIdentifier: identifier)
        } catch where isNoteMissing(error) {
            throw ToolError.notFound(identifier: identifier)
        } catch {
            throw storeFailure(error)
        }
        return doomed
    }
}
