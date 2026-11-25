import Foundation

public enum NotesMCPServer {

    public static let name = "apple-notes-mcp"
    public static let version = "2.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the id workflow, how a long result is read, the two rules that surprise
    /// people, and where policy lives.
    public static func instructions(_ configuration: Configuration = Configuration()) -> String {
        """
        Access to the macOS Notes app.

        Notes has no framework a separate process can use, so this server drives Notes.app \
        through Apple events. Notes must be running, and Notes — not this server — is what \
        reads the library. That makes every query slow: narrow a search by folder or date \
        when you can.

        Workflow: notes_folders to see what exists, notes_search to find notes, then \
        note_get with the id a search returned.

        LISTS COME IN PAGES. notes_accounts, notes_folders, notes_search and \
        note_attachments return one page of rows, in an order each states. When rows exist \
        that a result does not hold, its first lines say how many there are and the offset \
        of the next page: pass limit and offset. note_get returns the first \
        \(configuration.textLimit) characters of a note; for a longer one its first lines \
        give the character_offset of the rest, read with character_offset and \
        max_characters. A size or a count outside its range is moved to the nearest allowed \
        value, and the first lines say which one was used.

        A SEARCH CAN STOP EARLY. notes_search looks at no more than \
        \(configuration.scanCeiling) notes and for no longer than \
        \(NoteTools.scanBudget.components.seconds) seconds. When it stops, the first lines of \
        the result say so; notes it never looked at are not in the result, so narrow by \
        folder, from_date or to_date and search again. Dates accept 2026-08-12 (whole day), \
        2026-08-12T09:00 (local time) or 2026-08-12T09:00:00+02:00; from_date and to_date \
        are both inclusive.

        EVERY CALL IS BOUNDED. A call that has not finished after \
        \(NoteTools.defaultTimeout.components.seconds) seconds is abandoned and answered \
        with an error. For a tool that reads, nothing was changed. For a tool that writes, \
        the change may still have been made: look before trying again.

        note_get returns PLAIN TEXT by default. Ask for html=true only when the markup \
        matters — it is several times larger for the same content.

        update_note requires an explicit mode. "append" adds to the end; "replace" \
        DISCARDS the whole note and cannot be undone from here. When editing something \
        that already exists, read it first and prefer append.

        Password-protected notes are listed but locked: Notes will not give their text to \
        a script. They are reported as locked rather than as empty, and no write tool will \
        touch one.

        Tags, pinned notes and checklist state do not exist in Notes' scripting \
        dictionary. This server cannot read or set them, and will not pretend otherwise.

        Write tools carry a verb prefix (create_, update_, move_, delete_). delete_note \
        requires confirm=true, and its receipt repeats only the first \
        \(ToolCatalog.receiptTextWidth) characters of the note's text.

        This server exposes the notes library's full scriptable capability. What may be \
        used at any moment is decided by the permission switches in the client, not by \
        this code.
        """
    }

    /// The store is a parameter so the whole server can be driven by a double. Nothing in
    /// this function sends an Apple event by itself.
    public static func run(
        store: (any NoteStore)? = nil,
        configuration: Configuration = Configuration()
    ) async {
        let store = store ?? ScriptingBridgeNoteStore()
        Diagnostics.started(version: version)
        await serveStandardStreams(
            handler: handler(
                tools: NoteTools(store: store, configuration: configuration),
                configuration: configuration))
    }

    public static func handler(tools: NoteTools, configuration: Configuration) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions(configuration),
            catalog: ToolCatalog.all(configuration), tools: tools)
    }
}
