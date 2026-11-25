import Foundation
import Testing

@testable import NotesMCPCore

/// Reads this repository's own files, never the machine.
@Suite("Package")
struct PackageTests {

    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("extension/manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The installer keys on the manifest version alone, so a build whose three version
    /// strings disagree describes a build nobody has.
    @Test("The manifest, the server constant and Info.plist carry the same version")
    func versionsAgree() throws {
        let plistData = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(try manifest()["version"] as? String == NotesMCPServer.version)
        #expect(plist["CFBundleShortVersionString"] as? String == NotesMCPServer.version)
    }

    /// A tool missing from the manifest has no permission switch at all.
    @Test("The manifest lists exactly the tools the server offers")
    func manifestListsEveryTool() throws {
        let listed = try #require(try manifest()["tools"] as? [[String: Any]])
        let names = listed.compactMap { $0["name"] as? String }
        #expect(names == ToolCatalog.all().map(\.name))
        for tool in listed {
            #expect((tool["description"] as? String)?.isEmpty == false)
        }
    }

    /// The manifest is plain JSON and cannot take a figure from a constant, so this holds
    /// the bounds it states to the ones the code enforces.
    @Test("The manifest states the bounds the server enforces")
    func manifestStatesTheBounds() throws {
        let manifest = try manifest()
        let long = try #require(manifest["long_description"] as? String)
        let configuration = Configuration()
        #expect(long.contains("first \(configuration.textLimit) characters"))
        #expect(long.contains("no more than \(configuration.scanCeiling) notes"))
        #expect(long.contains("no longer than \(NoteTools.scanBudget.components.seconds) seconds"))
        #expect(long.contains("after \(NoteTools.defaultTimeout.components.seconds) seconds"))

        let tools = try #require(manifest["tools"] as? [[String: Any]])
        func described(_ name: String) -> String {
            tools.first { $0["name"] as? String == name }?["description"] as? String ?? ""
        }
        #expect(described(ToolCatalog.accountsName).contains("\(ToolCatalog.defaultAccountLimit) to a page"))
        #expect(described(ToolCatalog.foldersName).contains("\(ToolCatalog.defaultFolderLimit) to a page"))
        #expect(described(ToolCatalog.searchName).contains("\(configuration.searchLimit) to a page"))
        #expect(described(ToolCatalog.getName).contains("first \(configuration.textLimit) characters"))
        #expect(described(ToolCatalog.attachmentsName).contains("\(ToolCatalog.defaultAttachmentLimit) to a page"))
        #expect(described(ToolCatalog.deleteName).contains("first \(ToolCatalog.receiptTextWidth) characters"))
    }

    /// The server is built from the system's own frameworks and nothing else. A dependency
    /// is a decision for the owner, so adding one has to break this test first.
    @Test("The package declares no third-party dependency")
    func noDependencies() throws {
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!package.contains(".package("), "Package.swift declares a dependency")
        #expect(!package.contains(".product("))
    }
}
