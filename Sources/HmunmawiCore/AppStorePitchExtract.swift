import Foundation

/// Structured, concise product highlights derived automatically from an app's App Store Connect / App Store listing.
public struct AppPitchHighlights: Codable, Hashable, Sendable {
    public var outcome: String
    public var bullets: [String]
    public var whatsNew: [String]
    public var sourceDescription: String?
    public var fetchedAt: String?

    public init(outcome: String = "", bullets: [String] = [], whatsNew: [String] = [],
                sourceDescription: String? = nil, fetchedAt: String? = nil) {
        self.outcome = outcome; self.bullets = bullets; self.whatsNew = whatsNew
        self.sourceDescription = sourceDescription; self.fetchedAt = fetchedAt
    }
}

public enum AppStorePitchExtract {
    private static let maxBulletChars = 138

    private static let highSignalSectionTokens = [
        "sees what no single", "correlation", "why", "echo", "how it works", "what it"
    ]

    private static let strongKeywords = [
        "correlat", "while", "connect", "pair", "trigger", "pattern",
        "camera", "form", "grade", "on your iphone", "no account", "private", "without"
    ]

    private static let domainKeywords = [
        "recovery", "readiness", "hrv", "sleep", "group", "battle", "score"
    ]

    private static let excludedBulletTokens = [
        "found a bug", "rating or review", "leave a review", "settings ->", "settings →",
        "privacy", "medical advice", "in-app purchase", "cancel anytime",
        "auto-renew", "itunes account", "terms of use", "terms of service", "eula"
    ]

    private static let excludedPricingSectionTokens = [
        "in-app purchase", "subscription", "pricing", "pro (", "legal", "disclaimer", "support"
    ]

    private static let excludedWhatsNewTokens = [
        "found a bug", "feedback", "support", "settings ->", "settings →",
        "enjoying", "review on the app store", "version"
    ]

    private static let declineSignals = [
        "no thanks", "not interested", "not a fit", "pass on"
    ]

    private static let promoRequestPhrases = [
        "promo code", "offer code", "free code", "redeem code", "coupon",
        "review code", "review copy", "press copy", "full access",
        "try pro", "unlock pro", "lifetime code", "testflight",
        "send a code", "share a code", "got a code"
    ]

    private static let couponLeakTokens = [
        "free code", "promo code", "offer code", "coupon",
        "free4life", "free lifetime", "lifetime access", "apps.apple.com/redeem"
    ]

    /// Extracts a plain, outcome-led summary + 2-3 short scannable highlight bullets (prioritizing correlations
    /// and unique differentiators) and optional short release-note bullets from App Store metadata.
    public static func summarize(
        description: String,
        whatsNew: String? = nil,
        maxOutcomeChars: Int = 190,
        maxBullets: Int = 3,
        maxWhatsNew: Int = 2
    ) -> AppPitchHighlights {
        let normalizedDesc = normalizeNewlines(description)
        let outcome = extractOutcome(from: normalizedDesc, maxChars: maxOutcomeChars)
        let bullets = extractBullets(from: normalizedDesc, outcome: outcome, maxBullets: maxBullets)
        let releaseNotes = extractWhatsNew(whatsNew, maxItems: maxWhatsNew)
        return AppPitchHighlights(outcome: outcome, bullets: bullets, whatsNew: releaseNotes)
    }

    /// True only when an external recipient's reply explicitly requests full access or a promo/review code.
    public static func replyWantsPromoCode(_ text: String) -> Bool {
        let s = collapseWhitespace(text).lowercased()
        guard !s.isEmpty else { return false }
        if declineSignals.contains(where: s.contains) { return false }
        if promoRequestPhrases.contains(where: s.contains) { return true }
        let codeNearAction = #"\b(try|test|testing|share|sharing|send|sending)\b(?:\W+\w+){0,6}\W+\bcodes?\b|\bcodes?\b(?:\W+\w+){0,6}\W+\b(try|test|testing|share|sharing|send|sending)\b"#
        return s.range(of: codeNearAction, options: .regularExpression) != nil
    }

