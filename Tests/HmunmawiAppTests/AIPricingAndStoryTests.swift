import Foundation
import Testing
@testable import HmunmawiApp
@testable import HmunmawiCore

@MainActor
@Suite struct AIPricingAndStoryTests {
    @Test func builtInPricesCoverOpenAIGeminiGroq() throws {
        let m1 = try #require(AISettings.matchPrice(AISettings.builtInPrices[.openai]!, model: "gpt-4o-mini"))
        #expect(m1 == (0.15, 0.60))
        let m2 = try #require(AISettings.matchPrice(AISettings.builtInPrices[.openai]!, model: "gpt-5-2026-01-01"))
        #expect(m2 == (1.25, 10.0))
        let m3 = try #require(AISettings.matchPrice(AISettings.builtInPrices[.gemini]!, model: "gemini-2.5-flash"))
        #expect(m3 == (0.30, 2.50))
        let m4 = try #require(AISettings.matchPrice(AISettings.builtInPrices[.groq]!, model: "llama-3.3-70b-versatile"))
        #expect(m4 == (0.59, 0.79))
        #expect(AISettings.matchPrice(AISettings.builtInPrices[.openai]!, model: "unknown-custom-model") == nil)
    }

    @Test func weeklyStoryPromptForbidsDeveloperLocationAndLintCatchesForbiddenPhrase() {
        let prompt = WeeklyStory.polishPrompt(facts: ["10 sales", "MRR $50"])
        #expect(prompt.lowercased().contains("location") || prompt.lowercased().contains("city"))
        let rules = WordingRules(rules: [WordingRules.Rule(text: "clinically proven", why: "no study")])
        #expect(rules.problem("Our app is clinically proven to help") != nil)
        #expect(rules.problem("Shipped 1.6 with a faster chart.") == nil)
    }
}
