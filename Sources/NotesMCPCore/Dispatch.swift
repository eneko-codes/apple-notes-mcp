import Foundation
import Synchronization

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never sends an Apple event itself — everything goes through `NoteStore`, which is what
/// lets the tests drive every branch below with Notes closed and no note touched.
public struct NoteTools: ToolHandler {
    private let store: any NoteStore
    private let calendar: Calendar
    private let configuration: Configuration
    private let format: Format
    private let timeout: Duration

    /// How long one search may spend walking notes before it returns what it has. Notes
    /// answers one Apple event after another, so a large folder is slow in proportion.
    public static let scanBudget = Duration.seconds(45)

    /// How long any call may take before it is answered with an error. It is longer than
    /// `scanBudget` by more than the minute Scripting Bridge waits, by default, for the
    /// reply to one Apple event, so a search that runs out of time while one event is in
    /// flight still returns its partial result; and it is inside `ToolStandard.timeLimit`.
    public static let defaultTimeout = Duration.seconds(120)

    public init(
        store: any NoteStore, calendar: Calendar = .current,
        configuration: Configuration = Configuration(),
        timeout: Duration = NoteTools.defaultTimeout
    ) {
        self.store = store
        self.calendar = calendar
        self.configuration = configuration
        self.format = Format(calendar: calendar)
        self.timeout = timeout
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(seconds: Int(timeout.components.seconds), tool: parameters.name),
                tool: parameters.name, since: started)
        }
    }

    private func failure(
        _ error: any Error, tool: String, since started: ContinuousClock.Instant
    ) -> ToolOutput {
        Diagnostics.toolFailed(tool, error: error, since: started)
        let known = error as? ToolError ?? .storeFailure(error.localizedDescription)
        return ToolOutput(text: known.message, isError: true)
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        // Reports availability instead of failing on it: this is the tool you reach for
        // precisely when the others are refusing to work.
        if parameters.name == ToolCatalog.statusName {
            return format.status(
                store.availability(), binaryPath: Self.binaryPath, configuration: configuration)
        }
        guard ToolCatalog.names.contains(parameters.name) else {
            throw ToolError.unknownTool(parameters.name)
        }

        let state = store.availability()
        // A call whose consent has never been asked for still has to go through: sending
        // the Apple event is what raises the dialog.
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }

        switch parameters.name {
        case ToolCatalog.accountsName: return try await accounts(arguments)
        case ToolCatalog.foldersName: return try await folders(arguments)
        case ToolCatalog.searchName: return try await search(arguments)
        case ToolCatalog.getName: return try await get(arguments)
        case ToolCatalog.attachmentsName: return try await attachments(arguments)
        case ToolCatalog.createName: return try await create(arguments)
        case ToolCatalog.updateName: return try await update(arguments)
        case ToolCatalog.moveName: return try await move(arguments)
        case ToolCatalog.deleteName: return try await delete(arguments)
        default: throw ToolError.unknownTool(parameters.name)
        }
    }

    // MARK: Reads

    /// The order of every listing of names: "Folder 2" before "Folder 10", ignoring case,
    /// and the plain comparison when that calls two different names equal.
    static func namePrecedes(_ lhs: String, _ rhs: String) -> Bool? {
        switch lhs.compare(rhs, options: [.caseInsensitive, .numeric]) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs == rhs ? nil : lhs < rhs
        }
    }

    private func accounts(_ arguments: Arguments) async throws -> String {
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultAccountLimit, limits: ToolCatalog.accountLimitRange)
        // By name, then by identifier so that two accounts of one name never tie.
        let all = try await store.accounts().sorted {
            Self.namePrecedes($0.name, $1.name) ?? ($0.identifier < $1.identifier)
        }
        return ToolStandard.page(
            of: all, limit: page.limit, offset: page.offset, things: "accounts",
            notices: arguments.notices
        ) { format.accounts($0, matching: all.count) }
    }

    private func folders(_ arguments: Arguments) async throws -> String {
        let account = try arguments.optionalString("account")
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultFolderLimit, limits: ToolCatalog.folderLimitRange)
        let visible = try await visibleFolders()
            .filter { account == nil || $0.account == account }
            .sorted {
                Self.namePrecedes($0.account, $1.account) ?? Self.namePrecedes($0.path, $1.path)
                    ?? ($0.identifier < $1.identifier)
            }
        return ToolStandard.page(
            of: visible, limit: page.limit, offset: page.offset, things: "folders",
            notices: arguments.notices
        ) { format.folders($0, matching: visible.count) }
    }

    private func search(_ arguments: Arguments) async throws -> String {
        let started = ContinuousClock.now
        let query = try arguments.optionalString("query")
        let account = try arguments.optionalString("account")
        let folder = try arguments.optionalString("folder")
        let dateField = try arguments.dateField("date_field")
        let from = try arguments.optionalDate("from_date")?.date
        // "On or before 12 August" has to include the whole of the 12th; a bare day parses
        // to midnight, which would exclude it.
        let to = try arguments.optionalDate("to_date").map { parsed in
            parsed.isDateOnly ? endOfDay(parsed.date) : parsed.date
        }
        if let from, let to, to < from {
            throw ToolError.badArgument(
                name: "to_date",
                reason: "it is earlier than from_date. Both are inclusive: pass a from_date "
                    + "that is not after to_date, or only one of the two.")
        }
        let page = try arguments.page(
            defaultLimit: configuration.searchLimit, limits: ToolCatalog.searchLimitRange)

        let folders = try await resolvedSearchFolders(requested: folder, account: account)

        // Finding the folders has already asked Notes for its whole tree, and that time
        // comes out of the same budget: what is left is what the walk may spend.
        let scan = try await store.search(
            query: query, folders: folders, from: from, to: to,
            dateField: dateField, scanCeiling: configuration.scanCeiling,
            timeBudget: max(Self.scanBudget - (ContinuousClock.now - started), .zero))

        // Newest first, then by id: two notes saved in the same second must not swap
        // places between one page and the next.
        let matches = scan.matches.sorted {
            $0.modified == $1.modified ? $0.identifier < $1.identifier : $0.modified > $1.modified
        }

        // Notes the search never looked at count as not returned, so that comes first.
        var notices = arguments.notices
        let narrowing = "folder, from_date or to_date"
        if scan.reachedTimeLimit {
            notices.append(
                Notice.partial(after: scan.scanned, things: "notes", narrowBy: narrowing))
        } else if scan.hitScanLimit {
            notices.append(
                Notice.scanStopped(after: scan.scanned, things: "notes", narrowBy: narrowing))
        }

        // Echoing the scope back means a caller can see that its filters were understood
        // the way it meant them.
        var scope: [String] = []
        if let query { scope.append("'\(ToolStandard.echo(query))'") }
        if let folder { scope.append("in \(ToolStandard.echo(folder))") }
        if let account { scope.append("account \(ToolStandard.echo(account))") }
        if let from { scope.append("\(dateField.rawValue) from \(format.stamp(from, withYear: true))") }
        if let to { scope.append("\(dateField.rawValue) to \(format.stamp(to, withYear: true))") }
        let described =
            scope.isEmpty ? "every folder in scope (\(folders.count))" : scope.joined(separator: " · ")

        return ToolStandard.fitting(page.limit) { size in
            let shown = Array(matches.dropFirst(page.offset).prefix(size))
            var notices = notices
            if let position = Notice.page(
                offset: page.offset, count: shown.count, total: matches.count, things: "notes")
            {
                notices.append(position)
            }
            if shown.contains(where: Format.titleIsClipped) {
                notices.append(
                    Notice.clipped(
                        field: "Title", width: ToolCatalog.titleWidth, tool: ToolCatalog.getName))
            }
            return ToolStandard.withNotices(
                notices, format.searchResults(shown, matching: matches.count, describing: described))
        }
    }

    private func get(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        let wantsHTML = try arguments.bool("html")
        let characterOffset = try arguments.int(
            "character_offset", default: 0, in: ToolCatalog.offsetRange)
        let maxCharacters = try arguments.int(
            "max_characters", default: configuration.textLimit, in: ToolCatalog.maxCharactersRange)
        let note = try await requireVisibleNote(identifier, includeHTML: wantsHTML)

        // The window is cut here rather than in the store so the policy is reachable from
        // a test, and so an append always has the whole body to work from.
        let full = wantsHTML ? (note.html ?? "") : note.plaintext
        return ToolStandard.fitting(maxCharacters) {
            format.detail(
                note, text: full, isHTML: wantsHTML, characterOffset: characterOffset,
                maxCharacters: $0, notices: arguments.notices)
        }
    }

    private func attachments(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultAttachmentLimit, limits: ToolCatalog.attachmentLimitRange)
        let note = try await requireVisibleNote(identifier, includeHTML: false)
        // By the date each was added, then by identifier: Notes promises no order of its
        // own that a second page could rely on.
        let all = try await store.attachments(identifier: note.identifier).sorted {
            $0.created == $1.created ? $0.identifier < $1.identifier : $0.created < $1.created
        }
        return ToolStandard.page(
            of: all, limit: page.limit, offset: page.offset, things: "attachments",
            notices: arguments.notices + Format.headingNotices(note.name)
        ) { format.attachments($0, matching: all.count, of: note) }
    }

    // MARK: Writes

    private func create(_ arguments: Arguments) async throws -> String {
        let folder = try await requireFolder(
            try arguments.requiredString("folder"), account: try arguments.optionalString("account"))
        let draft = NoteDraft(
            folderPath: folder.path, account: folder.account,
            bodyHTML: try arguments.requiredBody("body"))
        return format.created(try await store.create(draft))
    }

    private func update(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        // Decoded before the note is fetched so a missing or misspelt mode is reported
        // without a round trip, and so no path can reach the store with mode unresolved.
        let mode = try arguments.updateMode("mode")
        let body = try arguments.requiredBody("body")

        let existing = try await requireVisibleNote(identifier, includeHTML: true)
        guard !existing.isLocked else {
            throw ToolError.notePasswordProtected(
                name: existing.name, action: mode == .append ? "appending to it" : "replacing it")
        }

        // Read, compose, write. A note edited in Notes.app between those two steps loses
        // that edit, which is inherent to a scripting interface with no compare-and-swap —
        // it is why append exists rather than making the caller send the whole body back.
        let composed: String
        switch mode {
        case .append:
            composed = (existing.html ?? "") + body
        case .replace:
            composed = body
        }

        let updated = try await store.replaceBody(identifier: identifier, html: composed)
        return format.updated(updated, mode: mode, previousLength: existing.plaintext.count)
    }

    private func move(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        let note = try await requireVisibleNote(identifier, includeHTML: false)
        let destination = try await requireFolder(
            try arguments.requiredString("folder"), account: try arguments.optionalString("account"))

        // Refused here rather than left to Notes, which reports it as an opaque Apple
        // event failure that reads like a bug in this server.
        guard destination.account == note.account else {
            throw ToolError.crossAccountMove(from: note.account, to: destination.account)
        }
        guard destination.path != note.folderPath else {
            throw ToolError.badArgument(
                name: "folder",
                reason: "the note is already in '\(ToolStandard.echo(destination.path))'")
        }

        let moved = try await store.move(
            identifier: identifier, toFolderPath: destination.path, account: destination.account)
        return format.moved(moved, from: "\(note.account) / \(note.folderPath)")
    }

    private func delete(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        let note = try await requireVisibleNote(identifier, includeHTML: false)
        guard !note.isLocked else {
            throw ToolError.notePasswordProtected(name: note.name, action: "deleting it")
        }
        guard try arguments.bool("confirm") else {
            throw ToolError.confirmationRequired(action: "Deleting a note")
        }
        let removed = try await store.delete(identifier: identifier)
        return ToolStandard.fitting(ToolCatalog.receiptTextWidth) {
            format.deleted(removed, textWidth: $0)
        }
    }

    // MARK: Folders

    /// Every folder that exists, in every account. There is no allow-list any more — the
    /// owner's plug-and-play rule removed "Folders Claude may use" — so this is just the
    /// one place the folder tree is flattened, kept so a future filter has a single call
    /// site to land on rather than being forgotten at one of several.
    private func visibleFolders() async throws -> [FolderInfo] {
        try await store.accounts().flatMap(\.folders)
    }

    /// Every folder at `path`, one for each account that has it, or the one in `account`.
    /// Throws when there is none.
    private func existingFolders(_ path: String, account: String?) async throws -> [FolderInfo] {
        let everything = try await visibleFolders()
        let matches = everything.filter {
            $0.path.caseInsensitiveCompare(path) == .orderedSame
                && (account == nil || $0.account == account)
        }
        guard !matches.isEmpty else {
            throw ToolError.folderNotFound(path: path, available: everything.map(\.path))
        }
        return matches
    }

    /// The one folder a write goes to. When several accounts have the path and none was
    /// named, the first wins, and the receipt names the account it was.
    private func requireFolder(_ path: String, account: String?) async throws -> FolderInfo {
        try await existingFolders(path, account: account)[0]
    }

    /// The folders one search may walk.
    ///
    /// Never returns an empty array meaning "everywhere": an unqualified search is
    /// expanded to every folder that exists, and an empty result — no folder at all, or
    /// none in the requested account — is an error rather than a silent no-op.
    private func resolvedSearchFolders(requested: String?, account: String?) async throws -> [FolderInfo] {
        if let requested {
            // Every account that has the path, when none was named: searching only the
            // first would leave the others unlooked at with nothing to say so.
            return try await existingFolders(requested, account: account)
        }
        let visible = try await visibleFolders().filter { account == nil || $0.account == account }
        guard !visible.isEmpty else {
            throw ToolError.noFoldersToSearch(account: account)
        }
        return visible
    }

    /// Loads a note. Every tool that takes an id goes through here.
    private func requireVisibleNote(_ identifier: String, includeHTML: Bool) async throws
        -> NoteDetail
    {
        guard let note = try await store.fetch(identifier: identifier, includeHTML: includeHTML)
        else { throw ToolError.notFound(identifier: identifier) }
        return note
    }

    private func endOfDay(_ date: Date) -> Date {
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        return (next ?? date).addingTimeInterval(-1)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
