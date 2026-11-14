import Foundation
import HmunmawiCore
import HmunmawiProtocol
import Testing

@Suite struct SearchHealthTests {
    static let sample = """
    {"generated":"2026-11-10T17:24+05:30","sites":[
     {"id":"a","name":"example.com","project":"Example Apps","status":"red","counts":{"high":1,"moderate":1,"low":0},
      "bing":{"available":false,"reason":"no Bing key"},"gsc":{"sitemaps":[]},
      "issues":[{"id":"crawl","severity":"high","source":"bing_ui","title":"Bing: limited crawl capacity","plain":"p",
        "fix_paths":[{"kind":"safari","action":"safari_steps","label":"Recheck","start_url":"https://www.bing.com/webmasters/recommendations?siteUrl=x","steps":["Open","Close"]},
                     {"kind":"api","action":"bing_submit_sitemap","label":"Resubmit sitemap"}],
        "fix_status":{"kind":"ai_code","state":"deferred","at":"2026-11-10T18:00+05:30","detail":"AI is paused; runs when the pause ends"}},
       {"id":"alt","severity":"moderate","title":"Images without alt","fix_paths":[{"kind":"ai_code","action":"site_pr","label":"Add alt text","brief":"b"}],
        "fix_status":{"kind":"api","state":"done","detail":{"action":"x","recheck":"cleared"}}}]},
     {"id":"b","name":"tours.example","project":"Sunny Tours","status":"green","issues":[]}]}
    """

    func report() throws -> SearchHealthReport {
        try JSONDecoder().decode(SearchHealthReport.self, from: Data(Self.sample.utf8))
    }

    @Test func decodesAndGroupsByProject() throws {
        let r = try report()
        #expect(r.sites.count == 2)
        #expect(SearchHealth.sites(r, project: nil).count == 2)
        #expect(SearchHealth.sites(r, project: "Sunny Tours").map(\.id) == ["b"])
        #expect(SearchHealth.sites(r, project: "My apps", members: ["example.com"]).map(\.id) == ["a"])
        #expect(SearchHealth.sites(r, project: "Other").isEmpty)
        let a = r.sites[0]
        #expect(a.missingReason("bing") == "no Bing key")
        #expect(a.missingReason("gsc") == nil)
        #expect(SearchHealth.headline(a) == "Needs attention")
        #expect(SearchHealth.headline(r.sites[1]) == "All clear")
    }

    @Test func statusLinesInPlainWords() throws {
        let i = try report().sites[0].issues
        #expect(i[0].fixStatus?.line == "Deferred: AI is paused; runs when the pause ends")
        #expect(i[1].fixStatus?.line == "Done: recheck: cleared")
        #expect(i[0].severityLabel == "Needs attention")
    }

    @Test func fixArguments() {
        let api = SearchHealthFix(kind: .api, action: "bing_submit_sitemap", label: "x")
        #expect(SearchHealth.arguments(fix: api, site: "a", issue: "i") == ["fix", "--site", "a", "--issue", "i", "--action", "bing_submit_sitemap"])
        #expect(SearchHealth.arguments(fix: SearchHealthFix(kind: .aiCode, action: "site_pr", label: "x"), site: "a", issue: "i") == ["ai-fix", "--site", "a", "--issue", "i"])
        #expect(SearchHealth.arguments(fix: SearchHealthFix(kind: .safari, action: "safari_steps", label: "x"), site: "a", issue: "i") == nil)
        #expect(SearchHealth.arguments(fix: nil, site: "a", issue: "i") == ["run", "--site", "a", "--reason", "recheck"])
    }

    @Test func reportAndScriptLocationsAreNotOwnerSpecific() {
        let none = OwnerConfig()
        #expect(SearchHealth.reportURL(owner: none, chosen: nil) == nil)
        #expect(SearchHealth.reportURL(owner: none, chosen: "/x/out/search/search_health.json")?.path == "/x/out/search/search_health.json")
        var o = OwnerConfig(enabled: true); o.hubRoot = "/hub"
        #expect(SearchHealth.reportURL(owner: o, chosen: nil)?.path == "/hub/out/search/search_health.json")
        let picked = URL(fileURLWithPath: "/mine/out/search/search_health.json")
        #expect(SearchHealth.scriptURL(report: picked, owner: none, exists: { _ in true })?.path == "/mine/scripts/search_health.py")
        #expect(SearchHealth.scriptURL(report: picked, owner: none, exists: { _ in false }) == nil)
    }

    @Test func safariOnlyOpensSearchToolPagesAndStopsAtSignIn() {
        #expect(SafariFix.isAllowed("https://www.bing.com/webmasters/crawlcontrol?siteUrl=https%3A%2F%2Fa%2F"))
        #expect(SafariFix.isAllowed("https://search.google.com/search-console/sitemaps?resource_id=x"))
        #expect(!SafariFix.isAllowed("https://www.bing.com/search?q=x"))
        #expect(!SafariFix.isAllowed("http://www.bing.com/webmasters/"))
        #expect(!SafariFix.isAllowed("https://evil.example/webmasters"))
        #expect(!SafariFix.isAllowed("https://www.bing.com/webmasters/\"&quit"))
        #expect(SafariFix.openScript("https://evil.example/") == nil)
        let s = SafariFix.openScript("https://www.bing.com/webmasters/home")!
        #expect(s.components(separatedBy: "make new tab").count == 2)  // exactly one tab
        #expect(!s.contains("set URL of"))  // never navigates an existing tab
        #expect(SafariFix.closeScript(window: 7, tab: 3).contains("u starts with \"https://www.bing.com/webmasters\""))
        #expect(SafariFix.needsYou("https://login.live.com/oauth20"))
        #expect(!SafariFix.needsYou("https://www.bing.com/webmasters/home"))
        #expect(SafariFix.parseHandle("123,4\n")! == (123, 4))
        #expect(SafariFix.parseHandle("oops") == nil)
    }

    @Test func minuteTimestamps() {
        #expect(SearchHealth.date("2026-11-10T17:24+05:30") == SearchHealth.date("2026-11-10T11:54:00Z"))
        #expect(SearchHealth.date("garbage") == nil)
    }
}
