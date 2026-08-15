import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never sends an Apple event itself — everything goes through `NoteStore`, which is what
/// lets the tests drive every branch below with Notes closed and no note touched.
public struct NoteTools: Sendable {
    private let store: any NoteStore
    private let calendar: Calendar
    private let configuration: Configuration
    private let format: Format

    public init(
        store: any NoteStore, calendar: Calendar = .current,
        configuration: Configuration = Configuration()
    ) {
        self.store = store
        self.calendar = calendar
        self.configuration = configuration
        self.format = Format(calendar: calendar)
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        // Reports availability instead of failing on it: this is the tool you reach for
        // precisely when the others are refusing to work.
        if parameters.name == ToolCatalog.statusName {
            return format.status(
                store.availability(), binaryPath: Self.binaryPath, configuration: configuration)
        }

        let state = store.availability()
        // A call whose consent has never been asked for still has to go through: sending
        // the Apple event is what raises the dialog.
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }

        switch parameters.name {
        case ToolCatalog.accountsName:
            return format.accounts(try await store.accounts())

        case ToolCatalog.foldersName:
            let account = arguments.optionalString("account")
            let visible = try await visibleFolders().filter {
                account == nil || $0.account == account
            }
            return format.folders(visible)

        case ToolCatalog.searchName:
            return try await search(arguments)

        case ToolCatalog.getName:
            return try await get(arguments)

        case ToolCatalog.attachmentsName:
            let note = try await requireVisibleNote(
                try arguments.requiredString("id"), includeHTML: false)
            return format.attachments(
                try await store.attachments(identifier: note.identifier), of: note)

        case ToolCatalog.createName:
            return try await create(arguments)

        case ToolCatalog.updateName:
            return try await update(arguments)

        case ToolCatalog.moveName:
            return try await move(arguments)

        case ToolCatalog.deleteName:
            return try await delete(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    // MARK: Reads

    private func search(_ arguments: Arguments) async throws -> String {
        let query = arguments.optionalString("query")
        let account = arguments.optionalString("account")
        let dateField = try arguments.dateField("date_field")
        let from = try arguments.optionalDate("from")?.date
        // "On or before 12 August" has to include the whole of the 12th; a bare day parses
        // to midnight, which would exclude it.
        let to = try arguments.optionalDate("to").map { parsed in
            parsed.isDateOnly ? endOfDay(parsed.date) : parsed.date
        }
        let limit = try arguments.int(
            "limit", default: configuration.searchLimit, in: Configuration.searchLimitRange)

        let paths = try await resolvedSearchPaths(
            requested: arguments.optionalString("folder"), account: account)

        let page = try await store.search(
            query: query, folderPaths: paths, account: account, from: from, to: to,
            dateField: dateField, limit: limit, scanCeiling: configuration.scanCeiling)

        // Echoing the scope back means a caller can see that its filters were understood
        // the way it meant them.
        var scope: [String] = []
        if let query { scope.append("'\(query)'") }
        if let folder = arguments.optionalString("folder") { scope.append("in \(folder)") }
        if let account { scope.append("account \(account)") }
        if let from { scope.append("\(dateField.rawValue) from \(format.stamp(from, withYear: true))") }
        if let to { scope.append("\(dateField.rawValue) to \(format.stamp(to, withYear: true))") }
        return format.searchResults(
            page,
            describing: scope.isEmpty
                ? "every folder in scope (\(paths.count))" : scope.joined(separator: " · "))
    }

    private func get(_ arguments: Arguments) async throws -> String {
        let wantsHTML = arguments.bool("html")
        let note = try await requireVisibleNote(
            try arguments.requiredString("id"), includeHTML: wantsHTML)
        let limit = try arguments.int(
            "text_limit", default: configuration.textLimit, in: Configuration.textLimitRange)

        // Truncation lives here rather than in the store so the policy is reachable from a
        // test, and so an append always has the whole body to work from.
        let full = wantsHTML ? (note.html ?? "") : note.plaintext
        let truncated = full.count > limit
        return format.detail(
            note, text: truncated ? String(full.prefix(limit)) : full, truncated: truncated,
            isHTML: wantsHTML)
    }

    // MARK: Writes

    private func create(_ arguments: Arguments) async throws -> String {
        let folder = try await requireFolder(
            try arguments.requiredString("folder"), account: arguments.optionalString("account"))
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
            try arguments.requiredString("folder"), account: arguments.optionalString("account"))

        // Refused here rather than left to Notes, which reports it as an opaque Apple
        // event failure that reads like a bug in this server.
        guard destination.account == note.account else {
            throw ToolError.crossAccountMove(from: note.account, to: destination.account)
        }
        guard destination.path != note.folderPath else {
            throw ToolError.badArgument(
                name: "folder", reason: "the note is already in '\(destination.path)'")
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
        guard arguments.bool("confirm") else {
            throw ToolError.confirmationRequired(action: "Deleting a note")
        }
        return format.deleted(try await store.delete(identifier: identifier))
    }

    // MARK: Folders

    /// Every folder that exists, in every account. There is no allow-list any more — the
    /// owner's plug-and-play rule removed "Folders Claude may use" — so this is just the
    /// one place the folder tree is flattened, kept so a future filter has a single call
    /// site to land on rather than being forgotten at one of several.
    private func visibleFolders() async throws -> [FolderInfo] {
        try await store.accounts().flatMap(\.folders)
    }

    /// Resolves one folder path against what actually exists.
    private func requireFolder(_ path: String, account: String?) async throws -> FolderInfo {
        let everything = try await store.accounts().flatMap(\.folders)
        let matches = everything.filter {
            $0.path.caseInsensitiveCompare(path) == .orderedSame
                && (account == nil || $0.account == account)
        }
        guard let folder = matches.first else {
            throw ToolError.folderNotFound(
                path: path, available: try await visibleFolders().map(\.path))
        }
        return folder
    }

    /// The folder paths one search may walk.
    ///
    /// Never returns an empty array meaning "everywhere": an unqualified search is
    /// expanded to every folder that exists, and an empty result — no folder at all, or
    /// none in the requested account — is an error rather than a silent no-op.
    private func resolvedSearchPaths(requested: String?, account: String?) async throws -> [String] {
        if let requested {
            return [try await requireFolder(requested, account: account).path]
        }
        let visible = try await visibleFolders().filter { account == nil || $0.account == account }
        guard !visible.isEmpty else {
            throw ToolError.noFoldersToSearch(account: account)
        }
        return visible.map(\.path)
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
