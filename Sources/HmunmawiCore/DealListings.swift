import Foundation
import ImageIO

// MARK: - Deal & Directory Launch Types

public enum DealPlatform: String, Codable, Sendable, CaseIterable, Hashable {
    case ios
    case mac
    case watch
    case tv
    case web

    public var label: String {
        switch self {
        case .ios: "iOS"
        case .mac: "Mac"
        case .watch: "Watch"
        case .tv: "tvOS"
        case .web: "Web"
        }
    }
}

public enum DealDirectoryKind: String, Codable, Sendable {
    case githubJSONPR
    case githubMarkdownPR
    case webForm
    case emailPitch

    public var label: String {
        switch self {
        case .githubJSONPR: "GitHub PR (JSON)"
        case .githubMarkdownPR: "GitHub PR (Markdown)"
        case .webForm: "Web Form"
        case .emailPitch: "Email Pitch"
        }
    }
}

public enum DealPricingKind: String, Codable, Sendable, CaseIterable {
    case lifetime
    case oneTime = "one-time"
    case subscription

    public var label: String {
        switch self {
        case .lifetime: "Lifetime"
        case .oneTime: "One-time"
        case .subscription: "Subscription"
        }
    }
}

public enum DealSubmissionStatus: String, Codable, Sendable {
    case planned
    case preflightFailed
    case waitingApproval
    case prOpen
    case needsFix
    case submitted
    case merged
    case listed
    case expired

    public var label: String {
        switch self {
        case .planned: "Planned"
        case .preflightFailed: "Fix Needed"
        case .waitingApproval: "Needs your OK"
        case .prOpen: "PR Open"
        case .needsFix: "Reviewer Note"
        case .submitted: "Submitted"
        case .merged: "Merged"
        case .listed: "Listed"
        case .expired: "Expired"
        }
    }

    public var isLiveListed: Bool {
        self == .listed || self == .merged
    }
}

