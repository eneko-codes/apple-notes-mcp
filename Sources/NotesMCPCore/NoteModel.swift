import Foundation

/// One Notes account: iCloud, On My Mac, an Exchange account, and so on.
public struct AccountInfo: Sendable, Equatable {
    public let name: String
    public let identifier: String
    public let folders: [FolderInfo]

    public init(name: String, identifier: String, folders: [FolderInfo]) {
        self.name = name
        self.identifier = identifier
        self.folders = folders
    }
}

/// One folder, addressed by its `path` within its account.
///
/// Notes folders nest, so a bare name cannot say which "Archive" was meant. The path is
/// the folder names from the top of the account joined with `/`, and it is exactly the
/// string every tool that takes a folder expects — `notes_folders` prints it verbatim so
/// nothing has to be guessed.
public struct FolderInfo: Sendable, Equatable {
    public let name: String
    public let path: String
    public let identifier: String
    public let account: String
    public let isShared: Bool
    public let noteCount: Int

    public init(
        name: String, path: String, identifier: String, account: String, isShared: Bool,
        noteCount: Int
    ) {
        self.name = name
        self.path = path
        self.identifier = identifier
        self.account = account
        self.isShared = isShared
        self.noteCount = noteCount
    }
}

public struct NoteSummary: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let folderPath: String
    public let account: String
    public let created: Date
    public let modified: Date
    /// Password-protected. The note is listed — Notes shows locked notes too — but its
    /// text cannot be read, and saying so is the whole point of carrying the flag.
    public let isLocked: Bool
    public let isShared: Bool

    public init(
        identifier: String, name: String, folderPath: String, account: String, created: Date,
        modified: Date, isLocked: Bool, isShared: Bool
    ) {
        self.identifier = identifier
        self.name = name
        self.folderPath = folderPath
        self.account = account
        self.created = created
        self.modified = modified
        self.isLocked = isLocked
        self.isShared = isShared
    }
}

public struct NoteDetail: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let folderPath: String
    public let account: String
    public let created: Date
    public let modified: Date
    public let isLocked: Bool
    public let isShared: Bool
    public let attachmentCount: Int
    /// The note's text with the markup stripped, which is what Notes' own `plaintext`
    /// property returns. Empty for a locked note.
    public let plaintext: String
    /// The note's HTML, fetched only when it was asked for. `nil` means "not requested",
    /// which is a different fact from "the note is empty".
    public let html: String?

    public init(
        identifier: String, name: String, folderPath: String, account: String, created: Date,
        modified: Date, isLocked: Bool, isShared: Bool, attachmentCount: Int, plaintext: String,
        html: String?
    ) {
        self.identifier = identifier
        self.name = name
        self.folderPath = folderPath
        self.account = account
        self.created = created
        self.modified = modified
        self.isLocked = isLocked
        self.isShared = isShared
        self.attachmentCount = attachmentCount
        self.plaintext = plaintext
        self.html = html
    }

    public var summary: NoteSummary {
        NoteSummary(
            identifier: identifier, name: name, folderPath: folderPath, account: account,
            created: created, modified: modified, isLocked: isLocked, isShared: isShared)
    }
}

public struct AttachmentInfo: Sendable, Equatable {
    public let identifier: String
    public let name: String
    /// The `cid:` URL this attachment appears under inside the note's HTML, which is how
    /// an image in the body is matched to the file behind it.
    public let contentIdentifier: String
    /// Set only for URL attachments — a link previewed in the note.
    public let url: String?
    public let created: Date
    public let modified: Date
    public let isShared: Bool

    public init(
        identifier: String, name: String, contentIdentifier: String, url: String?, created: Date,
        modified: Date, isShared: Bool
    ) {
        self.identifier = identifier
        self.name = name
        self.contentIdentifier = contentIdentifier
        self.url = url
        self.created = created
        self.modified = modified
        self.isShared = isShared
    }
}

public struct NoteSearchPage: Sendable, Equatable {
    public let results: [NoteSummary]
    public let total: Int
    /// True when the walk stopped at the scan ceiling rather than exhausting the folders.
    /// Distinct from `total`: it means "there may be notes I never looked at", which
    /// silence would misrepresent.
    public let hitScanLimit: Bool

    public init(results: [NoteSummary], total: Int, hitScanLimit: Bool = false) {
        self.results = results
        self.total = total
        self.hitScanLimit = hitScanLimit
    }
}

/// Which of the two dates a search range applies to. Both are real Notes properties, so
/// filtering on either is a filter rather than a judgement.
public enum NoteDateField: String, Sendable, Equatable {
    case modified
    case created
}

/// What `update_note` does with the text it is given.
///
/// Required on the tool, with no default. Replacing a long note by accident is this
/// server's most expensive possible mistake — Notes keeps no version history a script can
/// reach — and a default would make it the outcome of forgetting an argument.
public enum UpdateMode: String, Sendable, Equatable {
    case append
    case replace
}

public struct NoteDraft: Sendable, Equatable {
    public var folderPath: String
    public var account: String?
    /// The note's content as HTML. Notes derives the note's name from the first line of
    /// it, so there is no separate title: two sources of truth for the same fact drift
    /// apart.
    public var bodyHTML: String

    public init(folderPath: String, account: String? = nil, bodyHTML: String) {
        self.folderPath = folderPath
        self.account = account
        self.bodyHTML = bodyHTML
    }
}
