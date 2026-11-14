import Foundation
import HmunmawiCore

/// The list of accounts that don't follow you back, as your bot saves it: `{"non_followbacks": [{"handle", "suggestion"}]}`
/// (or a plain list of handles). Only entries without a "keep" suggestion are offered; your keep list always wins.
/// Hmunmawi only reminds you; it never unfollows anyone (automated actions on X can get an account limited).
enum UnfollowList {
    /// "safari": the list comes from your own Following page, read through your Safari login (no bot needed).
    static func fromSafari(_ r: MyRoutine) -> Bool { r.params?["source"] == "safari" }

    static func file(_ r: MyRoutine) -> URL {
        if let f = r.params?["file"], !f.isEmpty { return URL(fileURLWithPath: f) }
        return URL.hmSupport.appending(path: "unfollow-queue.json")
    }

    static func load(_ r: MyRoutine) -> [String]? {
        guard let d = try? Data(contentsOf: file(r)), let any = try? JSONSerialization.jsonObject(with: d) else { return nil }
        return parse(any)
    }

    static func parse(_ any: Any) -> [String] {
        let list: [Any] = (any as? [Any]) ?? ((any as? [String: Any])?["non_followbacks"] as? [Any]) ?? []
        return list.compactMap { e -> String? in
            if let h = e as? String { return XNative.validHandle(h) }
            guard let o = e as? [String: Any], let h = (o["handle"] as? String).flatMap(XNative.validHandle) else { return nil }
            let s = (o["suggestion"] as? String ?? "unfollow").lowercased()
            return s.contains("keep") ? nil : h
        }
    }

    /// Up to `count` handles not kept and not sent before, in list order.
    static func pick(_ all: [String], count: Int, keep: Set<String>, sent: Set<String>) -> [String] {
        var seen = Set<String>()
        return Array(all.filter { h in
            let k = h.lowercased()
            return !keep.contains(k) && !sent.contains(k) && seen.insert(k).inserted
        }.prefix(count))
    }

    /// The next `count` handles from `from`, skipping your keeps; returns them and where to start next time.
    static func batch(_ all: [String], from: Int, count: Int, keep: Set<String>) -> ([String], Int) {
        var out: [String] = [], i = max(from, 0)
        while i < all.count, out.count < count {
            if !keep.contains(all[i].lowercased()) { out.append(all[i]) }
            i += 1
        }
        return (out, i)
    }
}
