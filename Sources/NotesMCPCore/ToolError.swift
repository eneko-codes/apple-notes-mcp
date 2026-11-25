import Foundation

public enum ToolError: Error, Equatable {
    case notAvailable(NotesAvailability)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case unknownTool(String)
    case notFound(identifier: String)
    case folderNotFound(path: String, available: [String])
    case noFoldersToSearch(account: String?)
    case notePasswordProtected(name: String, action: String)
    case crossAccountMove(from: String, to: String)
    case confirmationRequired(action: String)
    case storeFailure(String)
    case timedOut(seconds: Int, tool: String)

    /// How much of a failure Notes described an error repeats. Its text is Notes' own, or
    /// the bridge's, and can quote a folder path of any length.
    static let detailWidth = 300

    /// Every text that is not this file's own goes through `ToolStandard.echo` or a clip:
    /// what the caller sent, and what Notes holds (a note's title, a folder's path).
    public var message: String {
        switch self {
        case .notAvailable(let state):
            return Self.availabilityMessage(state)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: \
                '\(ToolStandard.echo(value))'

                Use a day that exists, written 2026-08-12, 2026-08-12T09:00, or \
                2026-08-12T09:00:00+02:00.
                """

        case .unknownTool(let name):
            return "'\(ToolStandard.echo(name))' is not a tool of this server."

        case .notFound(let identifier):
            return """
                No note has the id '\(ToolStandard.echo(identifier))'.

                Note identifiers change when an account is resynchronised, and a note that
                has been deleted since the search will no longer resolve. Find it again
                with notes_search rather than reusing an earlier id.
                """

        case .folderNotFound(let path, let available):
            return """
                No folder '\(ToolStandard.echo(path))'.

                \(Self.candidates(for: path, among: available))

                A folder is addressed by its path inside its account, with '/' between
                levels — exactly the string notes_folders prints. Matching ignores case
                but nothing else.
                """

        case .noFoldersToSearch(let account):
            if let account {
                return """
                    Account '\(ToolStandard.echo(account))' has no folders, or no such account exists.

                    Nothing was searched. Call notes_accounts to see what actually exists.
                    """
            }
            return """
                This Notes installation has no folders at all.

                Nothing was searched. Call notes_accounts to check what exists.
                """

        case .notePasswordProtected(let name, let action):
            return """
                '\(ToolStandard.echo(name))' is a password-protected note, so \(action) is refused.

                Notes lists locked notes but will not hand their text to a script. Nothing
                here can read what is inside, which means an append would be appending to
                content nobody can see, and a delete could not say what was lost.

                Unlock it in Notes.app if the change really has to happen — or make the
                change there, where the text is visible.
                """

        case .crossAccountMove(let from, let to):
            let source = ToolStandard.echo(from)
            return """
                A note cannot be moved from account '\(source)' to account '\(ToolStandard.echo(to))'.

                Notes accounts are separate stores — iCloud and On My Mac do not share
                notes — and Notes refuses the move rather than copying. Pick a folder in
                '\(source)', or create a new note in the other account and delete this one
                deliberately.
                """

        case .confirmationRequired(let action):
            return """
                \(action) requires confirm=true.

                This is destructive. Notes moves a deleted note to Recently Deleted, but
                this server makes no promise about that and cannot undo it. Call again
                with confirm=true only if you really mean to delete it.
                """

        case .storeFailure(let detail):
            let shown =
                detail.count > Self.detailWidth ? String(detail.prefix(Self.detailWidth)) + "…" : detail
            return "Notes returned an error: \(shown)"

        case .timedOut(let seconds, let tool):
            let abandoned = "The call did not finish within \(seconds) seconds and was abandoned."
            if ToolCatalog.writeNames.contains(tool) {
                return """
                    \(abandoned)

                    Notes had already been asked, and a request it has received cannot be \
                    taken back: the change may have been made, or may still be made. Do \
                    not repeat the call yet. Look first, with notes_search or note_get, so \
                    that the same change is not made twice.
                    """
            }
            // Only a search has anything to ask less of. The other reads cost Notes the
            // same whatever page or window is asked for, so saying "pass a lower limit"
            // would send the caller round again for nothing.
            let next =
                tool == ToolCatalog.searchName
                ? "Ask for less: pass folder, from_date or to_date, so that Notes has fewer notes to read."
                : "No argument of this tool makes Notes' part of the work smaller, so try again once Notes is idle."
            return """
                \(abandoned) This tool only reads, so nothing was changed.

                Notes itself does the reading and may be busy or still synchronising. \
                \(next) notes_status says whether Notes still answers at all.
                """
        }
    }

    /// The existing folders an error names: the ones most like what was asked for first,
    /// cut to a few, with the count of the others.
    static func candidates(for path: String, among available: [String]) -> String {
        guard !available.isEmpty else { return "No folder exists at all." }
        // The last level is what a caller most often gets right: "Invoices" for
        // "Work/Invoices". Folders that hold it come first, the rest keep their order.
        let wanted = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        let near = available.filter { $0.lowercased().contains(wanted) }
        let ordered = near + available.filter { !$0.lowercased().contains(wanted) }
        let shown = ordered.prefix(ToolCatalog.folderCandidates)
            .map { "'\(ToolStandard.echo($0))'" }.joined(separator: ", ")
        let others = ordered.count - min(ordered.count, ToolCatalog.folderCandidates)
        guard others > 0 else { return "Folders that exist: \(shown)" }
        return "Folders that exist: \(shown), and \(others) more. notes_folders lists them all."
    }
}

extension ToolError {

    static func availabilityMessage(_ state: NotesAvailability) -> String {
        switch state {
        case .ready:
            return "Notes is running and automation is permitted."

        case .notInstalled:
            return """
                Notes.app was not found on this Mac.

                This server drives the Notes app through Apple events; without it there is
                nothing to talk to.
                """

        case .notRunning:
            return """
                Notes is not running.

                This server does not launch it: starting an app on your behalf is a side
                effect you did not ask for, and Notes can take a long time to sync on first
                launch. Open Notes and try again.
                """

        case .consentNotGranted:
            return """
                Automation permission for Notes has not been granted yet.

                macOS raises the dialog the first time this server sends an Apple event.
                Restart Claude Desktop, call a Notes tool, and approve
                "apple-notes-mcp wants to control Notes".
                """

        case .automationDenied:
            return """
                Automation permission for Notes is denied.

                Grant it in:
                  System Settings → Privacy & Security → Automation → apple-notes-mcp → enable Notes
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Automatización)

                Then restart Claude Desktop. The grant is per target app: allowing Notes
                says nothing about any other app.
                """
        }
    }
}
