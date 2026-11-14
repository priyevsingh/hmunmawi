import Foundation

/// Where a conversation stands after their latest message, and whose move it is. Rules decide the clear cases (a
/// question or request is always your move); anything they can't place is `unclear`, for an on-device model or you.
/// Every result is only a suggestion: you tap to accept it.
public enum ThreadState: String, Codable, Sendable, CaseIterable {
    case yourTurn = "your turn"      // they asked something or asked for something
    case promised                    // they'll do something later (test it, consider it, cover it, get back)
    case scheduled                   // a date for coverage, an interview or a call
    case referred = "passed on"      // they pointed you to someone else
    case declined                    // not a fit / not now
    case thanks = "done"             // only thanks: nothing to do
    case unclear

    /// The kind of promise, which sets how long to wait: testing gets one check-in, coverage gets watched quietly.
    public enum Promise: String, Codable, Sendable { case testing, coverage, getBack = "get back" }

    public struct Reading: Sendable, Equatable {
        public var state: ThreadState
        public var promise: Promise?
        public var evidence: String
    }

    /// Senders that never write a personal reply (newsletters, mailers, no-reply robots).
    public static func isRobot(_ from: String) -> Bool {
        let local = from.lowercased().split(separator: "@").first.map(String.init) ?? ""
        return ["noreply", "no-reply", "donotreply", "do-not-reply", "mailer", "newsletter", "news", "notifications",
                "notification", "updates", "digest", "bounce", "mailer-daemon", "postmaster"].contains { local == $0 || local.hasPrefix($0 + "-") || local.hasPrefix($0 + "+") }
    }

    public static func read(_ text: String) -> Reading {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = " " + t.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        func first(_ words: [String]) -> String? { words.first { s.contains($0) } }
        func quote(_ word: String) -> String {
            // The sentence that holds the word, as evidence.
            let sentences = t.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).map { $0.trimmingCharacters(in: .whitespaces) }
            return sentences.first { $0.lowercased().contains(word.trimmingCharacters(in: .whitespaces)) }.map { String($0.prefix(160)) } ?? String(t.prefix(160))
        }
        // 1. A question or a request: your move, whatever else it says.
        let asks = [" could you", " can you", " would you", " please send", " send me", " send over", " do you have", " are you able",
                    " let me know", " can i get", " could i get", " is there a ", " what is ", " when does", " when will", " how does", " how do "]
        if let q = t.split(separator: "\n").first(where: { $0.contains("?") }) {
            return Reading(state: .yourTurn, promise: nil, evidence: String(q.prefix(160)))
        }
        if let w = first(asks) { return Reading(state: .yourTurn, promise: nil, evidence: quote(w)) }
        // 2. No.
        let no = [" not a fit", " not interested", " no thanks", " no, thank", " pass on", " not right now", " not at this time",
                  " unfortunately", " we don't cover", " we do not cover", " won't be able", " can't feature", " cannot feature", " decline"]
        if let w = first(no) { return Reading(state: .declined, promise: nil, evidence: quote(w)) }
        // 3. Someone else.
        let other = [" not the right person", " reach out to ", " contact our ", " try reaching", " forwarded this", " forwarding this",
                     " cc'ing", " cc’ing", " copying in", " looping in"]
        if let w = first(other) { return Reading(state: .referred, promise: nil, evidence: quote(w)) }
        // 4. A date.
        let when = #"\b(mon|tue|wed|thu|fri|sat|sun)(day|sday|nesday|rsday|urday)?\b|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.? \d{1,2}\b|\b\d{1,2} (jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|\bnext week\b|\btomorrow\b|\bthis week\b"#
        let doing = [" feature", " publish", " air", " record", " episode", " post it", " run it", " review it", " interview"]
        if s.range(of: when, options: .regularExpression) != nil, let w = first(doing) {
            return Reading(state: .scheduled, promise: .coverage, evidence: quote(w))
        }
        // 5. A promise, and which kind.
        let coverage = [" future episode", " an episode", " on the show", " will cover", " we'll cover", " will feature", " we'll feature",
                        " will mention", " write about", " write it up", " include it", " inclusion", " roundup", " round-up"]
        let testing = [" test it", " testing it", " try it", " give it a try", " give it a spin", " download", " check it out",
                       " checking it out", " take a look", " look at it", " play with it", " consider"]
        let back = [" get back to you", " i'll get back", " we'll get back", " keep you posted", " circle back", " follow up with you", " will let you know"]
        if let w = first(coverage) { return Reading(state: .promised, promise: .coverage, evidence: quote(w)) }
        if let w = first(testing) { return Reading(state: .promised, promise: .testing, evidence: quote(w)) }
        if let w = first(back) { return Reading(state: .promised, promise: .getBack, evidence: quote(w)) }
        // 6. Only thanks.
        let thanks = [" thank", " thanks", " appreciate", " cheers", " great", " awesome", " got it", " received"]
        if let w = first(thanks), t.count < 400 { return Reading(state: .thanks, promise: nil, evidence: quote(w)) }
        return Reading(state: .unclear, promise: nil, evidence: String(t.prefix(160)))
    }

    /// The thread's state after a new message: thanks after a promise keeps the promise (they still owe the next step).
    public static func next(after current: ThreadState?, currentPromise: Promise?, reading: Reading) -> (ThreadState, Promise?) {
        if reading.state == .thanks, current == .promised || current == .scheduled { return (current!, currentPromise) }
        // A testing promise that turns into a coverage promise keeps the stronger one.
        if reading.state == .promised, current == .promised, currentPromise == .coverage, reading.promise != .coverage { return (.promised, .coverage) }
        return (reading.state, reading.promise)
    }

    /// When to look again, from the day the state began (nil = nothing to wait for).
    public static func checkBack(_ state: ThreadState, promise: Promise?) -> Int? {
        switch state {
        case .yourTurn: 2                                       // a reminder to answer
        case .promised: promise == .coverage ? 90 : 14          // coverage: watched quietly; testing / get back: one check-in
        case .scheduled: nil
        case .referred, .declined, .thanks, .unclear: nil
        }
    }
}