public struct DealDirectory: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var websiteURL: String
    public var submitURL: String
    public var kind: DealDirectoryKind
    public var platforms: [DealPlatform]
    public var isFree: Bool
    public var requiresBacklink: Bool
    public var repo: String?
    public var targetSection: String?
    public var maxPerYear: Int?
    public var maxDescriptionChars: Int?
    public var maxDealChars: Int?
    public var allowTrailingPeriodInDescription: Bool
    public var requiresIcon: Bool
    public var minIconPixels: Int
    public var liveURLTemplate: String?
    public var rulesSummary: String
    public var isCustom: Bool

    public init(
        id: String,
        name: String,
        websiteURL: String,
        submitURL: String,
        kind: DealDirectoryKind,
        platforms: [DealPlatform],
        isFree: Bool = true,
        requiresBacklink: Bool = false,
        repo: String? = nil,
        targetSection: String? = nil,
        maxPerYear: Int? = nil,
        maxDescriptionChars: Int? = nil,
        maxDealChars: Int? = nil,
        allowTrailingPeriodInDescription: Bool = true,
        requiresIcon: Bool = false,
        minIconPixels: Int = 128,
        liveURLTemplate: String? = nil,
        rulesSummary: String,
        isCustom: Bool = false
    ) {
        self.id = id
        self.name = name
        self.websiteURL = websiteURL
        self.submitURL = submitURL
        self.kind = kind
        self.platforms = platforms
        self.isFree = isFree
        self.requiresBacklink = requiresBacklink
        self.repo = repo
        self.targetSection = targetSection
        self.maxPerYear = maxPerYear
        self.maxDescriptionChars = maxDescriptionChars
        self.maxDealChars = maxDealChars
        self.allowTrailingPeriodInDescription = allowTrailingPeriodInDescription
        self.requiresIcon = requiresIcon
        self.minIconPixels = minIconPixels
        self.liveURLTemplate = liveURLTemplate
        self.rulesSummary = rulesSummary
        self.isCustom = isCustom
    }

    public func supports(platform: DealPlatform) -> Bool {
        platforms.contains(platform)
    }

    /// Built-in catalog of verified free deal directories.
    public static let builtIn: [DealDirectory] = [
        DealDirectory(
            id: "indie-app-sales",
            name: "Indie App Sales",
            websiteURL: "https://indieappsales.com",
            submitURL: "https://indieappsales.com",
            kind: .webForm,
            platforms: [.ios, .mac],
            isFree: true,
            requiresBacklink: false,
            liveURLTemplate: "https://indieappsales.com",
            rulesSummary: "Self-serve web form (sign in). Needs App Store ID, product URL, regular/sale USD price, offer code, and end date."
        ),
        DealDirectory(
            id: "indie-goodies",
            name: "Indie Goodies",
            websiteURL: "https://indiegoodies.com/blackfriday",
            submitURL: "https://github.com/onmyway133/blackfriday",
            kind: .githubJSONPR,
            platforms: [.ios, .mac, .watch, .web],
            isFree: true,
            requiresBacklink: false,
            repo: "onmyway133/blackfriday",
            targetSection: "lifestyle",
            maxPerYear: 2,
            maxDescriptionChars: 160,
            maxDealChars: 90,
            allowTrailingPeriodInDescription: false,
            requiresIcon: true,
            minIconPixels: 128,
            liveURLTemplate: "https://indiegoodies.com/blackfriday",
            rulesSummary: "PR adding YYYY/<slug>.json. Max 2 deals/maker/year, description <= 160 chars (no trailing period), deal <= 90 chars, 200 OK square icon >= 128px."
        ),
        DealDirectory(
            id: "rare-big-deal",
            name: "Rare Big Deal",
            websiteURL: "https://rarebigdeal.com",
            submitURL: "https://github.com/danmindru/rare-big-deal",
            kind: .githubMarkdownPR,
            platforms: [.ios, .mac, .tv, .web],
            isFree: true,
            requiresBacklink: false,
            repo: "danmindru/rare-big-deal",
            targetSection: "### Health & Fitness",
            liveURLTemplate: "https://rarebigdeal.com/products/{slug}",
            rulesSummary: "PR appending 1 row at the bottom of the matching README.md category table. Discount must be live and verifiable on your site or store."
        ),
        DealDirectory(
            id: "awesome-bfcm",
            name: "Awesome BFCM",
            websiteURL: "https://github.com/trungdq88/Awesome-Black-Friday-Cyber-Monday",
            submitURL: "https://github.com/trungdq88/Awesome-Black-Friday-Cyber-Monday",
            kind: .githubMarkdownPR,
            platforms: [.ios, .mac, .web],
            isFree: true,
            requiresBacklink: false,
            repo: "trungdq88/Awesome-Black-Friday-Cyber-Monday",
            targetSection: "## 💪 Health and Fitness",
            liveURLTemplate: "https://github.com/trungdq88/Awesome-Black-Friday-Cyber-Monday#-health-and-fitness",
            rulesSummary: "PR appending 1 row at the bottom of the matching README.md section. Software/apps only."
        ),
        DealDirectory(
            id: "apps-deals",
            name: "Apps.Deals",
            websiteURL: "https://apps.deals",
            submitURL: "https://apps.deals",
            kind: .webForm,
            platforms: [.mac],
            isFree: true,
            requiresBacklink: false,
            liveURLTemplate: "https://apps.deals",
            rulesSummary: "Mac apps only. Free web form submission."
        ),
    ]
}

