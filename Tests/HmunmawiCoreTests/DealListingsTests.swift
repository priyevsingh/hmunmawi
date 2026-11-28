import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct DealListingsTests {
    @Test func platformFilteringExcludesMacOnlyForIOSApps() {
        let iosDirs = DealDirectory.builtIn.filter { $0.supports(platform: .ios) && $0.isFree }
        #expect(iosDirs.contains(where: { $0.id == "indie-app-sales" }))
        #expect(iosDirs.contains(where: { $0.id == "indie-goodies" }))
        #expect(iosDirs.contains(where: { $0.id == "rare-big-deal" }))
        #expect(iosDirs.contains(where: { $0.id == "awesome-bfcm" }))
        #expect(!iosDirs.contains(where: { $0.id == "apps-deals" }))

        let macDirs = DealDirectory.builtIn.filter { $0.supports(platform: .mac) && $0.isFree }
        #expect(macDirs.contains(where: { $0.id == "apps-deals" }))
    }

    @Test func indieGoodiesJSONFormatAndRules() {
        let sub = DealSubmission(
            directoryID: "indie-goodies",
            appName: "Example App",
            platforms: [.ios, .watch],
            productURL: "https://example.com/app",
            iconURL: "https://example.com/icon.png",
            shortDescription: "Calm health dashboard on iPhone and Watch.",
            dealSummary: "60% off lifetime with code SAVE60",
            offerCode: "SAVE60",
            pricing: .lifetime,
            regularPrice: 99.99,
            salePrice: 39.99,
            startDate: "2026-11-27",
            endDate: "2027-04-29"
        )
        let json = DealFormatters.indieGoodiesJSON(for: sub)
        #expect(json.hasSuffix("\n"))
        #expect(json.contains("\"description\": \"Calm health dashboard on iPhone and Watch\""))
        #expect(json.contains("\"discount\": 60"))
        #expect(json.contains("\"platforms\": [\"ios\", \"watch\"]"))

        let ig = DealDirectory.builtIn.first { $0.id == "indie-goodies" }!
        let checkWithPeriod = DealPreflightValidator.validateSync(sub, directory: ig, existingBook: DealListingsBook(), today: "2026-11-28")
        #expect(!checkWithPeriod.ok)
        #expect(checkWithPeriod.errors.contains(where: { $0.contains("trailing period") }))
    }

    @Test func markdownTableBottomInsertionAndEmojiAnchor() {
        let sample = """
        ## 💪 Health and Fitness

        | | Name | Description | Deal |
        | - | - | - | - |
        | 🏃 | [First](https://example.com/1) | First app | 50% off |

        ## 🎯 Miscellaneous
        """
        let bfcm = DealDirectory.builtIn.first { $0.id == "awesome-bfcm" }!
        let sub = DealSubmission(
            directoryID: "awesome-bfcm",
            appName: "Second App",
            platforms: [.ios],
            productURL: "https://example.com/2",
            shortDescription: "Second app",
            dealSummary: "20% off lifetime",
            offerCode: "CODE20",
            pricing: .lifetime,
            regularPrice: 49.99,
            salePrice: 39.99,
            startDate: "2026-11-27",
            endDate: "2027-04-29"
        )
        let row = DealFormatters.markdownTableRow(for: sub, directory: bfcm)
        let updated = DealFormatters.appendRowToMarkdownSection(sample, row: row, heading: "## 💪 Health and Fitness")
        #expect(updated != nil)
        #expect(updated?.contains("| 🏃 | [First]") == true)
        #expect(updated?.contains("| ✨ | [Second App](https://example.com/2)") == true)
        #expect(DealFormatters.githubAnchor(forHeading: "## 💪 Health and Fitness") == "#-health-and-fitness")
    }

    @Test func liveURLResolutionFromMergeCommentAndTemplates() {
        let rbd = DealDirectory.builtIn.first { $0.id == "rare-big-deal" }!
        let ig = DealDirectory.builtIn.first { $0.id == "indie-goodies" }!
        let subRBD = DealSubmission(
            directoryID: "rare-big-deal",
            appName: "Body Vitals",
            productURL: "https://example.com/bv",
            shortDescription: "Health widget",
            dealSummary: "60% off",
            regularPrice: 99.99,
            salePrice: 39.99,
            startDate: "2026-11-27",
            endDate: "2027-04-29"
        )
        let fromComment = DealFormatters.resolveLiveListingURL(
            for: subRBD,
            directory: rbd,
            mergeComment: "Merged! Live at https://rarebigdeal.com/products/body-vitals"
        )
        #expect(fromComment == "https://rarebigdeal.com/products/body-vitals")
        #expect(DealFormatters.resolveLiveListingURL(for: subRBD, directory: rbd) == "https://rarebigdeal.com/products/body-vitals")

        let subIG = DealSubmission(
            directoryID: "indie-goodies",
            appName: "Body Vitals",
            productURL: "https://example.com/bv",
            iconURL: "https://example.com/icon.png",
            shortDescription: "Health widget",
            dealSummary: "60% off",
            regularPrice: 99.99,
            salePrice: 39.99,
            startDate: "2026-11-27",
            endDate: "2027-04-29"
        )
        #expect(DealFormatters.resolveLiveListingURL(for: subIG, directory: ig) == "https://indiegoodies.com/blackfriday")
    }

    @Test func storeRoundtripAndQuotaGuard() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-deals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: DealListingsStore.fileName)

        let s1 = DealSubmission(
            directoryID: "indie-goodies",
            appName: "App One",
            productURL: "https://example.com/1",
            iconURL: "https://example.com/1.png",
            shortDescription: "One",
            dealSummary: "50% off",
            regularPrice: 20,
            salePrice: 10,
            startDate: "2026-11-27",
            endDate: "2027-04-29"
        )
        let s2 = DealSubmission(
            directoryID: "indie-goodies",
            appName: "App Two",
            productURL: "https://example.com/2",
            iconURL: "https://example.com/2.png",
            shortDescription: "Two",
            dealSummary: "50% off",
            regularPrice: 20,
            salePrice: 10,
            startDate: "2026-11-27",
            endDate: "2027-04-29"
        )
        let book = DealListingsBook(submissions: [s1, s2], updatedAt: "2026-11-28T00:00:00Z")
        DealListingsStore.save(book, to: fileURL)
        let loaded = DealListingsStore.load(fileURL)
        #expect(loaded.submissions.count == 2)

        let ig = DealDirectory.builtIn.first { $0.id == "indie-goodies" }!
        let s3 = DealSubmission(
            directoryID: "indie-goodies",
            appName: "App Three",
            productURL: "https://example.com/3",
            iconURL: "https://example.com/3.png",
            shortDescription: "Three",
            dealSummary: "50% off",
            regularPrice: 20,
            salePrice: 10,
            startDate: "2026-11-27",
            endDate: "2027-04-29"
        )
        let res = DealPreflightValidator.validateSync(s3, directory: ig, existingBook: loaded, today: "2026-11-28")
        #expect(!res.ok)
        #expect(res.errors.contains(where: { $0.contains("at most 2 deals") }))
    }
}
