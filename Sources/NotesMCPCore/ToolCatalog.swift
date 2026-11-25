import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop. Reads carry no verb prefix; writes always start with a verb, so the
/// destructive ones are visible at a glance in the switch list.
public enum ToolCatalog {

    /// Names are constants rather than being read back off a `Tool`, because a tool whose
    /// schema depends on the configuration has to be built as a function and its name
    /// would then have nowhere stable to live.
    public static let statusName = "notes_status"
    public static let accountsName = "notes_accounts"
    public static let foldersName = "notes_folders"
    public static let searchName = "notes_search"
    public static let getName = "note_get"
    public static let attachmentsName = "note_attachments"
    public static let createName = "create_note"
    public static let updateName = "update_note"
    public static let moveName = "move_note"
    public static let deleteName = "delete_note"

    /// Every name a call may carry, and the ones that change the library. A write that
    /// runs out of time is answered differently from a read: it may still have happened.
    static let names: Set = [
        statusName, accountsName, foldersName, searchName, getName, attachmentsName, createName,
        updateName, moveName, deleteName,
    ]
    static let writeNames: Set = [createName, updateName, moveName, deleteName]

    /// The verbs a write tool may begin with. `move_` joins the usual three because
    /// moving a note is its own action and neither `update_` nor `delete_` describes it.
    static let writeVerbs = ["create_", "update_", "move_", "delete_"]

    // Pages. Each maximum is a number of rows of ordinary width that fits
    // `ToolStandard.longestResult` with room to spare, and each default makes a call with
    // no argument about `ToolStandard.usualPage` or less. `BoundsTests` renders a full page
    // of the widest ordinary rows of every listing to hold both to that. The default page
    // of `notes_search` is `Configuration.searchLimit`.
    public static let offsetRange = 0...10_000_000
    public static let accountLimitRange = 1...200
    public static let defaultAccountLimit = 50
    public static let folderLimitRange = 1...300
    public static let defaultFolderLimit = 100
    public static let searchLimitRange = 1...100
    public static let attachmentLimitRange = 1...100
    public static let defaultAttachmentLimit = 20

    /// The window on a note's text. The maximum leaves a quarter of the longest result for
    /// the note's header and for characters that take more than one UTF-16 unit;
    /// `ToolStandard.fitting` shrinks a window that still does not fit. The default is
    /// `Configuration.textLimit`, which starts at `ToolStandard.usualPage`.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult * 3 / 4)

    /// How much of a note's title one row of `notes_search` shows.
    public static let titleWidth = 60

    /// How much of a note's title a heading or a receipt shows. The whole title is the
    /// first line of the note's text, which `note_get` returns.
    public static let headingWidth = 200

    /// How much of a deleted note's text its receipt repeats.
    public static let receiptTextWidth = ToolStandard.usualPage

    /// How many existing folders an error names when a folder was not found.
    public static let folderCandidates = 10

    /// Built from the live configuration so a description never states a limit the running
    /// server does not actually enforce.
    public static func all(_ configuration: Configuration = Configuration()) -> [Tool] {
        [
            status, accounts, folders, search(configuration), get(configuration), attachments,
            create, update, move, delete,
        ]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// `type` is always a single string, never `["string", "null"]`. Claude Desktop's
    /// schema sanitiser drops a property outright when its `type` is a union and hands the
    /// model a bare `{}` in its place; an array argument is then serialised to a string and
    /// rejected on arrival. Nothing downstream of the client can catch that, so it is kept
    /// out here and a test walks the whole catalogue to keep it out.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String, default def: Bool) -> Value {
        .object([
            "type": .string("boolean"), "description": .string(description),
            "default": .bool(def),
        ])
    }

