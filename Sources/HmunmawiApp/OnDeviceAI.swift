import Foundation
import FoundationModels
import HmunmawiCore

/// Apple's on-device model (macOS 26+, Apple Intelligence on): free, private, nothing leaves the Mac. Used only for
/// outreach replies the rules can't place (its answer is a "maybe" you confirm, with their words shown) and, when chosen,
/// to draft X replies you edit and post yourself.
enum OnDeviceAI {
    static var available: Bool { if case .available = SystemLanguageModel.default.availability { return true }; return false }

    @Generable enum Move: String { case answerNeeded, thanksOnly, promised, scheduled, declined, referred }
    @Generable struct Verdict {
        @Guide(description: "What the sender's message means for the next step") var move: Move
        @Guide(description: "The few words from the message that show it") var evidence: String
    }

    static let instructions = """
    You read one short email reply to an indie app developer who pitched their app to a journalist, podcaster or listing site.
    Pick exactly one:
    - answerNeeded: they ask a question or ask for something (a code, press kit, screenshots, more details, a call).
    - promised: they say they will do something later: test or download the app, consider it, cover it, mention it, get back.
    - scheduled: they give a date or time for coverage, an interview or a call.
    - declined: not a fit, not interested, not now, no.
    - referred: they point to another person or address.
    - thanksOnly: only thanks or a pleasantry, nothing asked, nothing promised.
    If a message both thanks and promises, it is promised. If it asks anything, it is answerNeeded.
    """

    /// A state for a reply the rules left unclear, or nil when the model isn't available or fails.
    static func read(_ text: String) async -> (ThreadState, String)? {
        guard available else { return nil }
        let s = LanguageModelSession(instructions: instructions)
        guard let r = try? await s.respond(to: String(text.prefix(1500)), generating: Verdict.self) else { return nil }
        let map: [Move: ThreadState] = [.answerNeeded: .yourTurn, .thanksOnly: .thanks, .promised: .promised, .scheduled: .scheduled,
                                        .declined: .declined, .referred: .referred]
        return (map[r.content.move] ?? .unclear, r.content.evidence)
    }

    // MARK: Drafting X replies (free, nothing leaves the Mac)

    /// Whether the model can run now, and if not, why (in plain words for the screen).
    static var status: (available: Bool, reason: String?) {
        switch SystemLanguageModel.default.availability {
        case .available: return (true, nil)
        case .unavailable(.deviceNotEligible): return (false, "This Mac doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled): return (false, "Turn on Apple Intelligence in System Settings.")
        case .unavailable(.modelNotReady): return (false, "Apple Intelligence is still getting ready (downloading).")
        case .unavailable: return (false, "Apple's on-device model isn't available right now.")
        }
    }

    /// One short draft. Throws when the model is unavailable or declines (Apple's safety check, a refusal, the
    /// language); callers skip that post and never retry around a safety check.
    static func draft(_ prompt: String, instructions: String) async throws -> String {
        guard available else { throw DraftError(status.reason ?? "unavailable") }
        let session = LanguageModelSession(instructions: instructions)
        let r = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.7, maximumResponseTokens: 120))
        return r.content
    }

    struct DraftError: Error { let reason: String; init(_ r: String) { reason = r } }
}
