import Foundation
import HmunmawiCore
import Testing
@testable import HmunmawiApp

/// Resources/WhatsNew.json is the one source for the Today card and the update window: it must have this version's
/// notes, newest first, and every button must open a real screen.
@Suite struct WhatsNewFileTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @MainActor @Test func notesCoverThisVersionAndOpenRealScreens() throws {
        let notes = try #require(WhatsNew.decode(Data(contentsOf: Self.root.appending(path: "Resources/WhatsNew.json"))))
        let plist = try #require(NSDictionary(contentsOf: Self.root.appending(path: "Resources/Info.plist")))
        let version = try #require(plist["CFBundleShortVersionString"] as? String)
        #expect(notes.versions.first?.version == version, "Add \(version)'s notes to Resources/WhatsNew.json")
        let order = notes.versions.map(\.version)
        #expect(order == order.sorted { WhatsNew.compare($0, $1) == .orderedDescending } && Set(order).count == order.count)
        for item in notes.versions.flatMap(\.items) + notes.start_here {
            #expect((1...3).contains(item.detail.split(separator: ".").count) && item.detail.count <= 260, "\(item.title): keep it to 2-4 lines")
            if let a = item.action { #expect(WhatsNewCard.buttonTitle(a) != nil, "\(a) opens nothing") }
        }
        #expect(notes.versions.allSatisfy { (1...3).contains($0.items.count) } && !notes.start_here.isEmpty)
        #expect(WhatsNewCard.buttonTitle("settings:jobs") == "Open Jobs" && WhatsNewCard.buttonTitle("page:automations") == "Open Automations")
    }
}
