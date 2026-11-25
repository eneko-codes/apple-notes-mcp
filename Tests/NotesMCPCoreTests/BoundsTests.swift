import Foundation
import Testing

@testable import NotesMCPCore

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages and windows that chain, the longest result, and the texts
/// the model reads. Every account, folder, note and attachment in here is invented.
@Suite("Bounds")
struct BoundsTests {

    // MARK: An invented library with as many rows as a test asks for

    private static func padded(_ index: Int) -> String {
        String(format: "%04d", index)
    }

    /// `prefix` filled out to `length` characters, the widest an ordinary row gets.
    private static func filled(_ prefix: String, to length: Int) -> String {
        prefix + String(repeating: "x", count: max(length - prefix.count, 0))
    }

    private static let folder = "Work/Invented clients/2026"
    private static let noteID = "x-coredata://5D0F2A6E-0000-4000-8000-00000000C0DE/ICNote/p"

    private static func folderInfo(_ path: String, account: String = "iCloud", id: String) -> FolderInfo {
        FolderInfo(
            name: path.split(separator: "/").last.map(String.init) ?? path, path: path,
            identifier: id, account: account, isShared: false, noteCount: 12)
    }

    /// A library whose one folder holds `count` notes. Note `index` was modified `index`
    /// minutes before the newest, so the order a search lists them in is their index.
    private static func library(notes count: Int, title: @Sendable (Int) -> String = longTitle) -> FakeNoteStore {
        let store = FakeNoteStore()
        store.accountsValue = [
            AccountInfo(
                name: "iCloud", identifier: "account-1",
                folders: [folderInfo(folder, id: "folder-1"), folderInfo("Archive", id: "folder-2")])
        ]
        for index in 0..<count {
            let identifier = noteID + padded(index)
            store.notes[identifier] = Fixtures.note(
                id: identifier, name: title(index), folder: folder, text: "Invented text \(index).",
                modified: Fixtures.now.addingTimeInterval(Double(-60 * index)))
        }
        return store
    }

    /// A title exactly as wide as a row shows, so no row here is clipped.
    private static let longTitle: @Sendable (Int) -> String = {
        filled("Invented note \(padded($0)) ", to: ToolCatalog.titleWidth)
    }

    /// One listing tool, and a library that gives it `count` rows of the widest ordinary
    /// width, in the order the tool lists them. `row` is text found in row `index` only.
    private struct Listing: Sendable, CustomTestStringConvertible {
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var arguments: [String: Value] = [:]
        var store: @Sendable (Int) -> FakeNoteStore
        var row: @Sendable (Int) -> String

        var testDescription: String { tool }

        func call(_ count: Int, _ extra: [String: Value] = [:]) async -> ToolResult {
            await NotesMCPCoreTests.call(
                tool, arguments.merging(extra) { _, new in new }, store: store(count))
        }