    private static func integer(_ description: String, range: ClosedRange<Int>, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
            "default": .int(def),
        ])
    }

    private static func limit(_ things: String, range: ClosedRange<Int>, default def: Int) -> Value {
        integer("Maximum number of \(things) in one page.", range: range, default: def)
    }

    private static let offset = integer(
        """
        Number of rows to skip. A result that does not hold every row says, in its first \
        lines, the offset to pass for the next page.
        """, range: offsetRange, default: 0)

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    private static let dateHelp = """
        Accepts 2026-08-12 (whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    private static let folderHelp = """
        Folder path inside its account, exactly as notes_folders prints it — 'Notes' or \
        'Work/Invoices'. Matching ignores case but nothing else.
        """

    private static let bodyHelp = """
        The note's content, as HTML: that is how Notes stores a body. Plain text works but \
        newlines in it are ignored, so wrap each line in <div>…</div> or end it with <br>. \
        The note's title is its first line — Notes derives one from the other, so there is \
        no separate title argument.
        """

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Notes availability and settings",
        description: """
            Reports whether Notes is running, whether this server may automate it, and \
            what limits are in force. Reads no notes.

            Use it when another notes tool fails, or when setting the server up. Do not \
            use it to look for notes.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly)

    static let accounts = Tool(
        name: accountsName,
        title: "List Notes accounts",
        description: """
            Lists the Notes accounts (iCloud, On My Mac, an Exchange account), \
            \(defaultAccountLimit) to a page in name order, with how many folders each \
            holds. When there are more than the page holds, the first lines of the result \
            give the offset of the next page: pass limit (up to \
            \(accountLimitRange.upperBound)) and offset.

            Accounts are separate stores: a note cannot be moved between them, and two \
            accounts routinely both have a folder called "Notes".
            """,
        inputSchema: object(properties: [
            "limit": limit("accounts", range: accountLimitRange, default: defaultAccountLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let folders = Tool(
        name: foldersName,
        title: "List folders",
        description: """
            Lists the folders, \(defaultFolderLimit) to a page ordered by account, then \
            path, each with its note count and the path to address it by. Nested folders \
            appear as 'Parent/Child'. When there are more than the page holds, the first \
            lines of the result give the offset of the next page: pass limit (up to \
            \(folderLimitRange.upperBound)) and offset. account lists one account only.

            Call this before notes_search or create_note if you are not certain a folder \
            exists under that exact path.
            """,
        inputSchema: object(
            properties: [
                "account": string("Optional account name. Omit to list every account's folders."),
                "limit": limit("folders", range: folderLimitRange, default: defaultFolderLimit),
                "offset": offset,
            ]),
        annotations: readOnly)

    static func search(_ configuration: Configuration) -> Tool {
        Tool(
            name: searchName,
            title: "Search notes",
            description: """
                Finds notes by text, folder, account and date, and returns \
                \(configuration.searchLimit) to a page, the most recently modified first: \
                one line per note with its id, never the note's contents. Read one with \
                note_get. When more match than the page holds, the first lines of the \
                result say how many there are and the offset of the next page: pass limit \
                (up to \(searchLimitRange.upperBound)) and offset. from_date and to_date, \
                both inclusive, bound the date; one alone runs to the end.

                A search looks at no more than \(configuration.scanCeiling) notes and for no \
                longer than \(NoteTools.scanBudget.components.seconds) seconds, because Notes \
                itself reads each one. When it stops early the first lines of the result \
                say so: notes it never looked at are not in the result and not in its \
                count, so narrow by folder, from_date or to_date and search again.

                'query' is matched against the note's plain text, so it finds words in the \
                body as well as in the title. Every filter is optional. A title longer \
                than \(titleWidth) characters is clipped in its row.

                Password-protected notes are listed with a lock marker. Their text cannot \
                be read by any tool here and is never matched against 'query'.
                """,
            inputSchema: object(
                properties: [
                    "query": string(
                        "Text to find in a note's title or plain text. Case-insensitive."),
                    "folder": string(
                        "Optional. \(folderHelp) When several accounts have a folder at "
                            + "this path, each is searched unless account names one."),
                    "account": string("Optional account name to restrict the search to."),
                    "date_field": .object([
                        "type": .string("string"),
                        "enum": .array(NoteDateField.allCases.map { .string($0.rawValue) }),
                        "default": .string(NoteDateField.modified.rawValue),
                        "description": .string(
                            "Which date from_date and to_date apply to. Defaults to the "
                                + "modification date, which is what \"recent\" usually means "
                                + "for a note. Results are ordered by modification date "
                                + "either way."),
                    ]),
                    "from_date": string("Earliest date, inclusive. \(dateHelp)"),
                    "to_date": string(
                        "Latest date, inclusive: a whole day includes all of that day. \(dateHelp)"),
                    "limit": limit(
                        "notes", range: searchLimitRange, default: configuration.searchLimit),
                    "offset": offset,
                ]),
            annotations: readOnly)
    }

    static func get(_ configuration: Configuration) -> Tool {
        Tool(
            name: getName,
            title: "Read one note",
            description: """
                Returns one note: its folder, dates and attachment count, then the first \
                \(configuration.textLimit) characters of its text, as plain text. When the \
                note is longer, the first lines of the result say how many characters it \
                has and the character_offset of the rest: pass character_offset and \
                max_characters (up to \(maxCharactersRange.upperBound)) to read it one \
                window at a time. The markup is left out unless html=true.

                Plain text is what you almost always want: the same note as HTML is \
                several times larger for no extra meaning. Pass html=true only when the \
                markup itself matters — before an append, or to see which images are \
                embedded. A window counts characters of the form asked for, so an offset \
                into the plain text is not an offset into the HTML.

                A password-protected note reports that it is locked instead of returning \
                empty text.
                """,
            inputSchema: object(
                properties: [
                    "id": string("Identifier returned by notes_search."),
                    "html": boolean(
                        "Return the note's HTML instead of its plain text.", default: false),
                    "character_offset": integer(
                        """
                        Number of characters of the note's text to skip. A result that does \
                        not hold all of it says, in its first lines, the value to pass for \
                        the rest.
                        """, range: offsetRange, default: 0),
                    "max_characters": integer(
                        "The most characters of the note's text to return.",
                        range: maxCharactersRange, default: configuration.textLimit),
                ],
                required: ["id"]),
            annotations: readOnly)
    }

    static let attachments = Tool(
        name: attachmentsName,
        title: "List a note's attachments",
        description: """
            Lists what is attached to one note, \(defaultAttachmentLimit) to a page, the \
            first added first: name, dates, the link a URL attachment points at, and the \
            cid: reference it appears under in the note's HTML. When there are more than \
            the page holds, the first lines of the result give the offset of the next page: \
            pass limit (up to \(attachmentLimitRange.upperBound)) and offset.

            It lists them only. Saving an attachment to disk is not built here — that \
            needs a filesystem scope this server does not have.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by notes_search."),
                "limit": limit(
                    "attachments", range: attachmentLimitRange, default: defaultAttachmentLimit),
                "offset": offset,
            ],
            required: ["id"]),
        annotations: readOnly)

    // MARK: Writes

    static let create = Tool(
        name: createName,
        title: "Create a note",
        description: """
            Adds a new note to a folder. The note's title is the first line of the body, \
            because that is how Notes works — there is no separate title.

            Call notes_folders first if you are not certain the folder path exists.
            """,
        inputSchema: object(
            properties: [
                "folder": string(folderHelp),
                "account": string(
                    "Optional account name, for when the same folder path exists in more "
                        + "than one account."),
                "body": string(bodyHelp),
            ],
            required: ["folder", "body"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
        )
    )

    static let update = Tool(
        name: updateName,
        title: "Append to or replace a note",
        description: """
            Changes a note's content. 'mode' is REQUIRED and decides which of two very \
            different things happens:

              append   — adds your text to the end, keeping everything already there.
              replace  — DISCARDS THE WHOLE NOTE and writes your text instead.

            replace cannot be undone by this server, and a long note replaced by a short \
            one is the most expensive mistake available here. If you are editing something \
            that already exists, read it with note_get first and use append unless the \
            person actually asked you to start over.

            In append mode your text is concatenated onto the existing HTML exactly as \
            given, so begin it with <div> or <br> to start a new line. Renaming a note \
            means replacing it with a body whose first line is the new title.

            Refuses a password-protected note: its current content cannot be read, so \
            neither mode could be carried out honestly.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by notes_search."),
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array(UpdateMode.allCases.map { .string($0.rawValue) }),
                    "description": .string(
                        "\"append\" keeps the existing content; \"replace\" discards it. "
                            + "Required — there is deliberately no default."),
                ]),
                "body": string(bodyHelp),
            ],
            required: ["id", "mode", "body"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
        )
    )

    static let move = Tool(
        name: moveName,
        title: "Move a note to another folder",
        description: """
            Moves a note into a different folder. Its content is untouched.

            Both folders must actually exist. A note cannot move between accounts — \
            iCloud and On My Mac are separate stores — and that is refused rather than \
            copied.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by notes_search."),
                "folder": string("Destination. \(folderHelp)"),
                "account": string(
                    "Optional account name, for when the destination path exists in more "
                        + "than one account."),
            ],
            required: ["id", "folder"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let delete = Tool(
        name: deleteName,
        title: "Delete a note",
        description: """
            Deletes a note. Requires confirm=true, and returns the record it removed with \
            the first \(receiptTextWidth) characters of its text, so what was lost is at \
            least written down somewhere. The rest of a longer note is not in the receipt \
            and cannot be read afterwards: read it with note_get before deleting if it \
            has to be kept.

            Notes puts a deleted note in Recently Deleted, but this server makes no promise \
            about that and cannot bring it back. Refuses a password-protected note, whose \
            text it could not report.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by notes_search."),
                "confirm": .object([
                    "type": .string("boolean"),
                    "description": .string("Must be true. Without it the call is refused."),
                ]),
            ],
            required: ["id", "confirm"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )
}
