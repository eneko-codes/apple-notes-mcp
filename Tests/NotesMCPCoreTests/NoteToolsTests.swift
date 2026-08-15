import Foundation
import MCP
import Testing

@testable import NotesMCPCore

/// Drives the tool layer end to end against `FakeNoteStore`. No test here sends an Apple
/// event, so the suite runs with Notes closed, no Automation consent, and nothing the
/// owner wrote at risk.
@Suite("Tool dispatch")
struct NoteToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeNoteStore = FakeNoteStore(),
        configuration: Configuration = Configuration()
    ) async -> (text: String, isError: Bool) {
        let tools = NoteTools(
            store: store, calendar: Fixtures.calendar, configuration: configuration)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    private func stocked() -> FakeNoteStore {
        let store = FakeNoteStore()
        store.accountsValue = Fixtures.accounts
        store.notes = [
            "n1": Fixtures.note(
                id: "n1", name: "Tide tables", folder: "Notes",
                text: "High water at 04:12 and 16:38."),
            "n2": Fixtures.note(
                id: "n2", name: "Shopping", folder: "Notes", text: "bread, olives, ice",
                modified: Fixtures.date(2026, 8, 8, 9, 0)),
            "n3": Fixtures.note(
                id: "n3", name: "Sealed", folder: "Private", text: "", locked: true),
        ]
        return store
    }

    // MARK: Catalogue

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let tools = ToolCatalog.all()
        let names = tools.map(\.name)
        #expect(names.count == Set(names).count)
        for tool in tools {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union and
    /// hands the model a bare `{}` instead, which stays invisible until a caller happens
    /// to use that field.
    @Test("No property declares a union type")
    func noUnionTypesInSchemas() {
        for tool in ToolCatalog.all() {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { continue }
            for (property, definition) in properties {
                guard case .object(let fields) = definition else { continue }
                if case .array = fields["type"] {
                    Issue.record("\(tool.name).\(property) declares a union type")
                }
            }
        }
    }

    @Test("Only the writing tools are marked as writes")
    func annotationsAreHonest() {
        let writes = [
            ToolCatalog.createName, ToolCatalog.updateName, ToolCatalog.moveName,
            ToolCatalog.deleteName,
        ]
        for tool in ToolCatalog.all() {
            #expect(
                tool.annotations.readOnlyHint == !writes.contains(tool.name),
                "\(tool.name) is mis-annotated")
        }
    }

    // MARK: Availability

    @Test("A tool call is refused when Notes is not running")
    func refusesWhenNotRunning() async {
        let store = stocked()
        store.availabilityValue = .notRunning
        let (text, isError) = await call(ToolCatalog.searchName, store: store)
        #expect(isError)
        #expect(text.contains("running"))
    }

    /// macOS only raises the Automation dialog when a real Apple event is sent, so
    /// refusing this state would mean the dialog never appears and consent could never be
    /// granted at all.
    @Test("Ungranted consent does not block the call that would trigger the prompt")
    func consentNotGrantedStillProceeds() async {
        let store = stocked()
        store.availabilityValue = .consentNotGranted
        let (_, isError) = await call(ToolCatalog.searchName, store: store)
        #expect(!isError)
    }

    @Test("notes_status works while Notes is unreachable")
    func statusWorksWhenUnavailable() async {
        let store = stocked()
        store.availabilityValue = .automationDenied
        let (text, isError) = await call(ToolCatalog.statusName, store: store)
        #expect(!isError)
        #expect(!text.isEmpty)
    }

    // MARK: Reads

    @Test("notes_search finds by text")
    func searchFindsByText() async {
        let (text, isError) = await call(
            ToolCatalog.searchName, ["query": .string("olives")], store: stocked())
        #expect(!isError)
        #expect(text.contains("Shopping"))
        #expect(!text.contains("Tide tables"))
    }

    /// There is no allow-list any more: the owner's plug-and-play rule removed "Folders
    /// Claude may use", and an unqualified search is expanded to every folder that exists.
    /// This is the one place a narrower scope could leak back in unnoticed, so it is
    /// checked at the store call rather than only in the rendered output.
    @Test("An unqualified search reaches every folder, unconditionally")
    func everyFolderIsSearched() async {
        let store = stocked()

        let (text, isError) = await call(ToolCatalog.searchName, store: store)
        #expect(!isError)
        #expect(Set(store.searchedFolders.first ?? []) == Set(["Notes", "Private"]))
        #expect(text.contains("Sealed"))
    }

    @Test("A specific folder is reachable regardless of which one it is")
    func anyRealFolderIsReachable() async {
        let (text, isError) = await call(
            ToolCatalog.searchName, ["folder": .string("Private")], store: stocked())
        #expect(!isError)
        #expect(text.contains("Sealed"))
    }

    /// Plaintext is many times smaller than the HTML of the same note and is what anyone
    /// actually wants to read, so HTML has to be asked for.
    @Test("note_get returns plaintext by default and HTML only on request")
    func noteGetPrefersPlaintext() async {
        let (plain, isError) = await call(
            ToolCatalog.getName, ["id": .string("n1")], store: stocked())
        #expect(!isError)
        #expect(plain.contains("High water"))
        #expect(!plain.contains("<div>"))

        let (html, _) = await call(
            ToolCatalog.getName, ["id": .string("n1"), "html": .bool(true)], store: stocked())
        #expect(html.contains("<div>"))
    }

    /// A locked note is visible but unreadable. Returning empty text would look like an
    /// empty note rather than a sealed one.
    @Test("A password-protected note says it is locked rather than returning nothing")
    func lockedNoteIsReported() async {
        let (text, _) = await call(
            ToolCatalog.getName, ["id": .string("n3")], store: stocked())
        #expect(text.lowercased().contains("lock"))
    }

    @Test("An unknown id says so")
    func unknownIDIsNamed() async {
        let (text, isError) = await call(
            ToolCatalog.getName, ["id": .string("nope")], store: stocked())
        #expect(isError)
        #expect(text.contains("nope"))
    }

    @Test("notes_accounts and notes_folders report the containers")
    func containersAreListed() async {
        let (accounts, accountsFailed) = await call(ToolCatalog.accountsName, store: stocked())
        #expect(!accountsFailed)
        #expect(accounts.contains("iCloud"))

        let (folders, foldersFailed) = await call(ToolCatalog.foldersName, store: stocked())
        #expect(!foldersFailed)
        #expect(folders.contains("Notes"))
    }

    @Test("An unknown tool name is refused")
    func unknownToolIsRefused() async {
        let (_, isError) = await call("notes_delete_everything", store: stocked())
        #expect(isError)
    }

    // MARK: Writes

    @Test("create_note reaches the store once with the folder it was given")
    func createPassesThrough() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.createName,
            ["folder": .string("Notes"), "body": .string("ZZTest fixture note")], store: store)
        #expect(!isError)
        #expect(store.created.count == 1)
        #expect(store.created.first?.folderPath == "Notes")
    }

    /// The footgun this server is designed against: silently replacing a long note.
    /// `mode` is required, so neither the model nor a slip can default into destruction.
    @Test("update_note refuses to guess between appending and replacing")
    func updateRequiresAnExplicitMode() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.updateName,
            ["id": .string("n1"), "body": .string("more text")], store: store)
        #expect(isError)
        #expect(store.replacedBodies.isEmpty)
        #expect(text.lowercased().contains("mode"))
    }

    @Test("update_note in append mode keeps what was already there")
    func appendKeepsExistingText() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.updateName,
            [
                "id": .string("n1"), "body": .string("Low water at 10:25."),
                "mode": .string("append"),
            ],
            store: store)
        #expect(!isError)
        let written = store.replacedBodies.first?.html ?? ""
        #expect(written.contains("High water"), "append must not drop the existing body")
        #expect(written.contains("Low water"))
    }

    @Test("update_note in replace mode replaces")
    func replaceReplaces() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.updateName,
            ["id": .string("n1"), "body": .string("only this"), "mode": .string("replace")],
            store: store)
        #expect(!isError)
        let written = store.replacedBodies.first?.html ?? ""
        #expect(written.contains("only this"))
        #expect(!written.contains("High water"))
    }

    @Test("move_note reaches the store with the destination folder")
    func movePassesThrough() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.moveName,
            ["id": .string("n1"), "folder": .string("Private")], store: store)
        #expect(!isError)
        #expect(store.moved.first?.folder == "Private")
    }

    @Test("delete_note without confirm=true deletes nothing")
    func deleteRequiresConfirmation() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.deleteName, ["id": .string("n2")], store: store)
        #expect(isError)
        #expect(store.deleted.isEmpty)
        #expect(text.contains("confirm"))
    }

    @Test("delete_note with confirm=true deletes exactly the note addressed")
    func deleteRemovesOne() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.deleteName,
            ["id": .string("n2"), "confirm": .bool(true)], store: store)
        #expect(!isError)
        #expect(store.deleted == ["n2"])
    }

    @Test("A store failure is reported rather than swallowed")
    func storeFailureIsReported() async {
        let store = stocked()
        store.failure = ToolError.storeFailure("Notes stopped responding")
        let (text, isError) = await call(ToolCatalog.searchName, store: store)
        #expect(isError)
        #expect(text.contains("Notes"))
    }
}