public struct DealSubmission: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var directoryID: String
    public var appName: String
    public var appStoreID: String?
    public var platforms: [DealPlatform]
    public var productURL: String
    public var iconURL: String?
    public var shortDescription: String
    public var dealSummary: String
    public var categorySlug: String
    public var emoji: String
    public var offerCode: String?
    public var redeemURL: String?
    public var pricing: DealPricingKind
    public var regularPrice: Double
    public var salePrice: Double
    public var currency: String
    public var startDate: String
    public var endDate: String
    public var status: DealSubmissionStatus
    public var prURL: String?
    public var prNumber: Int?
    public var branchName: String?
    public var prETag: String?
    public var liveListingURL: String?
    public var liveCheckOK: Bool?
    public var lastCheckedAt: String?
    public var lastNote: String?

    public init(
        id: String = UUID().uuidString,
        directoryID: String,
        appName: String,
        appStoreID: String? = nil,
        platforms: [DealPlatform] = [.ios],
        productURL: String,
        iconURL: String? = nil,
        shortDescription: String,
        dealSummary: String,
        categorySlug: String = "lifestyle",
        emoji: String = "✨",
        offerCode: String? = nil,
        redeemURL: String? = nil,
        pricing: DealPricingKind = .lifetime,
        regularPrice: Double,
        salePrice: Double,
        currency: String = "USD",
        startDate: String,
        endDate: String,
        status: DealSubmissionStatus = .planned,
        prURL: String? = nil,
        prNumber: Int? = nil,
        branchName: String? = nil,
        prETag: String? = nil,
        liveListingURL: String? = nil,
        liveCheckOK: Bool? = nil,
        lastCheckedAt: String? = nil,
        lastNote: String? = nil
    ) {
        self.id = id
        self.directoryID = directoryID
        self.appName = appName
        self.appStoreID = appStoreID
        self.platforms = platforms
        self.productURL = productURL
        self.iconURL = iconURL
        self.shortDescription = shortDescription
        self.dealSummary = dealSummary
        self.categorySlug = categorySlug
        self.emoji = emoji
        self.offerCode = offerCode
        self.redeemURL = redeemURL
        self.pricing = pricing
        self.regularPrice = regularPrice
        self.salePrice = salePrice
        self.currency = currency
        self.startDate = startDate
        self.endDate = endDate
        self.status = status
        self.prURL = prURL
        self.prNumber = prNumber
        self.branchName = branchName
        self.prETag = prETag
        self.liveListingURL = liveListingURL
        self.liveCheckOK = liveCheckOK
        self.lastCheckedAt = lastCheckedAt
        self.lastNote = lastNote
    }

    public var discountPercent: Int {
        guard regularPrice > 0, salePrice >= 0, salePrice <= regularPrice else { return 0 }
        return Int(((regularPrice - salePrice) / regularPrice * 100.0).rounded())
    }
}

public struct DealListingsBook: Codable, Sendable, Equatable {
    public var submissions: [DealSubmission]
    public var customDirectories: [DealDirectory]
    public var updatedAt: String?

    public init(submissions: [DealSubmission] = [], customDirectories: [DealDirectory] = [], updatedAt: String? = nil) {
        self.submissions = submissions
        self.customDirectories = customDirectories
        self.updatedAt = updatedAt
    }

    public var allDirectories: [DealDirectory] {
        DealDirectory.builtIn + customDirectories
    }

    public func directory(id: String) -> DealDirectory? {
        allDirectories.first { $0.id == id }
    }
}

// MARK: - Persistence (`deal-listings.json`, 0o600 atomic writes)

public enum DealListingsStore {
    public static let fileName = "deal-listings.json"
    private static let maxBytes = 5_000_000

    public static func load(_ url: URL) -> DealListingsBook {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sz = (attrs[.size] as? NSNumber)?.intValue,
              sz > 0, sz < maxBytes,
              let data = try? Data(contentsOf: url),
              let book = try? JSONDecoder().decode(DealListingsBook.self, from: data) else {
            return DealListingsBook()
        }
        return book
    }

