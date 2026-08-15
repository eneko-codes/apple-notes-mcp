import Foundation

public enum ToolError: Error, Equatable {
    case notAvailable(NotesAvailability)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case notFound(identifier: String)
    case folderNotFound(path: String, available: [String])
    case noFoldersToSearch(account: String?)
    case notePasswordProtected(name: String, action: String)
    case crossAccountMove(from: String, to: String)
    case confirmationRequired(action: String)
    case storeFailure(String)

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
                Argument '\(argument)' is not a date this server accepts: '\(value)'

                Use 2026-08-12, 2026-08-12T09:00, or 2026-08-12T09:00:00+02:00.
                """

        case .notFound(let identifier):
            return """
                No note has the id '\(identifier)'.

                Note identifiers change when an account is resynchronised, and a note that
                has been deleted since the search will no longer resolve. Find it again
                with notes_search rather than reusing an earlier id.
                """

        case .folderNotFound(let path, let available):
            let list = available.isEmpty ? "(none found)" : available.joined(separator: ", ")
            return """
                No folder '\(path)'.

                Folders that exist: \(list)

                A folder is addressed by its path inside its account, with '/' between
                levels — exactly the string notes_folders prints. Matching ignores case
                but nothing else.
                """

        case .noFoldersToSearch(let account):
            if let account {
                return """
                    Account '\(account)' has no folders, or no such account exists.

                    Nothing was searched. Call notes_accounts to see what actually exists.
                    """
            }
            return """
                This Notes installation has no folders at all.

                Nothing was searched. Call notes_accounts to check what exists.
                """

        case .notePasswordProtected(let name, let action):
            return """
                '\(name)' is a password-protected note, so \(action) is refused.

                Notes lists locked notes but will not hand their text to a script. Nothing
                here can read what is inside, which means an append would be appending to
                content nobody can see, and a delete could not say what was lost.

                Unlock it in Notes.app if the change really has to happen — or make the
                change there, where the text is visible.
                """

        case .crossAccountMove(let from, let to):
            return """
                A note cannot be moved from account '\(from)' to account '\(to)'.

                Notes accounts are separate stores — iCloud and On My Mac do not share
                notes — and Notes refuses the move rather than copying. Pick a folder in
                '\(from)', or create a new note in the other account and delete this one
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
            return "Notes returned an error: \(detail)"
        }
    }

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
