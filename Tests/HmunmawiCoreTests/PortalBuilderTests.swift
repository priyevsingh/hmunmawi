import Testing
@testable import HmunmawiCore

@Suite struct PortalBuilderTests {
    typealias B = PortalBuilder

    @Test func escapesEverythingItWrites() {
        let page = B.Page(product: "<Apps & co>", updated: "Updated now", glance: ["a \"quoted\" <b>"],
                          sections: [B.Section(id: "x", title: "T<script>", meaning: "1 < 2", stats: [B.Stat("$5", "Earned's")])])
        let html = B.html(page, css: "")
        #expect(!html.contains("<script>") && html.contains("T&lt;script&gt;"))
        #expect(html.contains("&lt;Apps &amp; co&gt;") && html.contains("Earned&#39;s") && html.contains("&quot;quoted&quot;"))
    }

    @Test func emptySectionsAreLeftOut() {
        let page = B.Page(product: "P", updated: "u", sections: [
            B.Section(id: "empty", title: "Nothing"),
            B.Section(id: "apps", title: "Apps", tiles: [B.Tile(name: "Quiet")]),
            B.Section(id: "money", title: "Money", headline: "$12")])
        let html = B.html(page, css: "")
        #expect(!html.contains("Nothing") && !html.contains("Quiet") && html.contains("$12"))
        #expect(html.contains("id=\"money\"") && html.contains("noindex"))
    }

    @Test func anchorsAreSafe() {
        #expect(B.anchor("s-Hill Trails|trail-pulse") == "s-hill-trails-trail-pulse")
    }
}

@Suite struct PortalPublicSafeTests {
    typealias B = PortalBuilder

    @Test func publicSafeDropsEveryAmount() {
        var money = B.Section(id: "money", title: "Money", headline: "$1,140", unit: "earned",
                              stats: [B.Stat("$86", "MRR", money: true), B.Stat("13", "Paying subscribers"), B.Stat("+14%", "vs before")],
                              spark: B.Spark(caption: "Earned", values: [1, 2], start: "a", end: "b"), details: [("Week before", "$900")])
        money.moneyHeadline = true; money.moneySpark = true
        var health = B.Section(id: "health", title: "Health", meaning: "1 needs a look", lines: ["Key expires"]); health.privateLines = true
        var latest = B.Section(id: "latest", title: "Latest", lines: ["New sale $2.99"]); latest.privateSection = true
        let apps = B.Section(id: "apps", title: "Apps", tiles: [B.Tile(name: "A", headline: "22", stats: [B.Stat("₹1,140", "Earned", money: true)])])
        let page = B.Page(product: "P", updated: "u", glance: ["Earnings rose to $4.20 a day", "Downloads rose to 40"],
                          sections: [money, health, latest, apps])
        let html = B.html(B.publicSafe(page), css: "")
        for leak in ["$1,140", "$86", "$900", "₹1,140", "$2.99", "$4.20", "Key expires", "Latest"] { #expect(!html.contains(leak), "\(leak)") }
        for keep in ["13", "+14%", "22", "Downloads rose to 40", "1 needs a look"] { #expect(html.contains(keep), "\(keep)") }
    }

    @Test func earlierCopiesAreLinked() {
        let page = B.Page(product: "P", updated: "u", sections: [B.Section(id: "m", title: "M", headline: "1")],
                          earlier: [("Thursday 12 November", "earlier/2026-11-12.html")])
        let html = B.html(page, css: "")
        #expect(html.contains("Earlier copies") && html.contains("href=\"earlier/2026-11-12.html\""))
    }
}