    public static func save(_ book: DealListingsBook, to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(book) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Formatting & Live URL Resolution

public enum DealFormatters {
    public static func slug(for appName: String) -> String {
        let lower = appName.lowercased()
        var out = ""
        var prevDash = false
        for ch in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) {
                out.unicodeScalars.append(ch)
                prevDash = false
            } else if !prevDash && !out.isEmpty {
                out.append("-")
                prevDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "app" : out
    }

    /// Computes GitHub's exact heading anchor (preserving leading `-` when an emoji precedes the title).
    public static func githubAnchor(forHeading heading: String) -> String {
        var stripped = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        while stripped.hasPrefix("#") { stripped.removeFirst() }
        stripped = stripped.trimmingCharacters(in: .whitespaces)
        var out = ""
        for ch in stripped.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) || ch == "-" {
                out.unicodeScalars.append(ch)
            } else if ch == " " {
                out.append("-")
            }
        }
        return "#\(out)"
    }

    /// Formats an Indie Goodies `YYYY/<slug>.json` payload with exact key order, 2-space indent, and trailing newline.
    public static func indieGoodiesJSON(for sub: DealSubmission) -> String {
        let cleanDesc = sub.shortDescription.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let cleanDeal = sub.dealSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let plats = sub.platforms.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        var lines: [String] = [
            "{",
            "  \"name\": \(jsonString(sub.appName)),",
            "  \"url\": \(jsonString(sub.productURL)),",
            "  \"description\": \(jsonString(cleanDesc)),",
            "  \"category\": \(jsonString(sub.categorySlug)),",
            "  \"platforms\": [\(plats)],",
            "  \"deal\": \(jsonString(cleanDeal)),",
        ]
        if let code = sub.offerCode, !code.isEmpty {
            lines.append("  \"code\": \(jsonString(code)),")
        }
        lines.append("  \"pricing\": \(jsonString(sub.pricing.rawValue)),")
        lines.append("  \"price\": { \"regular\": \(priceString(sub.regularPrice)), \"sale\": \(priceString(sub.salePrice)), \"currency\": \(jsonString(sub.currency)) },")
        lines.append("  \"discount\": \(sub.discountPercent),")
        lines.append("  \"startDate\": \(jsonString(sub.startDate)),")
        lines.append("  \"endDate\": \(jsonString(sub.endDate))" + (sub.iconURL?.isEmpty == false ? "," : ""))
        if let icon = sub.iconURL, !icon.isEmpty {
            lines.append("  \"icon\": \(jsonString(icon))")
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Formats a single Markdown table row for Rare Big Deal or Awesome BFCM.
    public static func markdownTableRow(for sub: DealSubmission, directory: DealDirectory) -> String {
        let desc = sub.shortDescription.replacingOccurrences(of: "|", with: "-")
        let codePart: String
        if let code = sub.offerCode, !code.isEmpty {
            if let redeem = sub.redeemURL, !redeem.isEmpty {
                codePart = "with code **\(code)** ([Redeem](\(redeem)))"
            } else {
                codePart = "with code **\(code)**"
            }
        } else {
            codePart = "no code needed"
        }
        let pricePart = "($\(priceString(sub.regularPrice)) → $\(priceString(sub.salePrice)) \(sub.currency))"
        let dealCell = "**\(sub.discountPercent)% OFF** \(sub.pricing.label) \(pricePart) \(codePart)."
        if directory.id == "rare-big-deal" {
            return "| \(sub.emoji) | [\(sub.appName)](\(sub.productURL)) | \(desc) | \(dealCell) | \(sub.endDate) |"
        }
        return "| \(sub.emoji) | [\(sub.appName)](\(sub.productURL)) | \(desc) | \(dealCell) **\(sub.startDate) – \(sub.endDate)**. |"
    }

    /// Appends `row` at the bottom of the Markdown table under `heading` without altering existing rows.
    public static func appendRowToMarkdownSection(_ markdown: String, row: String, heading: String) -> String? {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard let headIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading.trimmingCharacters(in: .whitespaces) }) else {
            return nil
        }
        var lastTableIdx: Int?
        var i = headIdx + 1
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") { break }
            if trimmed.hasPrefix("|") { lastTableIdx = i }
            i += 1
        }
        guard let insertAfter = lastTableIdx else { return nil }
        lines.insert(row, at: insertAfter + 1)
        return lines.joined(separator: "\n")
    }

    /// Generates clean copy-pasteable fields for self-serve web-form directories (e.g. Indie App Sales, Apps.Deals).
    public static func selfServeCopyBlock(for sub: DealSubmission, directory: DealDirectory) -> String {
        var rows: [String] = [
            "Directory: \(directory.name) (\(directory.submitURL))",
            "App Name: \(sub.appName)",
            "Website Link: \(sub.productURL)",
        ]
        if let id = sub.appStoreID, !id.isEmpty { rows.append("App Store ID: \(id)") }
        rows.append("Pricing Model: \(sub.pricing.label)")
        rows.append("Original Price (\(sub.currency)): \(priceString(sub.regularPrice))")
        rows.append("Offer Price (\(sub.currency)): \(priceString(sub.salePrice)) (\(sub.discountPercent)% off)")
        if let code = sub.offerCode, !code.isEmpty { rows.append("Offer Code: \(code)") }
        if let redeem = sub.redeemURL, !redeem.isEmpty { rows.append("Redeem URL: \(redeem)") }
        rows.append("Valid: \(sub.startDate) to \(sub.endDate)")
        rows.append("Description: \(sub.shortDescription)")
        return rows.joined(separator: "\n")
    }

    /// Resolves the exact live listed URL for a directory (from a merge comment, template, or single-page URL).
    public static func resolveLiveListingURL(for sub: DealSubmission, directory: DealDirectory, mergeComment: String? = nil) -> String? {
        if let existing = sub.liveListingURL, !existing.isEmpty { return existing }
        let s = slug(for: sub.appName)
        if let comment = mergeComment,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = comment as NSString
            let matches = detector.matches(in: comment, range: NSRange(location: 0, length: ns.length))
            let urls = matches.compactMap { $0.url?.absoluteString }
            if let hit = urls.first(where: { $0.lowercased().contains(s) }) {
                return hit
            }
        }
        if let tpl = directory.liveURLTemplate, !tpl.isEmpty {
            return tpl.replacingOccurrences(of: "{slug}", with: s)
        }
        return directory.websiteURL
    }

    private static func jsonString(_ raw: String) -> String {
        let data = try? JSONEncoder().encode(raw)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func priceString(_ v: Double) -> String {
        if v.rounded() == v { return String(format: "%.0f", v) }
        return String(format: "%.2f", v)
    }
}

