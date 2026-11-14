import Foundation
import HmunmawiCore

/// The post-draft rules on this Mac (x-rules.json in the app's data folder), kept in step with X's published ranking
/// code: at most once a week the post-drafts routine asks GitHub whether xai-org/x-algorithm changed; only then it
/// reads X's ranking weights and recomputes the rules (XAlgorithm, fixed formulas, no AI). The previous rules are kept
/// as x-rules.prev.json; delete x-rules.json to go back to the built-in rules.
enum XRules {
    static var file: URL { URL.hmSupport.appending(path: "x-rules.json") }
    static var prevFile: URL { URL.hmSupport.appending(path: "x-rules.prev.json") }
    static let shaKey = "HMXAlgoSHA", checkedKey = "HMXAlgoChecked"

    static var current: PostRules {
        guard let d = try? Data(contentsOf: file), let r = try? JSONDecoder().decode(PostRules.self, from: d) else { return PostRules() }
        return r.clamped()
    }

    /// Checks X's code if a week has passed. Returns a line for the routine's note when the rules changed, else nil.
    static func checkIfDue(now: Date = .now) async -> String? {
        let d = UserDefaults.standard
        if let last = d.object(forKey: checkedKey) as? Date, now.timeIntervalSince(last) < 7 * 86400 { return nil }
        d.set(now, forKey: checkedKey)
        guard let sha = await latestCommit() else { return nil }
        guard sha != d.string(forKey: shaKey) else { return nil }
        guard let url = URL(string: "https://raw.githubusercontent.com/\(XAlgorithm.repo)/\(sha)/\(XAlgorithm.paramsPath)"),
              let (data, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let old = current
        guard let new = XAlgorithm.rules(from: XAlgorithm.parseParams(text), commit: sha, day: now.localDay, base: old) else {
            d.set(sha, forKey: shaKey); return "X's ranking code changed, but its weights moved; the post rules stay as they are."
        }
        d.set(sha, forKey: shaKey)
        let same = (old.question, old.numbersEach, old.lessonWords, old.longPost) == (new.question, new.numbersEach, new.lessonWords, new.longPost)
        guard !same else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let prev = try? JSONEncoder().encode(old) { try? prev.write(to: prevFile) }
        if let enc = try? JSONEncoder().encode(new) { try? enc.write(to: file) }
        func f(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) }
        return "X changed its ranking, so post drafts were re-ranked: questions \(f(old.question))→\(f(new.question)), "
            + "numbers \(f(old.numbersEach))→\(f(new.numbersEach)), shareable how-tos \(f(old.lessonWords))→\(f(new.lessonWords)), "
            + "longer reads \(f(old.longPost))→\(f(new.longPost)). (\(new.source))"
    }

    private static func latestCommit() async -> String? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(XAlgorithm.repo)/commits?per_page=1")!, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]], let sha = arr.first?["sha"] as? String,
              sha.allSatisfy(\.isHexDigit), sha.count == 40 else { return nil }
        return sha
    }
}
