import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct WallOfAppsTests {
    @Test func idsAndLinks() {
        #expect(WallOfApps.appID("1234567890") == "1234567890")
        #expect(WallOfApps.appID("https://apps.apple.com/us/app/x/id6759220059?uo=4") == "6759220059")
        #expect(WallOfApps.appID("abc") == nil && WallOfApps.appID("12") == nil)
    }
    @Test func entryFromLookupAndMerge() {
        let data = Data(#"{"resultCount":1,"results":[{"trackName":"Pocket Garden","trackViewUrl":"https://apps.apple.com/us/app/pocket-garden/id123456789?uo=4","artworkUrl512":"https://is1-ssl.mzstatic.com/x/512x512bb.jpg"}]}"#.utf8)
        let e = WallOfApps.entry(fromLookup: data)
        #expect(e?.app == "Pocket Garden")
        #expect(WallOfApps.entry(fromLookup: Data(#"{"resultCount":0,"results":[]}"#.utf8)) == nil)
        let old = WallOfApps.Entry(app: "Pocket Garden (old)", link: "https://apps.apple.com/us/app/pocket-garden/id123456789", icon: "https://a")
        let z = WallOfApps.Entry(app: "Zeta", link: "https://apps.apple.com/us/app/zeta/id999999999", icon: "https://b")
        let wall = WallOfApps.merged([z, old], adding: e!)
        #expect(wall.map(\.app) == ["Pocket Garden", "Zeta"])
    }
    @Test func newestFirstWithDeveloperAndDay() {
        let data = Data(#"{"resultCount":1,"results":[{"trackId":123456789,"artistName":"Example Studio","trackName":"Pocket Garden","trackViewUrl":"https://apps.apple.com/us/app/pocket-garden/id123456789?uo=4","artworkUrl512":"https://is1-ssl.mzstatic.com/x/512x512bb.jpg"}]}"#.utf8)
        let e = WallOfApps.entry(fromLookup: data)!
        #expect(e.id == "123456789" && e.developer == "Example Studio")
        let older = WallOfApps.Entry(app: "Alpha", link: "https://apps.apple.com/us/app/alpha/id111111111", icon: "https://a", added: "2026-11-01")
        let wall = WallOfApps.merged([older], adding: e, today: "2026-11-14")
        #expect(wall.map(\.app) == ["Pocket Garden", "Alpha"])
        #expect(wall.first?.added == "2026-11-14")
        // The same app again (by id) replaces, never duplicates.
        #expect(WallOfApps.merged(wall, adding: e, today: "2026-11-15").filter { $0.appID == "123456789" }.count == 1)
        #expect(WallOfApps.shareText(e).contains("Pocket Garden"))
    }
}
