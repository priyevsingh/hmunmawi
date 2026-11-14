import Foundation
import Testing
import HmunmawiCore
@testable import HmunmawiApp

@MainActor @Suite(.serialized) struct WallCommunityTests {
    static func e(_ id: String, _ name: String, added: String) -> WallOfApps.Entry {
        WallOfApps.Entry(app: name, link: "https://apps.apple.com/us/app/x/id\(id)", icon: "https://example.com/\(id).png",
                         id: id, developer: "Example Studio", added: added)
    }
    func reset() {
        for k in [WallCommunity.submittedKey, WallCommunity.sharedKey, WallCommunity.seenKey] { UserDefaults.standard.removeObject(forKey: k) }
        Bankfile.write("posts", Bankfile.read("posts").filter { $0.tag != "wall" })
    }

    @Test func yourAppOnTheWallOffersShareOnce() {
        reset(); defer { reset() }
        let w = WallCommunity()
        w.markSubmitted(Self.e("111111111", "Mine", added: "2026-11-10"))
        w.ingest([Self.e("222222222", "Other", added: "2026-11-11")])
        #expect(w.mine.isEmpty)                                   // not merged yet
        let mine = Self.e("111111111", "Mine", added: "2026-11-12")
        w.ingest([mine, Self.e("222222222", "Other", added: "2026-11-11")])
        #expect(w.mine.map(\.app) == ["Mine"])
        #expect(w.apps.first?.app == "Mine")                      // newest first
        w.finishShare(mine)
        #expect(w.mine.isEmpty)                                   // asked once
    }

    @Test func maintainerGetsOneDraftPerNewAppNoFlood() {
        reset(); defer { reset() }
        let w = WallCommunity()
        let a = Self.e("333333333", "Alpha", added: "2026-11-01"), b = Self.e("444444444", "Beta", added: "2026-11-02")
        w.ingest([a, b]); w.draftWelcomes(enabled: true)          // first read only remembers
        #expect(Bankfile.read("posts").filter { $0.tag == "wall" }.isEmpty)
        let c = Self.e("555555555", "Gamma", added: "2026-11-14")
        w.ingest([c, a, b]); w.draftWelcomes(enabled: true)
        w.draftWelcomes(enabled: true)                            // a second run adds nothing more
        let drafts = Bankfile.read("posts").filter { $0.tag == "wall" }
        #expect(drafts.count == 1 && drafts.first?.text.contains("Gamma") == true)
    }
}
