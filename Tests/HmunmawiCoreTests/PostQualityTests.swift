import Testing
@testable import HmunmawiCore

@Suite struct PostQualityTests {
    @Test func liftedFactAndShortDraftsAreRefused() {
        #expect(PostQuality.problem("The study modeled this as an exponential decrease.") != nil)
        #expect(PostQuality.problem("According to the guidelines, strength exercises are an add-on to your 150 minutes of aerobic activity each and every week for adults.")
                == "a lifted fact sentence, no point of view")
    }

    @Test func realWorkPostPasses() {
        let post = "Two apps went into App Review the same week. One was approved in about 15 minutes, the other waited 5 days. Same account, same kind of update. I stopped reading anything into review times."
        #expect(PostQuality.problem(post) == nil)
    }

    @Test func questionRanksFirstWithTodaysWeights() {
        let question = "I shipped an onboarding change last week and day-one retention moved from 21% to 25%. What do you show first-time users before asking for anything?"
        let numbers = "I shipped an onboarding change last week and day-one retention moved from 21% to 25% across 3 apps and 2 regions in 7 days."
        #expect(PostQuality.score(question) > PostQuality.score(numbers))
    }

    /// The `param!` lines exactly as X's code writes them (single- and multi-line).
    static let before = """
    param!(
        FavoriteWeight,
        f64,
        "rust_home_mixer_favorite_weight",
        0.708
    );
    param!(RetweetWeight, f64, "rust_home_mixer_retweet_weight", 1.0);
    param!(QuoteWeight, f64, "rust_home_mixer_quote_weight", 5.0);
    param!(ReplyWeight, f64, "rust_home_mixer_reply_weight", 5.0);
    param!(
        ShareViaDmWeight,
        f64,
        "rust_home_mixer_share_via_dm_weight",
        5.0
    );
    param!(
        ShareViaCopyLinkWeight,
        f64,
        "rust_home_mixer_share_via_copy_link_weight",
        20.0
    );
    param!(DwellWeight, f64, "rust_home_mixer_dwell_weight", 0.05);
    """

    @Test func parsesXsParams() {
        let p = XAlgorithm.parseParams(Self.before)
        #expect(p["ReplyWeight"] == 5.0 && p["ShareViaCopyLinkWeight"] == 20.0 && p["ShareViaDmWeight"] == 5.0 && p["DwellWeight"] == 0.05)
    }

    @Test func copyLinkGoingToZeroLowersNumbers() throws {
        let old = try #require(XAlgorithm.rules(from: XAlgorithm.parseParams(Self.before), commit: "cec6168293", day: "2026-11-12"))
        let after = Self.before.replacingOccurrences(of: "20.0", with: "0.0")
        let new = try #require(XAlgorithm.rules(from: XAlgorithm.parseParams(after), commit: "590f3926e5", day: "2026-11-13"))
        #expect(old.numbersEach == 1.5 && new.numbersEach == 0.5)
        #expect(new.question == 1.5 && new.lessonWords == 1.0 && new.longPost == 1.0)
        #expect(new == PostRules().with(source: new.source, updated: new.updated))   // today's built-in rules match X's 13 Nov code
    }

    @Test func missingWeightsKeepTheRules() {
        #expect(XAlgorithm.rules(from: ["ReplyWeight": 5], commit: "x", day: "2026-11-14") == nil)
    }

    @Test func weightsStayInBounds() throws {
        let wild = try #require(XAlgorithm.rules(from: ["ReplyWeight": 500, "ShareViaCopyLinkWeight": -9, "ShareViaDmWeight": 5, "DwellWeight": 0.05],
                                                 commit: "x", day: "2026-11-14"))
        #expect(wild.question == 3 && wild.numbersEach >= 0)
    }
}

extension PostRules {
    func with(source: String, updated: String) -> PostRules { var r = self; r.source = source; r.updated = updated; return r }
}

@Suite struct PostingHoursTests {
    static func p(_ h: Int, likes: Int = 0, replies: Int = 0) -> PostingHours.Post {
        .init(hour: h, likes: likes, replies: replies, reposts: 0, quotes: 0, views: 100)
    }

    @Test func picksTheHoursThatEarnedMostRepliesAndLikes() throws {
        let posts = [Self.p(9, replies: 4), Self.p(9, replies: 3), Self.p(19, likes: 20, replies: 2), Self.p(14), Self.p(11), Self.p(16)]
        let hours = try #require(PostingHours.best(posts, count: 2, gap: 3))
        #expect(hours == [9, 19])
    }

    @Test func keepsTheGapAndTheDaytimeWindow() throws {
        let posts = (8...21).map { Self.p($0, replies: $0 == 20 ? 9 : 1) }
        let hours = try #require(PostingHours.best(posts, count: 4, gap: 3))
        #expect(hours.count == 4 && zip(hours, hours.dropFirst()).allSatisfy { $1 - $0 >= 3 })
        #expect(hours.allSatisfy { (8...21).contains($0) } && hours.contains(20))
    }

    @Test func tooFewPostsKeepsTheRoutinesOwnTimes() {
        #expect(PostingHours.best([Self.p(9), Self.p(10)], count: 2, gap: 3) == nil)
    }
}