    /// Refuses unsolicited coupon/code/lifetime giveaways when `allowCode` is false.
    public static func couponLeakProblem(_ text: String, allowCode: Bool) -> String? {
        guard !allowCode else { return nil }
        let s = collapseWhitespace(text).lowercased()
        if couponLeakTokens.contains(where: s.contains) {
            return "unsolicited promo/lifetime code mention"
        }
        return nil
    }

    // MARK: - Outcome

    private static func extractOutcome(from text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        let paragraphs = text.components(separatedBy: "\n\n")
        var fallbackCandidate: String?

        for rawParagraph in paragraphs {
            let lines = rawParagraph.split(separator: "\n", omittingEmptySubsequences: true)
                .map { collapseWhitespace(String($0)) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            // Drop ALL-CAPS section headers and noisy pricing/footer lines from the paragraph.
            let proseLines = lines.filter { line in
                !isAllCapsHeader(line) && !isMarkdownHeader(line) && !isPricingOrFooterLine(line)
            }
            guard !proseLines.isEmpty else { continue }

            // Skip paragraphs that are purely bullet lists unless we have no prose fallback.
            let nonBulletLines = proseLines.filter { !isBulletLine($0) }
            if nonBulletLines.isEmpty {
                if fallbackCandidate == nil, let first = proseLines.first {
                    fallbackCandidate = cleanBulletText(first)
                }
                continue
            }

            let joined = collapseWhitespace(nonBulletLines.joined(separator: " "))
            if isPricingOrFooterLine(joined) { continue }
            return takeSentences(from: joined, maxChars: maxChars)
        }

        if let fallback = fallbackCandidate {
            return takeSentences(from: fallback, maxChars: maxChars)
        }
        return ""
    }

    private static func takeSentences(from paragraph: String, maxChars: Int) -> String {
        let sentences = splitSentences(paragraph)
        guard let first = sentences.first else { return trimCleanly(paragraph, maxChars: maxChars) }
        if first.count > maxChars {
            return trimCleanly(first, maxChars: maxChars)
        }
        if sentences.count >= 2 {
            let combined = first + " " + sentences[1]
            if combined.count <= maxChars {
                return combined
            }
        }
        return first
    }

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sub, _, _, _ in
            guard let sub else { return }
            let cleaned = collapseWhitespace(sub)
            if !cleaned.isEmpty { sentences.append(cleaned) }
        }
        return sentences.isEmpty ? [collapseWhitespace(text)] : sentences
    }

    // MARK: - Bullets

    private struct ScoredBullet {
        let text: String
        let score: Int
        let order: Int
    }

    private static func extractBullets(from text: String, outcome: String, maxBullets: Int) -> [String] {
        guard maxBullets > 0 else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var currentHeader = ""
        var candidates: [ScoredBullet] = []

        for (idx, rawLine) in lines.enumerated() {
            let trimmed = collapseWhitespace(rawLine)
            if trimmed.isEmpty { continue }

            if isSectionHeader(trimmed, nextLine: idx + 1 < lines.count ? lines[idx + 1] : nil) {
                currentHeader = trimmed.lowercased()
                continue
            }

            let explicitBullet = isBulletLine(trimmed)
            let cleaned = cleanBulletText(explicitBullet ? stripBulletMarker(trimmed) : trimmed)
            guard !cleaned.isEmpty, cleaned.count >= 12 else { continue }
            guard !isExcludedBullet(cleaned, sectionHeader: currentHeader) else { continue }

            let lower = cleaned.lowercased()
            let inHighSignalSection = highSignalSectionTokens.contains(where: currentHeader.contains)
            let strongHits = strongKeywords.filter { lower.contains($0) }.count
            let domainHits = domainKeywords.filter { lower.contains($0) }.count

            // Non-bullet prose only qualifies when it is a concise insight/correlation line and not too long.
            if !explicitBullet {
                guard cleaned.count <= 180, (inHighSignalSection || strongHits > 0 || domainHits > 0) else { continue }
                if isSimilarToOutcome(cleaned, outcome: outcome) { continue }
            }

            let score = (explicitBullet ? 2 : 0) + (inHighSignalSection ? 4 : 0) + (strongHits * 3) + (domainHits * 2)
            let capped = trimCleanly(cleaned, maxChars: maxBulletChars)
            candidates.append(ScoredBullet(text: capped, score: score, order: idx))
        }

        let sorted = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.order < rhs.order
        }

        var selected: [String] = []
        for candidate in sorted {
            if selected.contains(where: { isDuplicateBullet($0, candidate.text) }) { continue }
            selected.append(candidate.text)
            if selected.count >= maxBullets { break }
        }
        return selected
    }

    // MARK: - What's New

    private static func extractWhatsNew(_ whatsNew: String?, maxItems: Int) -> [String] {
        guard maxItems > 0, let whatsNew else { return [] }
        let lines = normalizeNewlines(whatsNew).split(separator: "\n", omittingEmptySubsequences: true)
        var out: [String] = []

        for rawLine in lines {
            let stripped = collapseWhitespace(stripBulletMarker(String(rawLine)))
            guard !stripped.isEmpty else { continue }
            let lower = stripped.lowercased()
            if excludedWhatsNewTokens.contains(where: lower.contains) { continue }
            if containsEmailOrURL(stripped) { continue }
            if isAllCapsHeader(stripped) || lower == "what's new:" || lower == "whats new:" { continue }
            // Skip bare app-version title headers like "ExampleApp 3.9.2" in release notes.
            if stripped.count <= 40, stripped.wholeMatch(of: /^[^\n]{1,30}\s+v?\d+\.\d+(?:\.\d+)?$/) != nil { continue }

            let capped = trimCleanly(stripped, maxChars: maxBulletChars)
            if !out.contains(where: { isDuplicateBullet($0, capped) }) {
                out.append(capped)
                if out.count >= maxItems { break }
            }
        }
        return out
    }

    // MARK: - Helpers

    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAllCapsHeader(_ line: String) -> Bool {
        let letters = line.filter { $0.isLetter }
        guard letters.count >= 3 else { return false }
        return line == line.uppercased() && line != line.lowercased()
    }

    private static func isMarkdownHeader(_ line: String) -> Bool {
        line.hasPrefix("#")
    }

    private static func isSectionHeader(_ line: String, nextLine: String?) -> Bool {
        if isAllCapsHeader(line) || isMarkdownHeader(line) { return true }
        let lower = line.lowercased()
        if line.count <= 65, line.hasSuffix(":"), !isBulletLine(line),
           nextLine.map({ isBulletLine(collapseWhitespace($0)) }) ?? false {
            return true
        }
        if line.count <= 55, !line.hasSuffix("."), !line.hasSuffix("!"), !isBulletLine(line),
           highSignalSectionTokens.contains(where: lower.contains) {
            return true
        }
        return false
    }

    private static func isPricingOrFooterLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let tokens = [
            "in-app purchase", "unlock every", "unlock all", "pro (", "pro version",
            "subscription", "auto-renew", "cancel anytime", "free trial",
            "found a bug", "rating or review", "leave a review", "medical advice",
            "terms of use", "terms of service", "privacy policy", "eula",
            "questions? email", "contact support", "follow us"
        ]
        if tokens.contains(where: lower.contains) { return true }
        if containsEmailOrURL(line) && line.count < 120 { return true }
        return false
    }

    private static func isBulletLine(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        return s.range(of: #"^(?:[-•*–—▪▸✓✔✅🔹]|\d+[.)])\s*"#, options: .regularExpression) != nil
            && (s.first.map { "-•*–—▪▸✓✔✅🔹".contains($0) } ?? false || s.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil)
    }

    private static func stripBulletMarker(_ line: String) -> String {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.replacingOccurrences(of: #"^(?:[-•*–—▪︎▪▸✓✔✅🔹]+\s*|\d+[.)]\s+)"#, with: "", options: .regularExpression)
    }

    private static func cleanBulletText(_ text: String) -> String {
        var s = collapseWhitespace(text)
        let promoTagPattern = #"\s*(?:\((?:pro|pro only|premium|in-app purchase|iap|new!?)\)|\[(?:pro|new!?)\]|[—-]\s*pro(?:\s+only)?)\s*$"#
        s = s.replacingOccurrences(of: promoTagPattern, with: "", options: [.regularExpression, .caseInsensitive])
        return collapseWhitespace(s)
    }

    private static func isExcludedBullet(_ text: String, sectionHeader: String) -> Bool {
        let lower = text.lowercased()
        if excludedPricingSectionTokens.contains(where: sectionHeader.contains) { return true }
        if excludedBulletTokens.contains(where: lower.contains) { return true }
        if containsEmailOrURL(text) { return true }
        if lower.hasPrefix("11 exercises:") || lower.range(of: #"^\d+\s+exercises:"#, options: .regularExpression) != nil {
            let hasDifferentiator = strongKeywords.contains(where: lower.contains)
            if !hasDifferentiator { return true }
        }
        return false
    }

    private static func containsEmailOrURL(_ text: String) -> Bool {
        if text.range(of: #"https?://|www\."#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return text.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) != nil
    }

    private static func trimCleanly(_ text: String, maxChars: Int) -> String {
        let s = collapseWhitespace(text)
        guard maxChars > 0 else { return "" }
        guard s.count > maxChars else { return s }
        if maxChars <= 3 { return String(s.prefix(maxChars)) }

        // If a complete sentence ends cleanly within maxChars (and isn't tiny), prefer that without ellipsis.
        let prefix = String(s.prefix(maxChars))
        if let sentenceEnd = prefix.range(of: #"[.!?](?=\s|$)"#, options: [.regularExpression, .backwards]),
           prefix.distance(from: prefix.startIndex, to: sentenceEnd.lowerBound) >= maxChars / 2 {
            return String(prefix[..<sentenceEnd.upperBound]).trimmingCharacters(in: .whitespaces)
        }

        // Otherwise cut cleanly at a word boundary and append ellipsis without dangling punctuation.
        let limitIdx = s.index(s.startIndex, offsetBy: maxChars - 1)
        let candidateSlice = s[..<limitIdx]
        let cutEnd: String.Index
        if s[limitIdx].isWhitespace {
            cutEnd = limitIdx
        } else if let lastSpace = candidateSlice.lastIndex(where: { $0.isWhitespace }) {
            cutEnd = lastSpace
        } else {
            cutEnd = limitIdx
        }

        var trimmed = String(s[..<cutEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let dangling = CharacterSet(charactersIn: ",;:-–—(/\\")
        while let last = trimmed.unicodeScalars.last, dangling.contains(last) || CharacterSet.whitespaces.contains(last) {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? String(s.prefix(maxChars - 1)) + "…" : trimmed + "…"
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        let lower = text.lowercased().replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
        return lower.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private static func isDuplicateBullet(_ a: String, _ b: String) -> Bool {
        let ta = normalizedTokens(a), tb = normalizedTokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let prefixCount = min(4, min(ta.count, tb.count))
        if prefixCount >= 3, ta.prefix(prefixCount) == tb.prefix(prefixCount) { return true }
        let setA = Set(ta), setB = Set(tb)
        let union = setA.union(setB).count
        guard union > 0 else { return false }
        let jaccard = Double(setA.intersection(setB).count) / Double(union)
        return jaccard >= 0.72
    }

    private static func isSimilarToOutcome(_ candidate: String, outcome: String) -> Bool {
        let ta = Set(normalizedTokens(candidate)), tb = Set(normalizedTokens(outcome))
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let overlap = Double(ta.intersection(tb).count) / Double(min(ta.count, tb.count))
        return overlap >= 0.8
    }
}
