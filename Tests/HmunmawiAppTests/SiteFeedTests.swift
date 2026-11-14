import Foundation
import Testing
@testable import HmunmawiApp
@testable import HmunmawiCore

/// The website Search card's footer names the window its number covers.
@Suite struct SiteFeedTests {
    @Test func footerNamesTheSourceWindow() {
        let site: JSONValue = .object(["impressions": .number(2039), "window_days": .number(7), "window": .string("1–7 Nov")])
        #expect(SiteFeed.seenFooter(site) == "Times the site showed on Google in 7 days (1–7 Nov).")
        let gsc: JSONValue = .object(["impressions_28d": .number(7964), "impressions": .number(1)])
        #expect(SiteFeed.seenFooter(gsc) == "Times the site showed on Google in 28 days.")
        // A plain number with no window said: no window is invented.
        #expect(SiteFeed.seenFooter(.object(["impressions": .number(5)])) == "Times the site showed on Google.")
        #expect(SiteFeed.seenFooter(nil) == "Times the site showed on Google in 28 days.")
    }
}
