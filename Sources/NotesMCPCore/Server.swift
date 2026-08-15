import Foundation
import MCP

public enum NotesMCPServer {

    public static let name = "apple-notes-mcp"
    public static let version = "1.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the id workflow, the two rules that surprise people, and where policy lives.
    public static let instructions = """
        Access to the macOS Notes app.

        Notes has no framework a separate process can use, so this server drives Notes.app \
        through Apple events. Notes must be running, and Notes — not this server — is what \
        reads the library. That makes every query slow: narrow a search by folder or date \
        when you can. notes_search stops at a scan ceiling and says so when it does.

        Workflow: notes_folders to see what exists, notes_search to find notes, then \
        note_get with the id a search returned.

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
        requires confirm=true.

        This server exposes the notes library's full scriptable capability. What may be \
        used at any moment is decided by the permission switches in the client, not by \
        this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing in
    /// this function sends an Apple event by itself.
    public static func run(
        store: (any NoteStore)? = nil,
        configuration: Configuration = Configuration()
    ) async throws {
        let store = store ?? ScriptingBridgeNoteStore()
        let tools = NoteTools(store: store, configuration: configuration)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolCatalog.all(configuration))
        }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