        /// The rows of a library with `count` of them that `text` shows, in order.
        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(row($0)) }
        }
    }

    private static let accounts = Listing(
        tool: ToolCatalog.accountsName, things: "accounts", limits: ToolCatalog.accountLimitRange,
        defaultLimit: ToolCatalog.defaultAccountLimit,
        store: { count in
            let store = FakeNoteStore()
            // Out of order, as nothing promises Notes hands them over sorted.
            store.accountsValue = (0..<count).reversed().map {
                AccountInfo(
                    name: filled("Invented account \(padded($0)) ", to: 40), identifier: "account-\($0)",
                    folders: [folderInfo("Notes", id: "folder-\($0)")])
            }
            return store
        },
        row: { "Invented account \(padded($0)) " })

    private static let folders = Listing(
        tool: ToolCatalog.foldersName, things: "folders", limits: ToolCatalog.folderLimitRange,
        defaultLimit: ToolCatalog.defaultFolderLimit,
        store: { count in
            let store = FakeNoteStore()
            store.accountsValue = [
                AccountInfo(
                    name: "iCloud", identifier: "account-1",
                    folders: (0..<count).reversed().map {
                        folderInfo(
                            filled("Projects/Invented clients/\(padded($0))/", to: 60), id: "folder-\($0)")
                    })
            ]
            return store
        },
        row: { "Invented clients/\(padded($0))/" })

    private static let search = Listing(
        tool: ToolCatalog.searchName, things: "notes", limits: ToolCatalog.searchLimitRange,
        defaultLimit: Configuration().searchLimit,
        store: { library(notes: $0) },
        row: { "id=\(noteID)\(padded($0))" })

    private static let attachments = Listing(
        tool: ToolCatalog.attachmentsName, things: "attachments", limits: ToolCatalog.attachmentLimitRange,
        defaultLimit: ToolCatalog.defaultAttachmentLimit, arguments: ["id": .string(noteID + "0000")],
        store: { count in
            let store = library(notes: 1)
            store.attachmentsValue[noteID + "0000"] = (0..<count).reversed().map {
                AttachmentInfo(
                    identifier: "x-coredata://5D0F2A6E-0000-4000-8000-00000000C0DE/ICAttachment/p\(padded($0))",
                    name: "Invented scan \(padded($0)).pdf",
                    contentIdentifier: "cid:0B8C2D54-0000-4000-8000-00000000\(padded($0))@example.com",
                    url: filled("https://example.com/invented/documents/\(padded($0))/", to: 80),
                    created: Fixtures.now.addingTimeInterval(Double(60 * $0)),
                    modified: Fixtures.now.addingTimeInterval(Double(60 * $0)), isShared: false)
            }
            return store
        },
        row: { "Invented scan \(padded($0)).pdf" })

    private static let listings = [accounts, folders, search, attachments]

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    private func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await listing.call(total)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(listing.defaultLimit) of \(total) \(listing.things). Pass offset=\(listing.defaultLimit) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<listing.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every row from the start carries no notice", arguments: listings)
    private func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await listing.call(listing.defaultLimit)
        #expect(listing.rows(in: result.text, of: listing.defaultLimit).count == listing.defaultLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
        #expect(!result.text.contains("is clipped"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    private func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await listing.call(total, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    private func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await listing.call(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                """
                limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.
                Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.


                """))
        #expect(listing.rows(in: over.text, of: total) == Array(0..<maximum))

        let under = await listing.call(total, ["limit": .int(0)])
        #expect(under.text.hasPrefix("limit=0 is outside 1–\(maximum); 1 was used.\nShowing 1–1 of \(total) "))
        #expect(listing.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    private func pagesChain(_ listing: Listing) async {
        let first = await listing.call(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix("Showing 1–3 of 7 \(listing.things). Pass offset=3 for the next page.\n\n"))
        #expect(listing.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await listing.call(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix("Showing 4–6 of 7 \(listing.things). Pass offset=6 for the next page.\n\n"))
        #expect(listing.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await listing.call(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n\n"))
        #expect(listing.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    private func offsetEdges(_ listing: Listing) async {
        let past = await listing.call(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all.\n\n"))
        #expect(listing.rows(in: past.text, of: 7).isEmpty)
        #expect(past.text.contains("(nothing at this offset)"))

        let lastRow = await listing.call(7, ["offset": .int(6)])
        #expect(listing.rows(in: lastRow.text, of: 7) == [6])

        let negative = await listing.call(7, ["offset": .int(-1)])
        let range = ToolCatalog.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))
    }

    @Test("A listing with no row at all says so in its own words, with no notice", arguments: listings)
    private func emptyListing(_ listing: Listing) async {
        let none = await listing.call(0)
        #expect(!none.isError)
        #expect(!none.text.contains("(nothing at this offset)"))
        #expect(!none.text.contains("Showing"))
        #expect(none.text.hasPrefix("No ") || none.text.contains(" has no attachments."))
    }

    @Test("A listing states its order")
    func orderIsStated() async {
        #expect(await Self.accounts.call(1).text.contains("ordered by name"))
        #expect(await Self.folders.call(1).text.contains("ordered by account, then path"))
        #expect(await Self.search.call(1).text.contains("ordered by modification date, newest first, then id"))
        #expect(await Self.attachments.call(1).text.contains("ordered by date added, then id"))
    }

    @Test("Names are ordered so that Folder 2 comes before Folder 10, and accounts before their folders")
    func namesOrderNumerically() async {
        let store = FakeNoteStore()
        store.accountsValue = [
            AccountInfo(
                name: "On My Mac", identifier: "account-2",
                folders: [Self.folderInfo("Notes", account: "On My Mac", id: "folder-9")]),
            AccountInfo(
                name: "iCloud", identifier: "account-1",
                folders: [
                    Self.folderInfo("Folder 10", id: "folder-3"), Self.folderInfo("folder 2", id: "folder-2"),
                    Self.folderInfo("Folder 2/Inner", id: "folder-4"),
                ]),
        ]
        let text = await call(ToolCatalog.foldersName, store: store).text
        let found = ["iCloud\n", "folder 2 ", "Folder 2/Inner", "Folder 10", "On My Mac\n"]
            .compactMap { text.range(of: $0)?.lowerBound }
        #expect(found.count == 5)
        #expect(found == found.sorted())

        let onlyOne = await call(ToolCatalog.foldersName, ["account": "On My Mac"], store: store).text
        #expect(onlyOne.hasPrefix("Folders: 1, "))
        #expect(!onlyOne.contains("Folder 10"))
    }

    // MARK: Rows wider than any maximum foresaw

    @Test("A page of rows too wide to fit holds fewer of them and says where to resume")
    func widePageShrinks() async throws {
        // The number leads the name, so that looking for a row never has to walk the filler.
        let wide = String(repeating: "w", count: 1000)
        let total = 120
        func store() -> FakeNoteStore {
            let store = FakeNoteStore()
            store.accountsValue = [
                AccountInfo(
                    name: "iCloud", identifier: "account-1",
                    folders: (0..<total).map { Self.folderInfo("row-\(Self.padded($0))-\(wide)", id: "folder-\($0)") })
            ]
            return store
        }
        var offset = 0
        var seen: [Int] = []
        while offset < total {
            let result = await call(
                ToolCatalog.foldersName, ["limit": .int(ToolCatalog.folderLimitRange.upperBound), "offset": .int(offset)],
                store: store())
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = (0..<total).filter { result.text.contains("row-\(Self.padded($0))-") }
            let last = try #require(shown.last)
            #expect(shown.first == offset)
            #expect(shown.count < total)
            let next = last + 1 < total ? "Pass offset=\(last + 1) for the next page." : "That is all."
            #expect(result.text.hasPrefix("Showing \(offset + 1)–\(last + 1) of \(total) folders. \(next)\n\n"))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<total))
    }

    // MARK: What a search leaves out

    private static let narrowing = "Narrow by folder, from_date or to_date."

    @Test("A search that stops at the scan ceiling says so first, and counts only what it looked at")
    func scanCeilingIsAnnounced() async {
        var configuration = Configuration()
        configuration.scanCeiling = 5
        let store = Self.library(notes: 12)

        let whole = await call(ToolCatalog.searchName, store: store, configuration: configuration)
        #expect(whole.text.hasPrefix("The scan stopped after 5 notes; more may exist. \(Self.narrowing)\n\n5 notes · "))
        #expect(Self.search.rows(in: whole.text, of: 12) == [0, 1, 2, 3, 4])
        #expect(store.lastScanCeiling == 5)

        let paged = await call(
            ToolCatalog.searchName, ["limit": .int(2)], store: store, configuration: configuration)
        #expect(
            paged.text.hasPrefix(
                """
                The scan stopped after 5 notes; more may exist. \(Self.narrowing)
                Showing 1–2 of 5 notes. Pass offset=2 for the next page.


                """))

        let nothing = await call(
            ToolCatalog.searchName, ["query": "no such words"], store: store, configuration: configuration)
        #expect(
            nothing.text
                == "The scan stopped after 5 notes; more may exist. \(Self.narrowing)\n\nNo notes match 'no such words'.")
    }

    @Test("A search that reaches no ceiling carries no such notice")
    func completeSearchHasNoScanNotice() async {
        let result = await Self.search.call(12)
        #expect(result.text.hasPrefix("12 notes · "))
        #expect(!result.text.contains("scan stopped"))
        #expect(!result.text.contains("Partial"))
    }

    @Test("A search that runs out of time returns what it has and says it is partial")
    func searchOutOfTimeIsPartial() async throws {
        let store = Self.library(notes: 12)
        store.timeRunsOutAfter = 3
        let result = await call(ToolCatalog.searchName, store: store)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Partial: the time limit was reached after 3 notes. \(Self.narrowing)\n\n3 notes · "))
        // What finding the folders took comes out of the budget, so a little less is passed.
        let passed = try #require(store.lastTimeBudget)
        #expect(passed <= NoteTools.scanBudget && passed > NoteTools.scanBudget - .seconds(5))
    }

    @Test("A path that two accounts share is searched in both, each once")
    func sharedPathIsSearchedInEveryAccount() async {
        let store = FakeNoteStore()
        store.accountsValue = ["iCloud", "On My Mac"].map { account in
            AccountInfo(
                name: account, identifier: "account-\(account)",
                folders: [Self.folderInfo("Notes", account: account, id: "folder-\(account)")])
        }
        store.notes = [
            "cloud": Fixtures.note(id: "cloud", name: "In the cloud", folder: "Notes", text: "Invented."),
            "local": Fixtures.note(
                id: "local", name: "On this Mac", folder: "Notes", text: "Invented.", account: "On My Mac"),
        ]
        let everywhere = await call(ToolCatalog.searchName, store: store)
        #expect(everywhere.text.hasPrefix("2 notes · every folder in scope (2)"))
        #expect(everywhere.text.contains("  iCloud / Notes     In the cloud  id=cloud"))
        #expect(everywhere.text.contains("  On My Mac / Notes  On this Mac  id=local"))

        let one = await call(ToolCatalog.searchName, ["account": "On My Mac"], store: store)
        #expect(one.text.hasPrefix("1 note · account On My Mac"))
        #expect(one.text.contains("  Notes  On this Mac  id=local") && !one.text.contains("id=cloud"))

        let named = await call(ToolCatalog.searchName, ["folder": "notes", "account": "On My Mac"], store: store)
        #expect(named.text.contains("id=local") && !named.text.contains("id=cloud"))

        // A folder named without its account is every folder of that path.
        let unqualified = await call(ToolCatalog.searchName, ["folder": "notes"], store: store)
        #expect(unqualified.text.hasPrefix("2 notes · in notes"))
        #expect(unqualified.text.contains("  iCloud / Notes     In the cloud  id=cloud"))
        #expect(unqualified.text.contains("  On My Mac / Notes  On this Mac  id=local"))
        #expect(store.searchedFolders.last == ["Notes", "Notes"])
    }

    @Test("A library of exactly as many notes as the ceiling is not reported as cut short")
    func ceilingExactlyMetIsNotAnnounced() async {
        var configuration = Configuration()
        configuration.scanCeiling = 5
        let exact = await call(ToolCatalog.searchName, store: Self.library(notes: 5), configuration: configuration)
        #expect(exact.text.hasPrefix("5 notes · "))
        let over = await call(ToolCatalog.searchName, store: Self.library(notes: 6), configuration: configuration)
        #expect(over.text.hasPrefix("The scan stopped after 5 notes; more may exist."))
    }

    @Test("A title wider than its column is clipped, and the result names the tool that reads it whole")
    func clippedTitleIsAnnounced() async {
        let notice = "Title is clipped to \(ToolCatalog.titleWidth) characters in each row. Read one in full with note_get."
        let long = Self.library(notes: 1) { _ in String(repeating: "t", count: ToolCatalog.titleWidth + 1) }
        let clipped = await call(ToolCatalog.searchName, store: long)
        #expect(clipped.text.hasPrefix(notice + "\n\n1 note · "))
        #expect(clipped.text.contains(String(repeating: "t", count: ToolCatalog.titleWidth - 1) + "…  id="))

        let exact = await call(ToolCatalog.searchName, store: Self.library(notes: 1))
        #expect(!exact.text.contains("is clipped"))
        #expect(exact.text.contains(Self.longTitle(0) + "  id="))
    }

    @Test("Notes modified in the same minute are ordered by id, so no page repeats or skips one")
    func tiesAreBrokenByIdentifier() async {
        let store = Self.library(notes: 0)
        for index in [3, 1, 4, 0, 2] {
            let identifier = Self.noteID + Self.padded(index)
            store.notes[identifier] = Fixtures.note(
                id: identifier, name: "Same minute \(index)", folder: Self.folder, text: "Invented.")
        }
        var seen: [Int] = []
        for offset in stride(from: 0, to: 5, by: 2) {
            let page = await call(ToolCatalog.searchName, ["limit": .int(2), "offset": .int(offset)], store: store)
            seen += Self.search.rows(in: page.text, of: 5)
        }
        #expect(seen == [0, 1, 2, 3, 4])
    }

    // MARK: Dates

    private func datedLibrary() -> FakeNoteStore {
        let store = Self.library(notes: 0)
        let days = [(6, "Sixth"), (8, "Eighth"), (10, "Tenth")]
        for (day, name) in days {
            store.notes[name] = Fixtures.note(
                id: name, name: name, folder: Self.folder, text: "Invented.",
                created: Fixtures.date(2026, 7, day, 15, 0), modified: Fixtures.date(2026, 8, day, 15, 0))
        }
        return store
    }

    private func found(_ arguments: [String: Value]) async -> [String] {
        let text = await call(ToolCatalog.searchName, arguments, store: datedLibrary()).text
        return ["Sixth", "Eighth", "Tenth"].filter { text.contains("id=\($0)") }
    }

    @Test("from_date and to_date are both inclusive, and one alone runs to the end")
    func datesAreInclusive() async {
        #expect(await found(["from_date": "2026-08-08", "to_date": "2026-08-08"]) == ["Eighth"])
        #expect(await found(["from_date": "2026-08-08"]) == ["Eighth", "Tenth"])
        #expect(await found(["to_date": "2026-08-08"]) == ["Sixth", "Eighth"])
        #expect(await found(["to_date": "2026-08-08T15:00"]) == ["Sixth", "Eighth"])
        #expect(await found(["to_date": "2026-08-08T14:59"]) == ["Sixth"])
        #expect(await found(["from_date": "2026-08-08T15:00:00+02:00"]) == ["Eighth", "Tenth"])
        #expect(await found(["from_date": "2026-08-09", "to_date": "2026-08-09"]).isEmpty)
        #expect(
            await found(["date_field": "created", "from_date": "2026-07-08", "to_date": "2026-07-08"]) == ["Eighth"])
    }

    @Test("A date that does not exist, or in another form, is refused with the forms accepted")
    func impossibleDatesAreRefused() async {
        let refused = [
            "2026-02-30", "2026-13-01", "2026-00-10", "2025-02-29", "12/08/2026", "2026-08", "yesterday",
            "2026-08-12T25:00", "2026-08-12T09:61", "2026-02-30T09:00:00+02:00", "2026-08-12T09:00:99",
            "2026-08-12T09:00:00+25:99", "2026-08-12T09:00:00+2", "2026-08-12T09:00:00+02:00Z",
            "2026-08-12T", "2026-08-12T09", "2026-+8-12", "2026-08-12T09:00:00-", "02026-08-12",
        ]
        for value in refused {
            for argument in ["from_date", "to_date"] {
                let result = await call(ToolCatalog.searchName, [argument: .string(value)], store: datedLibrary())
                #expect(result.isError, "\(value)")
                #expect(
                    result.text.hasPrefix("Argument '\(argument)' is not a date this server accepts: '\(value)'"),
                    "\(value): \(result.text)")
                #expect(result.text.contains("2026-08-12, 2026-08-12T09:00, or 2026-08-12T09:00:00+02:00"))
            }
        }
        #expect(await found(["from_date": "2024-02-29"]) == ["Sixth", "Eighth", "Tenth"])
    }

    @Test("Every form of date the descriptions offer names the instant it says")
    func dateFormsAreRead() throws {
        func parsed(_ text: String) throws -> (date: Date, isDateOnly: Bool) {
            try #require(try Arguments(["at": .string(text)], calendar: Fixtures.calendar).optionalDate("at"))
        }
        #expect(try parsed("2026-08-12").date == Fixtures.date(2026, 8, 12))
        #expect(try parsed("2026-08-12").isDateOnly)
        #expect(try parsed("2026-08-12T09:00").date == Fixtures.date(2026, 8, 12, 9, 0))
        #expect(try !parsed("2026-08-12T09:00").isDateOnly)
        #expect(try parsed("2026-08-12T09:00:30").date == Fixtures.date(2026, 8, 12, 9, 0).addingTimeInterval(30))
        // Madrid is two hours ahead of UTC in August and one in January.
        #expect(try parsed("2026-08-12T09:00:00+02:00").date == Fixtures.date(2026, 8, 12, 9, 0))
        #expect(try parsed("2026-08-12T07:00:00Z").date == Fixtures.date(2026, 8, 12, 9, 0))
        #expect(try parsed("2026-08-12T07:00Z").date == Fixtures.date(2026, 8, 12, 9, 0))
        #expect(try parsed("2026-01-12T09:00:00+01:00").date == Fixtures.date(2026, 1, 12, 9, 0))
        #expect(try parsed("2026-08-12T23:30:00-05:00").date == Fixtures.date(2026, 8, 13, 6, 30))
        #expect(try parsed(" 2026-08-12 ").date == Fixtures.date(2026, 8, 12))
    }

    @Test("An offset written with a minus sign is read as an offset, not dropped")
    func negativeOffsetsAreRead() throws {
        let arguments = Arguments(["at": "2026-08-08T09:00:00-05:00"], calendar: Fixtures.calendar)
        let parsed = try #require(try arguments.optionalDate("at"))
        // 09:00 at five hours behind UTC is 16:00 in Madrid in August.
        #expect(parsed.date == Fixtures.date(2026, 8, 8, 16, 0))
        #expect(!parsed.isDateOnly)
    }

    @Test("A range that ends before it starts is refused")
    func reversedRangeIsRefused() async {
        let result = await call(
            ToolCatalog.searchName, ["from_date": "2026-08-10", "to_date": "2026-08-08"], store: datedLibrary())
        #expect(result.isError)
        #expect(result.text.hasPrefix("Argument 'to_date' is not valid: it is earlier than from_date."))
    }

    // MARK: The window on a note's text

    private static let windowed = noteID + "0000"

    /// A note whose text is `text`, and whose HTML is that text inside one element.
    private static func noteStore(text: String, title: String = "Invented tide log") -> FakeNoteStore {
        let store = library(notes: 0)
        store.notes[windowed] = Fixtures.note(id: windowed, name: title, folder: folder, text: text)
        return store
    }

    private static let longText = (0..<1500).map { "Invented line \(padded($0)) of the tide log." }
        .joined(separator: "\n")

    private func note(_ extra: [String: Value] = [:], text: String = longText) async -> ToolResult {
        await call(
            ToolCatalog.getName, ["id": .string(Self.windowed)].merging(extra) { _, new in new },
            store: Self.noteStore(text: text))
    }

    /// What follows the note's heading: the window itself.
    private func window(_ text: String, html: Bool = false) throws -> String {
        let marker = html ? " characters\n\n" : "html=true returns the markup\n\n"
        let heading = try #require(text.range(of: marker))
        return String(text[heading.upperBound...])
    }

    @Test("A long note comes as one default window, announced before the data")
    func defaultWindow() async throws {
        let size = Configuration().textLimit
        #expect(size == ToolStandard.usualPage)
        #expect(Self.longText.count > size)
        let result = await note()
        #expect(
            result.text.hasPrefix(
                "Text: characters 1–\(size) of \(Self.longText.count). Pass character_offset=\(size) for the rest.\n\nInvented tide log\n"))
        #expect(try window(result.text) == String(Self.longText.prefix(size)))
        #expect(result.text.contains("plain text, \(Self.longText.count) characters; html=true returns the markup"))
    }

    @Test("Windows chain: each starts where the last ended, and together they are the whole note")
    func windowsChain() async throws {
        let whole = Self.longText
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await note(["character_offset": .int(offset), "max_characters": .int(7000)])
            let part = try window(result.text)
            let last = offset + part.count
            let next = last < whole.count ? "Pass character_offset=\(last) for the rest." : "That is all."
            #expect(result.text.hasPrefix("Text: characters \(offset + 1)–\(last) of \(whole.count). \(next)\n\n"))
            #expect(part.count == min(7000, whole.count - offset))
            joined += part
            offset = last
        }
        #expect(joined == whole)
    }

    @Test("A note that fits one window carries no notice")
    func shortNoteHasNoNotice() async throws {
        let result = await note(text: "High water at 04:12.")
        #expect(result.text.hasPrefix("Invented tide log\n"))
        #expect(!result.text.contains("characters 1–"))
        #expect(try window(result.text) == "High water at 04:12.")
    }

    @Test("max_characters at its maximum is used as asked; one past either end is moved and reported")
    func windowSizeBounds() async throws {
        let maximum = ToolCatalog.maxCharactersRange.upperBound
        #expect(Self.longText.count > maximum)

        let atMaximum = await note(["max_characters": .int(maximum)])
        #expect(!atMaximum.text.contains("is outside"))
        #expect(try window(atMaximum.text).count == maximum)
        #expect(atMaximum.text.utf16.count <= ToolStandard.longestResult)

        let over = await note(["max_characters": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                "max_characters=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\nText: characters 1–\(maximum) of "))
        #expect(try window(over.text).count == maximum)

        let under = await note(["max_characters": .int(0)])
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(maximum); 1 was used.\nText: characters 1–1 of "))
        #expect(try window(under.text) == "I")
    }

    @Test("character_offset past the end returns no text and says so; a negative one is moved to zero")
    func windowOffsetEdges() async throws {
        let total = Self.longText.count
        let past = await note(["character_offset": .int(total + 50)])
        #expect(!past.isError)
        #expect(
            past.text.hasPrefix(
                "Text: characters 0 of \(total): character_offset=\(total + 50) is past the end. That is all.\n\n"))
        #expect(try window(past.text).isEmpty)

        let negative = await note(["character_offset": .int(-3)])
        let range = ToolCatalog.offsetRange
        #expect(
            negative.text.hasPrefix(
                "character_offset=-3 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\nText: characters 1–"))
    }

    @Test("A window of characters that take several UTF-16 units each still fits a result, and still chains")
    func windowOfWideCharacters() async throws {
        // Eight UTF-16 units to the character: a full window would be six results long.
        let whole = String(repeating: "👩‍👩‍👧", count: 40_000)
        let maximum = ToolCatalog.maxCharactersRange.upperBound
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await note(
                ["character_offset": .int(offset), "max_characters": .int(maximum)], text: whole)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let part = try window(result.text)
            #expect(!part.isEmpty && part.count < maximum)
            let last = offset + part.count
            #expect(result.text.contains("Text: characters \(offset + 1)–\(last) of \(whole.count). "))
            joined += part
            offset = last
        }
        #expect(joined == whole)
    }

    @Test("html=true windows the markup, counted on its own, and says which form it is")
    func htmlWindow() async throws {
        let markup = "<div>\(Self.longText)</div>"
        let size = Configuration().textLimit
        let result = await note(["html": true])
        #expect(
            result.text.hasPrefix(
                "HTML: characters 1–\(size) of \(markup.count). Pass character_offset=\(size) for the rest.\n\n"))
        #expect(try window(result.text, html: true) == String(markup.prefix(size)))

        let rest = await note(["html": true, "character_offset": .int(markup.count - 6)])
        #expect(try window(rest.text, html: true) == "</div>")
        #expect(rest.text.hasPrefix("HTML: characters \(markup.count - 5)–\(markup.count) of \(markup.count). That is all.\n\n"))
    }

    @Test("A title as long as a note is clipped in a heading, and the result names the tool that reads it whole")
    func longTitleIsClipped() async {
        let title = String(repeating: "T", count: 50_000)
        let clipped = String(repeating: "T", count: ToolCatalog.headingWidth - 1) + "…"
        let notice = "Title is clipped to \(ToolCatalog.headingWidth) characters in each row. Read one in full with note_get.\n\n"
        let id: Value = .string(Self.windowed)
        func store() -> FakeNoteStore { Self.noteStore(text: "Short.", title: title) }

        let read = await call(ToolCatalog.getName, ["id": id], store: store())
        #expect(read.text.hasPrefix(notice + clipped + "\n"))
        let attached = await call(ToolCatalog.attachmentsName, ["id": id], store: store())
        #expect(attached.text == notice + "'\(clipped)' has no attachments.")
        let updated = await call(
            ToolCatalog.updateName, ["id": id, "mode": "append", "body": "<div>more</div>"], store: store())
        #expect(updated.text.hasPrefix(notice + "Updated '\(clipped)' (append)."))
        let moved = await call(ToolCatalog.moveName, ["id": id, "folder": "Archive"], store: store())
        #expect(moved.text.hasPrefix(notice + "Moved '\(clipped)'."))
        // The receipt of a deletion repeats the note's text, whose first line is the title.
        let removed = await call(ToolCatalog.deleteName, ["id": id, "confirm": true], store: store())
        #expect(removed.text.hasPrefix("Deleted '\(clipped)'."))
        for result in [read, attached, updated, moved, removed] {
            #expect(!result.isError)
            #expect(result.text.utf16.count < ToolStandard.usualPage)
        }

        let short = await call(ToolCatalog.getName, ["id": id], store: Self.noteStore(text: "Short."))
        #expect(short.text.hasPrefix("Invented tide log\n"))
    }

    // MARK: The receipt of a deletion

    private static let heldMarker = "The text it held:\n\n"

    @Test("delete_note repeats the start of a long note's text and says the rest is not in the receipt")
    func deletionReceiptIsBounded() async throws {
        let store = Self.noteStore(text: Self.longText)
        let result = await call(ToolCatalog.deleteName, ["id": .string(Self.windowed), "confirm": true], store: store)
        #expect(!result.isError)
        #expect(store.deleted == [Self.windowed])
        let width = ToolCatalog.receiptTextWidth
        #expect(width == ToolStandard.usualPage)
        #expect(
            result.text.hasPrefix(
                "Text: characters 1–\(width) of \(Self.longText.count). The rest is not in this receipt, and this server cannot read a deleted note. Notes.app may still hold it in Recently Deleted.\n\nDeleted 'Invented tide log'."))
        let held = try #require(result.text.range(of: Self.heldMarker))
        #expect(String(result.text[held.upperBound...]) == String(Self.longText.prefix(width)))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("delete_note repeats a short note whole, with no notice")
    func shortDeletionReceiptIsWhole() async {
        let text = String(repeating: "a", count: ToolCatalog.receiptTextWidth)
        let result = await call(
            ToolCatalog.deleteName, ["id": .string(Self.windowed), "confirm": true], store: Self.noteStore(text: text))
        #expect(result.text.hasPrefix("Deleted 'Invented tide log'. This server cannot undo it.\n"))
        #expect(result.text.hasSuffix(Self.heldMarker + text))
    }

    @Test("A receipt of characters that take several UTF-16 units each still fits a result")
    func deletionReceiptOfWideCharacters() async throws {
        let text = String(repeating: "👩‍👩‍👧", count: 20_000)
        let result = await call(
            ToolCatalog.deleteName, ["id": .string(Self.windowed), "confirm": true], store: Self.noteStore(text: text))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        let held = try #require(result.text.range(of: Self.heldMarker))
        let shown = result.text[held.upperBound...].count
        #expect(shown > 0 && shown < ToolCatalog.receiptTextWidth)
        #expect(result.text.hasPrefix("Text: characters 1–\(shown) of 20000. "))
    }

    // MARK: Numbers moved, values refused

    @Test("A wrong type is refused with the form expected")
    func wrongTypesAreRefused() async {
        let id: Value = .string(Self.windowed)
        let cases: [(tool: String, arguments: [String: Value], expected: String)] = [
            (ToolCatalog.searchName, ["limit": "ten"], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.searchName, ["limit": 2.5], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.searchName, ["offset": true], "Argument 'offset' is not valid: a whole number was expected"),
            (ToolCatalog.searchName, ["query": 5], "Argument 'query' is not valid: text was expected"),
            (ToolCatalog.searchName, ["folder": ["Notes"]], "Argument 'folder' is not valid: text was expected"),
            (ToolCatalog.searchName, ["from_date": 20_260_812], "Argument 'from_date' is not valid: text was expected"),
            (ToolCatalog.searchName, ["date_field": "edited"], "expected one of: modified, created; got 'edited'"),
            (ToolCatalog.foldersName, ["account": 1], "Argument 'account' is not valid: text was expected"),
            (ToolCatalog.foldersName, ["limit": [1]], "Argument 'limit' is not valid"),
            (ToolCatalog.accountsName, ["offset": "2"], "Argument 'offset' is not valid: a whole number was expected"),
            (ToolCatalog.getName, ["id": 7], "Argument 'id' is not valid: text was expected"),
            (ToolCatalog.getName, ["id": id, "html": "yes"], "Argument 'html' is not valid: true or false was expected"),
            (ToolCatalog.getName, ["id": id, "max_characters": "all"], "Argument 'max_characters' is not valid"),
            (ToolCatalog.getName, ["id": id, "character_offset": 1.5], "Argument 'character_offset' is not valid"),
            (ToolCatalog.attachmentsName, ["id": id, "limit": "5"], "Argument 'limit' is not valid"),
            (ToolCatalog.deleteName, ["id": id, "confirm": "true"], "Argument 'confirm' is not valid: true or false was expected"),
            (ToolCatalog.updateName, ["id": id, "mode": "merge", "body": "x"], "expected one of: append, replace; got 'merge'"),
            (ToolCatalog.updateName, ["id": id, "mode": "append", "body": 3], "Argument 'body' is not valid: text was expected"),
            (ToolCatalog.createName, ["folder": 3, "body": "x"], "Argument 'folder' is not valid: text was expected"),
        ]
        for (tool, arguments, expected) in cases {
            let store = Self.noteStore(text: "Short.")
            let result = await call(tool, arguments, store: store)
            #expect(result.isError, "\(tool) \(arguments)")
            #expect(result.text.contains(expected), "\(tool) \(arguments): \(result.text)")
            #expect(store.deleted.isEmpty && store.replacedBodies.isEmpty && store.created.isEmpty)
        }
    }

    @Test("A whole number sent as 20.0 is taken as 20, and a null as not given")
    func lenientForms() async {
        let result = await Self.search.call(30, ["limit": 20.0, "offset": .null, "query": .null, "from_date": .null])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Showing 1–20 of 30 notes."))
    }

    @Test("A missing required argument is named")
    func missingArguments() async {
        let store = Self.noteStore(text: "Short.")
        for tool in [ToolCatalog.getName, ToolCatalog.attachmentsName, ToolCatalog.deleteName, ToolCatalog.moveName] {
            let result = await call(tool, store: store)
            #expect(result.isError && result.text == "Missing required argument 'id'.", "\(tool)")
        }
        let confirm = await call(ToolCatalog.deleteName, ["id": .string(Self.windowed), "confirm": .null], store: store)
        #expect(confirm.isError && confirm.text.contains("requires confirm=true"))
        #expect(store.deleted.isEmpty)
    }

    // MARK: Errors and time

    @Test("An error repeats at most a short piece of what the caller sent")
    func errorsClipWhatTheyEcho() async {
        let long = String(repeating: "n", count: 5000)
        let clipped = String(repeating: "n", count: ToolStandard.echoWidth) + "…"
        let store = Self.noteStore(text: "Short.")
        let calls: [(tool: String, arguments: [String: Value])] = [
            (long, [:]),
            (ToolCatalog.getName, ["id": .string(long)]),
            (ToolCatalog.searchName, ["folder": .string(long)]),
            (ToolCatalog.searchName, ["account": .string(long)]),
            (ToolCatalog.searchName, ["from_date": .string(long)]),
            (ToolCatalog.searchName, ["date_field": .string(long)]),
            (ToolCatalog.createName, ["folder": .string(long), "body": "x"]),
            (ToolCatalog.updateName, ["id": .string(Self.windowed), "mode": .string(long), "body": "x"]),
        ]
        for (tool, arguments) in calls {
            let result = await call(tool, arguments, store: store)
            #expect(result.isError, "\(arguments)")
            #expect(result.text.contains(clipped), "\(arguments): \(result.text.prefix(200))")
            #expect(!result.text.contains(clipped.dropLast() + "n"), "\(arguments)")
            #expect(result.text.utf16.count <= ToolStandard.longestError / 10, "\(arguments)")
        }
    }

    @Test("A search echoes a long query clipped, in its result")
    func scopeIsClipped() async {
        let long = String(repeating: "q", count: 5000)
        let result = await call(ToolCatalog.searchName, ["query": .string(long)], store: Self.library(notes: 3))
        #expect(result.text == "No notes match '\(String(repeating: "q", count: ToolStandard.echoWidth))…'.")
    }

    @Test("A folder that does not exist names a few that do, the likeliest first, and counts the rest")
    func folderCandidatesAreCut() async {
        let store = FakeNoteStore()
        store.accountsValue = [
            AccountInfo(
                name: "iCloud", identifier: "account-1",
                folders: (0..<40).map { Self.folderInfo("Invented folder \(Self.padded($0))", id: "folder-\($0)") }
                    + [Self.folderInfo("Work/Invoices", id: "folder-work")])
        ]
        let result = await call(ToolCatalog.searchName, ["folder": "Invoices"], store: store)
        #expect(result.isError)
        #expect(result.text.hasPrefix("No folder 'Invoices'.\n\nFolders that exist: 'Work/Invoices', 'Invented folder 0000', "))
        let shown = ToolCatalog.folderCandidates
        #expect(result.text.contains("'Invented folder \(Self.padded(shown - 2))', and \(41 - shown) more. notes_folders lists them all."))
        #expect(!result.text.contains("Invented folder \(Self.padded(shown - 1))"))

        store.accountsValue = [
            AccountInfo(name: "iCloud", identifier: "account-1", folders: [Self.folderInfo("Notes", id: "folder-1")])
        ]
        let few = await call(ToolCatalog.searchName, ["folder": "Invoices"], store: store)
        #expect(few.text.contains("Folders that exist: 'Notes'\n"))
        #expect(!few.text.contains("more."))
    }

    @Test("Every error this server words is far inside the longest error")
    func errorsAreShort() {
        let long = String(repeating: "n", count: 50_000)
        let errors: [ToolError] = [
            .notAvailable(.notInstalled), .notAvailable(.notRunning), .notAvailable(.automationDenied),
            .notAvailable(.consentNotGranted), .missingArgument("id"),
            .badArgument(name: "limit", reason: "a whole number was expected"),
            .badDate(argument: "from_date", value: long), .unknownTool(long), .notFound(identifier: long),
            .folderNotFound(path: long, available: Array(repeating: long, count: 500)),
            .noFoldersToSearch(account: long), .noFoldersToSearch(account: nil),
            .notePasswordProtected(name: long, action: "deleting it"), .crossAccountMove(from: long, to: long),
            .confirmationRequired(action: "Deleting a note"), .storeFailure(long),
            .timedOut(seconds: 120, tool: ToolCatalog.searchName), .timedOut(seconds: 120, tool: ToolCatalog.getName),
            .timedOut(seconds: 120, tool: ToolCatalog.deleteName),
        ]
        for error in errors {
            #expect(error.message.utf16.count <= ToolStandard.longestError / 4, "\(Diagnostics.kind(of: error))")
        }
    }

    @Test("A failure Notes describes at length is repeated only in part")
    func storeFailureIsClipped() async {
        let store = Self.library(notes: 1)
        store.failure = NSError(
            domain: "Invented", code: 1,
            userInfo: [NSLocalizedDescriptionKey: String(repeating: "d", count: 5000)])
        let result = await call(ToolCatalog.searchName, store: store)
        #expect(result.isError)
        #expect(result.text == "Notes returned an error: " + String(repeating: "d", count: ToolError.detailWidth) + "…")
    }

    @Test("The deadline of a call, and the time a search may scan, are within the standard's time limit")
    func deadlineIsWithinTheTimeLimit() {
        #expect(NoteTools.defaultTimeout <= ToolStandard.timeLimit)
        // Room for the one Apple event in flight when the scan's time runs out, which
        // Scripting Bridge waits about a minute for.
        #expect(NoteTools.scanBudget + .seconds(60) < NoteTools.defaultTimeout)
    }

    private let shortTimeout = Duration.milliseconds(200)

    @Test("A read that Notes never answers is answered with an error that says nothing changed", .timeLimit(.minutes(1)))
    func hungReadIsAnswered() async {
        let gate = DispatchSemaphore(value: 0)
        let store = Self.library(notes: 3)
        store.blocker = gate
        // Released afterwards so the abandoned work does not leak a blocked thread.
        defer { for _ in 0..<8 { gate.signal() } }

        let result = await call(ToolCatalog.searchName, store: store, timeout: shortTimeout)
        #expect(result.isError)
        #expect(result.text.hasPrefix("The call did not finish within 0 seconds and was abandoned. This tool only reads, so nothing was changed."))
        #expect(result.text.contains("Ask for less: pass folder, from_date or to_date"))
    }

    @Test("A read with nothing to narrow says so and never names an argument it does not take")
    func hungListingIsAnswered() async {
        let id: Value = .string(Self.windowed)
        let reads: [(tool: String, arguments: [String: Value])] = [
            (ToolCatalog.accountsName, [:]), (ToolCatalog.foldersName, [:]), (ToolCatalog.getName, ["id": id]),
            (ToolCatalog.attachmentsName, ["id": id]),
        ]
        for (tool, arguments) in reads {
            let gate = DispatchSemaphore(value: 0)
            let store = Self.noteStore(text: "Short.")
            store.blocker = gate
            let result = await call(tool, arguments, store: store, timeout: shortTimeout)
            for _ in 0..<8 { gate.signal() }
            #expect(result.isError, "\(tool)")
            #expect(result.text.contains("This tool only reads, so nothing was changed."), "\(tool)")
            #expect(result.text.contains("No argument of this tool makes Notes' part of the work smaller"), "\(tool)")
            #expect(!result.text.contains("from_date") && !result.text.contains("folder,"), "\(tool)")
        }
    }

    @Test("A write that Notes never answers says the change may still have been made", .timeLimit(.minutes(1)))
    func hungWriteIsAnswered() async {
        let gate = DispatchSemaphore(value: 0)
        let store = Self.noteStore(text: "Short.")
        store.blocker = gate
        defer { for _ in 0..<8 { gate.signal() } }

        let result = await call(
            ToolCatalog.deleteName, ["id": .string(Self.windowed), "confirm": true], store: store,
            timeout: shortTimeout)
        #expect(result.isError)
        #expect(result.text.contains("the change may have been made, or may still be made"))
        #expect(!result.text.contains("nothing was changed"))
        for tool in ToolCatalog.writeNames {
            let message = ToolError.timedOut(seconds: 120, tool: tool).message
            #expect(message.contains("within 120 seconds") && message.contains("Do not repeat the call yet."))
        }
        #expect(Diagnostics.kind(of: ToolError.timedOut(seconds: 120, tool: "delete_note")) == "ToolError.timedOut")
    }

    @Test("notes_status answers inside the deadline and reports the limits in force")
    func statusReportsTheLimits() async {
        var configuration = Configuration()
        configuration.scanCeiling = 77
        let result = await call(
            ToolCatalog.statusName, store: FakeNoteStore(), configuration: configuration, timeout: shortTimeout)
        #expect(!result.isError)
        #expect(result.text.contains("77 notes in one notes_search"))
        #expect(result.text.contains("\(NoteTools.scanBudget.components.seconds) seconds in one notes_search"))
        #expect(result.text.contains("\(NoteTools.defaultTimeout.components.seconds) seconds for any call"))
        #expect(result.text.contains("\(configuration.textLimit) in note_get"))
        #expect(result.text.contains("\(configuration.searchLimit) in notes_search"))
    }

    // MARK: What the model reads

    @Test("The instructions and every tool description are within the longest a client keeps")
    func textsAreWithinTheLimit() {
        #expect(
            ToolStandard.overlongTexts(instructions: NotesMCPServer.instructions(), catalog: ToolCatalog.all()).isEmpty)
        #expect(!NotesMCPServer.instructions().isEmpty)
    }

    private func properties(of tool: Tool) -> [String: [String: Value]] {
        guard case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [:] }
        return properties.compactMapValues(\.objectValue)
    }

    @Test("Every listing's schema states the range and default of limit and offset that the code enforces", arguments: listings)
    private func schemaStatesThePage(_ listing: Listing) throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == listing.tool })
        let limit = try #require(properties(of: tool)["limit"])
        #expect(limit["minimum"]?.intValue == listing.limits.lowerBound)
        #expect(limit["maximum"]?.intValue == listing.limits.upperBound)
        #expect(limit["default"]?.intValue == listing.defaultLimit)
        let offset = try #require(properties(of: tool)["offset"])
        #expect(offset["minimum"]?.intValue == ToolCatalog.offsetRange.lowerBound)
        #expect(offset["maximum"]?.intValue == ToolCatalog.offsetRange.upperBound)
        #expect(offset["default"]?.intValue == 0)
        // The description states the same maximum, taken from the same constant.
        #expect(tool.description?.contains("limit (up to \(listing.limits.upperBound))") == true)
        #expect(tool.description?.contains("\(listing.defaultLimit) to a page") == true)
    }

    @Test("The window's schema states the range and default the code enforces")
    func schemaStatesTheWindow() throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.getName })
        let size = try #require(properties(of: tool)["max_characters"])
        #expect(size["minimum"]?.intValue == ToolCatalog.maxCharactersRange.lowerBound)
        #expect(size["maximum"]?.intValue == ToolCatalog.maxCharactersRange.upperBound)
        #expect(size["default"]?.intValue == ToolStandard.usualPage)
        let offset = try #require(properties(of: tool)["character_offset"])
        #expect(offset["minimum"]?.intValue == 0 && offset["default"]?.intValue == 0)
        #expect(tool.description?.contains("first \(ToolStandard.usualPage) characters") == true)
        #expect(tool.description?.contains("max_characters (up to \(ToolCatalog.maxCharactersRange.upperBound))") == true)
    }

    @Test("A setting passed on the command line changes the default the schema, the description and the tool use")
    func configurationReachesTheCatalogue() async throws {
        let configuration = Configuration.parse([
            "--text-limit", "999999", "--search-limit", "7", "--scan-ceiling", "60",
        ])
        #expect(configuration.textLimit == ToolCatalog.maxCharactersRange.upperBound)
        let catalog = ToolCatalog.all(configuration)
        let get = try #require(catalog.first { $0.name == ToolCatalog.getName })
        #expect(properties(of: get)["max_characters"]?["default"]?.intValue == configuration.textLimit)
        let search = try #require(catalog.first { $0.name == ToolCatalog.searchName })
        #expect(properties(of: search)["limit"]?["default"]?.intValue == 7)
        #expect(search.description?.contains("7 to a page") == true)
        #expect(search.description?.contains("no more than 60 notes") == true)
        #expect(NotesMCPServer.instructions(configuration).contains("no more than 60 notes"))
        #expect(ToolStandard.overlongTexts(instructions: NotesMCPServer.instructions(configuration), catalog: catalog).isEmpty)

        let result = await call(ToolCatalog.searchName, store: Self.library(notes: 9), configuration: configuration)
        #expect(result.text.hasPrefix("Showing 1–7 of 9 notes. Pass offset=7 for the next page.\n\n"))
    }

    @Test("The descriptions and the instructions state the bounds the code enforces")
    func textsStateTheBounds() throws {
        let instructions = NotesMCPServer.instructions()
        let configuration = Configuration()
        #expect(instructions.contains("first \(configuration.textLimit) characters of a note"))
        #expect(instructions.contains("no more than \(configuration.scanCeiling) notes"))
        #expect(instructions.contains("no longer than \(NoteTools.scanBudget.components.seconds) seconds"))
        #expect(instructions.contains("after \(NoteTools.defaultTimeout.components.seconds) seconds"))
        #expect(instructions.contains("first \(ToolCatalog.receiptTextWidth) characters of the note's text"))

        let search = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.searchName })
        #expect(search.description?.contains("no more than \(configuration.scanCeiling) notes") == true)
        #expect(search.description?.contains("no longer than \(NoteTools.scanBudget.components.seconds) seconds") == true)
        #expect(search.description?.contains("longer than \(ToolCatalog.titleWidth) characters is clipped") == true)
        let delete = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.deleteName })
        #expect(delete.description?.contains("first \(ToolCatalog.receiptTextWidth) characters of its text") == true)
    }

    @Test("Every number in a schema has a range, and every default lies inside it")
    func everyNumberHasARange() {
        for tool in ToolCatalog.all() {
            for (name, property) in properties(of: tool) where property["type"]?.stringValue == "integer" {
                guard let minimum = property["minimum"]?.intValue, let maximum = property["maximum"]?.intValue
                else {
                    Issue.record("\(tool.name).\(name) states no range")
                    continue
                }
                if let value = property["default"]?.intValue {
                    #expect((minimum...maximum).contains(value), "\(tool.name).\(name)")
                }
            }
        }
    }

    @Test("Only the standard names page, window and date a result")
    func standardArgumentNames() {
        let standard: Set = ["limit", "offset", "character_offset", "max_characters", "from_date", "to_date"]
        let lookalikes: Set = [
            "max", "count", "max_results", "page", "page_size", "skip", "start", "from", "to", "since", "until",
            "after", "before", "text_limit", "max_chars", "max_length", "char_offset", "cursor",
        ]
        var used: Set<String> = []
        for tool in ToolCatalog.all() {
            let names = Set(properties(of: tool).keys)
            #expect(names.isDisjoint(with: lookalikes), "\(tool.name)")
            used.formUnion(names.intersection(standard))
        }
        #expect(used == standard)
    }

    @Test("Every tool the catalogue offers is one the dispatcher knows, and the writes are the verb-prefixed ones")
    func catalogueAndDispatcherAgree() {
        let offered = Set(ToolCatalog.all().map(\.name))
        #expect(offered == ToolCatalog.names)
        #expect(
            ToolCatalog.writeNames
                == offered.filter { name in ToolCatalog.writeVerbs.contains { name.hasPrefix($0) } })
    }
}