// MARK: - Pre-Flight Validator

public struct DealPreflightResult: Sendable, Equatable {
    public var errors: [String]
    public var warnings: [String]
    public var ok: Bool { errors.isEmpty }

    public init(errors: [String] = [], warnings: [String] = []) {
        self.errors = errors
        self.warnings = warnings
    }
}

public enum DealPreflightValidator {
    /// Synchronous schema, date, wording, and quota checks (pure Swift, 0ms).
    public static func validateSync(
        _ sub: DealSubmission,
        directory: DealDirectory,
        existingBook: DealListingsBook,
        today: String = Self.todayISO(),
        wording: WordingRules? = nil
    ) -> DealPreflightResult {
        var errors: [String] = []
        var warnings: [String] = []

        if sub.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("App name is required.")
        }
        if !sub.productURL.lowercased().hasPrefix("https://") {
            errors.append("Product URL must start with https://.")
        }
        if sub.regularPrice <= 0 || sub.salePrice < 0 || sub.salePrice >= sub.regularPrice {
            errors.append("Sale price must be lower than regular price.")
        }
        if sub.endDate <= today {
            errors.append("End date (\(sub.endDate)) must be in the future.")
        }
        if let maxDesc = directory.maxDescriptionChars, sub.shortDescription.count > maxDesc {
            errors.append("Description is \(sub.shortDescription.count) chars (max \(maxDesc) for \(directory.name)).")
        }
        if !directory.allowTrailingPeriodInDescription && sub.shortDescription.trimmingCharacters(in: .whitespaces).hasSuffix(".") {
            errors.append("\(directory.name) does not allow a trailing period in description.")
        }
        if let maxDeal = directory.maxDealChars, sub.dealSummary.count > maxDeal {
            errors.append("Deal summary is \(sub.dealSummary.count) chars (max \(maxDeal) for \(directory.name)).")
        }
        if directory.requiresIcon {
            guard let icon = sub.iconURL, icon.lowercased().hasPrefix("https://") else {
                errors.append("\(directory.name) requires a direct https:// square icon URL.")
                return DealPreflightResult(errors: errors, warnings: warnings)
            }
        }
        if !sub.platforms.contains(where: { directory.supports(platform: $0) }) {
            errors.append("\(directory.name) only supports \(directory.platforms.map(\.label).joined(separator: ", ")).")
        }
        if let wording, let problem = wording.problem(sub.shortDescription) ?? wording.problem(sub.dealSummary) {
            warnings.append("Wording rule note: \(problem)")
        }
        let yearPrefix = String(today.prefix(4))
        let sameDirActive = existingBook.submissions.filter {
            $0.directoryID == directory.id && $0.id != sub.id && $0.status != .expired
        }
        if sameDirActive.contains(where: { $0.appName.caseInsensitiveCompare(sub.appName) == .orderedSame }) {
            warnings.append("\(sub.appName) already has an active entry for \(directory.name).")
        }
        if let maxYear = directory.maxPerYear {
            let countThisYear = sameDirActive.filter { $0.startDate.hasPrefix(yearPrefix) }.count
            if countThisYear >= maxYear {
                errors.append("\(directory.name) allows at most \(maxYear) deals per maker per year.")
            }
        }
        return DealPreflightResult(errors: errors, warnings: warnings)
    }

    public static func todayISO(now: Date = .now) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: now)
    }

    /// Thread-safe 10-minute in-memory cache for URL/icon checks.
    public actor URLCheckCache {
        private struct Entry { let ok: Bool; let note: String?; let at: Date }
        private var store: [String: Entry] = [:]

        public init() {}

        public func checkURL(_ urlString: String, requireImageMinPixels: Int? = nil) async -> (Bool, String?) {
            let key = "\(urlString)|\(requireImageMinPixels ?? 0)"
            if let hit = store[key], Date.now.timeIntervalSince(hit.at) < 600 {
                return (hit.ok, hit.note)
            }
            guard let url = URL(string: urlString), url.scheme == "https" else {
                return (false, "Invalid https:// URL: \(urlString)")
            }
            var req = URLRequest(url: url, timeoutInterval: 5)
            req.httpMethod = requireImageMinPixels == nil ? "HEAD" : "GET"
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                var status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 405 && req.httpMethod == "HEAD" {
                    var getReq = URLRequest(url: url, timeoutInterval: 5)
                    getReq.httpMethod = "GET"
                    let (_, getResp) = try await URLSession.shared.data(for: getReq)
                    status = (getResp as? HTTPURLResponse)?.statusCode ?? 0
                }
                guard (200..<300).contains(status) else {
                    let entry = Entry(ok: false, note: "URL returned HTTP \(status): \(urlString)", at: .now)
                    store[key] = entry
                    return (false, entry.note)
                }
                if let minPx = requireImageMinPixels {
                    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                          let w = props[kCGImagePropertyPixelWidth] as? Int,
                          let h = props[kCGImagePropertyPixelHeight] as? Int,
                          w >= minPx, h >= minPx else {
                        let entry = Entry(ok: false, note: "Icon must be at least \(minPx)x\(minPx) pixels: \(urlString)", at: .now)
                        store[key] = entry
                        return (false, entry.note)
                    }
                }
                let entry = Entry(ok: true, note: nil, at: .now)
                store[key] = entry
                return (true, nil)
            } catch {
                return (false, "Network check failed for \(urlString): \(error.localizedDescription)")
            }
        }
    }
}
