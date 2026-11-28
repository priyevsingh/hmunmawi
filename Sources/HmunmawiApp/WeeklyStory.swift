import AppKit
import HmunmawiCore
import SwiftUI

/// Weekly story: the week in one short, shareable read: money, people, wins, worries, what shipped and what's
/// next. Built from the app's own data; "Sort it for me: Polish" asks the AI for a friendlier version. The story is
/// read-only text here; Copy puts it on the clipboard. Nothing is posted anywhere.
@MainActor enum WeeklyStory {
    static func facts(_ model: AppModel) -> [String] {
        let money = Money.shared
        let weekAgo = Millis(Date.now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970 * 1000)
        let week = model.events.filter { $0.occurredAt > weekAgo }
        var out: [String] = []
        let sales = week.filter { ["revenue.purchase", "revenue.renewal"].contains($0.kind) }
        let earned = sales.compactMap { money.amount($0) }.reduce(0, +)
        if !sales.isEmpty { out.append("\(sales.count) sale\(sales.count == 1 ? "" : "s") and renewals, about \(money.format(earned, from: money.target, decimals: 0)) in prices paid, before Apple's cut") }
        let cancels = week.filter { $0.kind == "revenue.cancelled" }.count
        if cancels > 0 { out.append("\(cancels) cancellation\(cancels == 1 ? "" : "s")") }
        let reviews = week.filter { $0.kind == "review.new" }
        if !reviews.isEmpty {
            let avg = reviews.compactMap { $0.payload[path: "rating"]?.number }.reduce(0, +) / Double(max(1, reviews.count))
            out.append("\(reviews.count) new review\(reviews.count == 1 ? "" : "s"), averaging \(String(format: "%.1f", avg))★")
        }
        for f in model.findings.prefix(4) {
            // A source's pseudo-app ("All channels", "All apps") isn't a name worth printing.
            let app = f.app.flatMap { $0.lowercased().hasPrefix("all ") ? nil : $0 }
            out.append((f.lane == .win ? "Win: " : f.lane == .worry ? "Worry: " : "") + (app.map { "\($0): " } ?? "") + StoryCards.headline(f))
        }
        for r in ComingSoon.releases(model) where !r.parked { out.append("\(r.app) \(r.version ?? ""): \(r.status.prefix(1).lowercased() + r.status.dropFirst())") }
        let tf = week.filter { $0.kind == "testflight.feedback" }.count
        if tf > 0 { out.append("\(tf) TestFlight feedback item\(tf == 1 ? "" : "s")") }
        return out
    }

    static func plain(_ model: AppModel) -> String {
        let f = facts(model)
        let day = Date.now.formatted(.dateTime.day().month(.wide))
        return (["My week in apps (to \(day))"] + (f.isEmpty ? ["A quiet week: building more than shipping."] : f.map { "• " + $0 }))
            .joined(separator: "\n")
    }
}

struct WeeklyStoryCard: View {
    let model: AppModel
    @State private var text = ""
    @State private var generated = ""
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        KitCard {
            HStack {
                CardHeader(symbol: "newspaper.fill", title: "Your week, in a story", tint: Brand.Category.web,
                           caption: Calendar.current.component(.weekday, from: .now) == 1 ? "It's Sunday: story time" : "Ready any day; best on Sundays")
                Button { Task { await polish() } } label: { Label(busy ? "Sort it for me: Writing" : "Sort it for me: Polish", systemImage: "sparkles") }
                    .buttonStyle(.pill).disabled(busy)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); note = "Copied. Paste it wherever you like." } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.pill)
            }
            // Read-only: the story is built from your data (or the AI's polish of it). Copy it to share or edit
            // elsewhere. It used to be an unstyled TextField, which made the story look like editable page text.
            Text(text.isEmpty ? " " : text).font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
                .accessibilityLabel("Weekly story")
                .accessibilityValue(text)
            if text != generated, !generated.isEmpty {
                Button { text = generated; note = nil } label: { Label("Show the plain facts again", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).font(.caption)
            }
            if let note { Text(note).font(.caption).foregroundStyle(note.hasPrefix("Couldn") ? Brand.bad : .secondary) }
        }
        // Keep the plain story in step with new data until you polish it.
        .task(id: "\(model.events.count)|\(model.findings.count)|\(ComingSoon.releases(model).count)") {
            if text.isEmpty || text == generated { generated = WeeklyStory.plain(model); text = generated }
        }
    }

    private func polish() async {
        busy = true; defer { busy = false }
        do {
            let drafted = try await AIWriter.draft(WeeklyStory.polishPrompt(facts: WeeklyStory.facts(model)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = Wording.rules.problem(drafted) {
                note = "Couldn't polish it: AI draft \(problem)."
                return
            }
            text = drafted
            note = "Polished. Copy it to share."
        } catch { note = "Couldn't polish it: " + ((error as? WireError)?.message ?? "\(error)") }
    }
}

extension WeeklyStory {
    static func polishPrompt(facts: [String]) -> String {
        """
        Turn these weekly facts from a solo indie iOS developer into a short, friendly build-in-public update (under 900 \
        characters). Keep every number and app name exact; no hype, no hashtags, at most one emoji. Never mention the \
        developer's city, state, country, or location. Facts:
        \(facts.joined(separator: "\n"))
        """
    }

    /// Used by Sunday's `story.weekly` digest when opted in; returns nil if AI is off, fails, or hits Words I never use.
    static func polishDigest(facts: [String]) async -> String? {
        guard !facts.isEmpty, let drafted = try? await AIWriter.draft(polishPrompt(facts: facts)) else { return nil }
        let clean = String(drafted.trimmingCharacters(in: .whitespacesAndNewlines).prefix(900))
        guard !clean.isEmpty, Wording.rules.problem(clean) == nil else { return nil }
        return clean
    }
}
