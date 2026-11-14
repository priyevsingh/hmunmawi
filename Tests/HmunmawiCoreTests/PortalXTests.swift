import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct PortalXTests {
    static func page() -> PortalBuilder.Page {
        var x = PortalBuilder.Section(id: "x", title: "X", headline: "120", unit: "followers")
        x.xRows = [.init(kind: "pinned", label: "Pinned article", title: "How I price my apps", url: "https://x.com/example/status/1", views: 600, likes: 5),
                   .init(kind: "replies", label: "Top reply", title: "A reply", url: "https://x.com/example/status/2", views: 90, to: "@friend"),
                   .init(kind: "off", label: "Taking off", title: "Bad link", url: "javascript:alert(1)")]
        x.feed = [.init(reply: true, text: "@friend agreed", meta: "26 views · 2h ago", url: "https://x.com/example/status/3")]
        let p = PortalBuilder.Page(product: "Example", updated: "15 Nov", sections: [x])
        return p
    }

    @Test func rendersHubStyleRowsAndFeed() {
        let html = PortalBuilder.html(Self.page(), css: "")
        #expect(html.contains("class=\"xg-row pinned\"") && html.contains("How I price my apps") && html.contains("to @friend"))
        #expect(html.contains("class=\"pf-row reply\"") && html.contains("Last 24 hours"))
        #expect(!html.contains("javascript:"))                      // only x.com post links become links
    }

    @Test func publicCopyDropsFeedAndWhoYouRepliedTo() {
        let pub = PortalBuilder.publicSafe(Self.page())
        #expect(pub.sections[0].feed.isEmpty && pub.sections[0].xRows.allSatisfy { $0.to == nil })
        #expect(pub.sections[0].xRows.count == 3)
    }

    @Test func publicCopyDropsLinesWithAmounts() {
        let a = PortalBuilder.Section(id: "attention", title: "Attention", lines: ["US revenue per download is $2.47", "No written review in 35 days"])
        let pub = PortalBuilder.publicSafe(PortalBuilder.Page(product: "E", updated: "u", sections: [a]))
        #expect(pub.sections[0].lines == ["No written review in 35 days"])
    }
}
