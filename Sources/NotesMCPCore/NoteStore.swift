import Foundation

/// Whether Notes can be driven at all, and if not, why.
///
/// There is no `authorizationStatus` for Apple events the way there is for Contacts or
/// EventKit, so this collapses several distinct causes — Notes missing, Notes not
/// running, consent refused — into one value the tools can act on.
public enum NotesAvailability: Sendable, Equatable {
    case ready
    case notInstalled
    /// Notes is installed but not launched. This server does not launch it: starting an
    /// app on someone's behalf is a side effect they did not ask for.
    case notRunning
    case automationDenied
    /// macOS has not asked yet. The first real Apple event raises the dialog.
    case consentNotGranted

    /// Whether a tool call must be refused outright.
    ///
    /// `.consentNotGranted` deliberately does **not** block, which is why "may a call
    /// proceed" is a different question from "is Notes ready". macOS only shows the
    /// Automation dialog when a real Apple event is sent, so refusing here would mean the
    /// dialog never appears and the permission could never be granted at all. If consent
    /// is then refused, the event fails and the error path reports it.
    public var blocksCalls: Bool {
        switch self {
        case .ready, .consentNotGranted: return false
        case .notInstalled, .notRunning, .automationDenied: return true
        }
    }
}

/// The seam between the tool layer and Notes.
///
/// Nothing above this protocol sends an Apple event, which is what lets the tests drive
/// every branch against an in-memory double — with Notes closed and no note touched.
public protocol NoteStore: Sendable {
    func availability() -> NotesAvailability

    /// Every account with its whole folder tree, flattened to paths.
    func accounts() async throws -> [AccountInfo]

    /// Walks `folderPaths` in order and returns what matched.
    ///
    /// The folder list is always explicit and never means "everywhere": an empty array
    /// scans nothing. A scope that fails open is worse than one that errors, and this is
    /// the only place the configured folder allow-list could leak.
    ///
    /// `scanCeiling` is passed per call rather than held by the store so that the value
    /// the tools enforce and the value `notes_status` reports cannot be two numbers.
    func search(
        query: String?, folderPaths: [String], account: String?, from: Date?, to: Date?,
        dateField: NoteDateField, limit: Int, scanCeiling: Int
    ) async throws -> NoteSearchPage

    /// `includeHTML` is opt-in because the HTML of a long note is many times the size of
    /// its plaintext and is only needed to render or to append.
    func fetch(identifier: String, includeHTML: Bool) async throws -> NoteDetail?

    func attachments(identifier: String) async throws -> [AttachmentInfo]

    func create(_ draft: NoteDraft) async throws -> NoteDetail

    /// Replaces the note's whole body. Appending is composed above this seam, where the
    /// tests can reach it.
    func replaceBody(identifier: String, html: String) async throws -> NoteDetail

    func move(identifier: String, toFolderPath: String, account: String?) async throws -> NoteDetail

    /// Returns the note as it was immediately before removal, so the caller can describe
    /// precisely what disappeared.
    func delete(identifier: String) async throws -> NoteDetail
}
