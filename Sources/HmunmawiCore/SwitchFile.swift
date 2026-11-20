import Foundation

/// A JSON file of on/off switches that your own scripts read, for example a private workspace's
/// `config/social_channels.json`. Hmunmawi shows each true/false value as a switch and, when you flip one, changes
/// only that value: every other key, the `_comment`, the order and the spacing stay byte-for-byte as they were.
/// The write is atomic (a temporary file renamed over the old one) and is checked before it replaces the file.
///
/// Conventions (all optional) that a workspace can use:
/// - Top-level `true`/`false` keys, and `true`/`false` keys one level down inside an object (`"warmed_up": {"reddit": true}`).
/// - Keys starting with `_` are notes, never switches. `"_help": {"key": "one line"}` and `"_labels": {"key": "Name"}`
///   override the text shown for a switch (nested keys as `"warmed_up.reddit"`).
/// - Well-known social keys (`reddit`, `discord`, `instagram`, `youtube_shorts`, `x`, `warmed_up.<platform>`, …) get a
///   plain name and explanation; missing ones show their default (channels on, warm-up done = off) and are added to
///   the file the first time you flip them.
public enum SwitchFile {
    // MARK: Model

    public struct Switch: Identifiable, Equatable, Sendable {
        public let path: [String]
        public var id: String { path.joined(separator: ".") }
        public let label: String
        public let help: String
        public let group: String
        /// The value in effect: the file's value, or the default when the file doesn't have the key.
        public let value: Bool
        /// False when the key isn't in the file (the switch shows its default).
        public let isSet: Bool
    }

    public struct Known: Sendable {
        public let path: [String]
        public let label: String
        public let help: String
        public let group: String
        public let defaultValue: Bool
        /// Shown even when the file lacks the key (as long as the file uses at least one well-known key).
        public let core: Bool
    }

    public static let channelsGroup = "Channels"
    public static let detailsGroup = "Instagram details"
    public static let xGroup = "X details"
    public static let warmupGroup = "Account warm-up"
    public static let otherGroup = "Other switches"
    public static let groupOrder = [channelsGroup, detailsGroup, xGroup, warmupGroup, otherGroup]

    /// Well-known keys for social jobs. Channels default to on, as the scripts treat a missing key as on.
    public static let catalog: [Known] = [
        Known(path: ["reddit"], label: "Reddit", help: "Reddit post ideas and comment drafts from your scripts.", group: channelsGroup, defaultValue: true, core: true),
        Known(path: ["discord"], label: "Discord", help: "Discord post ideas for the servers you've joined.", group: channelsGroup, defaultValue: true, core: true),
        Known(path: ["instagram"], label: "Instagram", help: "All Instagram work: Reels, carousels and posting reminders.", group: channelsGroup, defaultValue: true, core: true),
        Known(path: ["youtube_shorts"], label: "YouTube Shorts", help: "Shorts plans and uploads (an upload still waits for your yes).", group: channelsGroup, defaultValue: true, core: true),
        Known(path: ["x"], label: "X", help: "X post drafts, reply reminders and automatic unfollows (off stops them all; you still post by hand).", group: channelsGroup, defaultValue: true, core: true),
        Known(path: ["x_unfollows"], label: "X unfollows (automatic)", help: "Hmunmawi's automatic X unfollows, when you've added that routine. Off pauses them; your list and progress are kept.", group: xGroup, defaultValue: true, core: true),
        Known(path: ["instagram_drafts"], label: "Instagram post suggestions", help: "Instagram posts from your post bank go into the day's plan.", group: detailsGroup, defaultValue: true, core: false),
        Known(path: ["new_instagram_carousels"], label: "New Instagram carousels", help: "AI jobs write new carousels; ones already made are still suggested.", group: detailsGroup, defaultValue: true, core: false),
        Known(path: ["instagram_warmup"], label: "Instagram warm-up sessions", help: "Daily warm-up sessions for a new Instagram account.", group: detailsGroup, defaultValue: true, core: false),
        Known(path: ["warmed_up", "reddit"], label: "Reddit account warmed up", help: "On: no karma-building or warm-up comments, only real post ideas.", group: warmupGroup, defaultValue: false, core: true),
        Known(path: ["warmed_up", "discord"], label: "Discord account warmed up", help: "On: no join, rules, intro or warm-up reply steps; joined servers get post ideas.", group: warmupGroup, defaultValue: false, core: true),
        Known(path: ["warmed_up", "instagram"], label: "Instagram account warmed up", help: "On: no warm-up ladder or sessions, only real Reels and carousels.", group: warmupGroup, defaultValue: false, core: true),
    ]

    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case missing
        case unreadable(String)
        case notJSON(String)
        case notObject
        case notSwitch(String)
        case verifyFailed
        case writeFailed(String)

        public var description: String {
            switch self {
            case .missing: "The switch file isn't there."
            case .unreadable(let why): "Couldn't read the switch file: \(why)"
            case .notJSON(let why): "The switch file isn't valid JSON, so nothing was changed. \(why)"
            case .notObject: "The switch file must be a JSON object ({ … })."
            case .notSwitch(let key): "\"\(key)\" in the file isn't true or false, so Hmunmawi leaves it alone."
            case .verifyFailed: "The change didn't check out, so the file was left as it was."
            case .writeFailed(let why): "Couldn't save the switch file: \(why)"
            }
        }
    }

    public struct Loaded: Equatable, Sendable {
        public let url: URL
        public let switches: [Switch]
        public let comment: String?
    }

    // MARK: Finding the file

    /// Paths looked for inside your workspace folder (the owner settings' `hubRoot`), in this order.
    public static let conventionalNames = ["config/hmunmawi-switches.json", "config/social_channels.json"]

    /// Where the switch file is: the one you chose in Settings, else owner settings' `switchFile`, else the first
    /// conventional name that exists in your workspace. A chosen or configured file is returned even when missing,
    /// so the section can say so; nil means there's nothing to show.
    public static func locate(chosen: String?, owner: OwnerConfig = .current, fileManager: FileManager = .default) -> URL? {
        if let c = chosen?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
            return URL(fileURLWithPath: (c as NSString).expandingTildeInPath)
        }
        if let configured = owner.switchFileURL { return configured }
        guard let hub = owner.hubURL else { return nil }
        return conventionalNames.map { hub.appending(path: $0) }.first { fileManager.fileExists(atPath: $0.path) }
    }

    // MARK: Reading

    public static func load(_ url: URL) -> Result<Loaded, Problem> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .failure(.unreadable(error.localizedDescription)) }
        return parse(data).map { obj in
            Loaded(url: url, switches: switches(in: obj), comment: obj["_comment"] as? String)
        }
    }

    public static func parse(_ data: Data) -> Result<[String: Any], Problem> {
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
            return .failure(.notJSON((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? ""))
        }
        guard let obj = any as? [String: Any] else { return .failure(.notObject) }
        return .success(obj)
    }

    static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    static func value(at path: [String], in obj: [String: Any]) -> Any? {
        var cur: Any? = obj
        for k in path { cur = (cur as? [String: Any])?[k] }
        return cur
    }

    /// Every switch to show: well-known keys (core ones even when missing, if the file uses any well-known key), then
    /// any other true/false value at the top level or one level down.
    public static func switches(in obj: [String: Any]) -> [Switch] {
        let help = obj["_help"] as? [String: Any] ?? [:]
        let labels = obj["_labels"] as? [String: Any] ?? [:]
        let usesCatalog = catalog.contains { value(at: $0.path, in: obj) != nil }
        var out: [Switch] = []
        var seen = Set<String>()
        for k in catalog {
            let id = k.path.joined(separator: ".")
            let raw = value(at: k.path, in: obj)
            if raw != nil, bool(raw) == nil { seen.insert(id); continue }   // not a true/false: leave it alone
            if raw == nil && !(usesCatalog && k.core) { continue }
            // A missing nested key under a non-object parent can't be written; skip it.
            if raw == nil, k.path.count > 1, let parent = obj[k.path[0]], !(parent is [String: Any]) { continue }
            seen.insert(id)
            out.append(Switch(path: k.path, label: labels[id] as? String ?? k.label, help: help[id] as? String ?? k.help,
                              group: k.group, value: bool(raw) ?? k.defaultValue, isSet: raw != nil))
        }
        for key in obj.keys.sorted() where !key.hasPrefix("_") {
            if let b = bool(obj[key]), !seen.contains(key) {
                out.append(Switch(path: [key], label: labels[key] as? String ?? humanize(key),
                                  help: help[key] as? String ?? "From your switch file.", group: otherGroup, value: b, isSet: true))
            } else if let sub = obj[key] as? [String: Any] {
                for sk in sub.keys.sorted() where !sk.hasPrefix("_") {
                    let id = "\(key).\(sk)"
                    guard let b = bool(sub[sk]), !seen.contains(id) else { continue }
                    out.append(Switch(path: [key, sk], label: labels[id] as? String ?? "\(humanize(key)): \(humanize(sk))",
                                      help: help[id] as? String ?? "From your switch file.", group: otherGroup, value: b, isSet: true))
                }
            }
        }
        return out
    }

    public static func humanize(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: Writing

    /// Sets one switch and saves the file atomically. Returns the file as read back afterwards.
    @discardableResult
    public static func set(_ path: [String], to value: Bool, in url: URL) -> Result<Loaded, Problem> {
        let target = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return .failure(.missing) }
        let data: Data
        do { data = try Data(contentsOf: target) } catch { return .failure(.unreadable(error.localizedDescription)) }
        switch edited(data, path: path, value: value) {
        case .failure(let p): return .failure(p)
        case .success(let new):
            if new != data {
                do { try writeAtomically(new, to: target) } catch { return .failure(.writeFailed(error.localizedDescription)) }
            }
            return load(url)
        }
    }

    /// The file's bytes with one switch set: an existing value is replaced in place; a missing key is added at the
    /// end of its object. Fails, changing nothing, if the file isn't a JSON object, the key holds something other
    /// than true/false, or the result doesn't equal the old document with only that value changed.
    public static func edited(_ data: Data, path: [String], value: Bool) -> Result<Data, Problem> {
        guard !path.isEmpty, path.count <= 2, !path.contains(where: { $0.isEmpty || $0.hasPrefix("_") }) else {
            return .failure(.notSwitch(path.joined(separator: ".")))
        }
        let old: [String: Any]
        switch parse(data) { case .success(let o): old = o; case .failure(let p): return .failure(p) }
        let id = path.joined(separator: ".")
        if let raw = Self.value(at: path, in: old), bool(raw) == nil { return .failure(.notSwitch(id)) }
        if path.count == 2, let parent = old[path[0]], !(parent is [String: Any]) { return .failure(.notSwitch(path[0])) }

        var bytes = [UInt8](data)
        let literal = Array((value ? "true" : "false").utf8)
        var scanner = Scanner(bytes)
        guard let root = try? scanner.document() else { return .failure(.notJSON("")) }
        if let member = root.member(path[0]) {
            if path.count == 1 {
                bytes.replaceSubrange(member.value, with: literal)
            } else if let obj = member.object {
                if let inner = obj.member(path[1]) {
                    bytes.replaceSubrange(inner.value, with: literal)
                } else {
                    insert(&bytes, into: obj, key: path[1], valueText: literal)
                }
            } else {
                return .failure(.notSwitch(path[0]))
            }
        } else if path.count == 1 {
            insert(&bytes, into: root, key: path[0], valueText: literal)
        } else {
            insert(&bytes, into: root, key: path[0], valueText: Array("{".utf8) + encodeKey(path[1]) + Array(": ".utf8) + literal + Array("}".utf8))
        }

        // Check: the new document equals the old one with only this value changed.
        guard case .success(let new) = parse(Data(bytes)) else { return .failure(.verifyFailed) }
        var expected = old
        if path.count == 1 {
            expected[path[0]] = NSNumber(value: value)
        } else {
            var sub = old[path[0]] as? [String: Any] ?? [:]
            sub[path[1]] = NSNumber(value: value)
            expected[path[0]] = sub
        }
        guard NSDictionary(dictionary: expected).isEqual(to: new), bool(Self.value(at: path, in: new)) == value else {
            return .failure(.verifyFailed)
        }
        return .success(Data(bytes))
    }

    /// Writes next to the file, then renames over it (readers see the old or the new file, never half of one).
    /// Keeps the file's permissions.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let perms = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try data.write(to: url, options: .atomic)
        if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
    }

    // MARK: Byte-level JSON spans

    private static func encodeKey(_ k: String) -> [UInt8] {
        let d = (try? JSONSerialization.data(withJSONObject: [k], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return Array(d.dropFirst().dropLast())   // strip [ ]
    }

    private static func insert(_ bytes: inout [UInt8], into obj: ObjectSpan, key: String, valueText: [UInt8]) {
        var text: [UInt8] = []
        if let last = obj.members.last, let first = obj.members.first {
            // Same separator as before the first member (e.g. "\n  "), after a comma.
            let sep = Array(bytes[(obj.open + 1)..<first.keyStart])
            text = Array(",".utf8) + sep + encodeKey(key) + Array(": ".utf8) + valueText
            bytes.insert(contentsOf: text, at: last.value.upperBound)
        } else {
            text = encodeKey(key) + Array(": ".utf8) + valueText
            bytes.insert(contentsOf: text, at: obj.open + 1)
        }
    }

    struct Member {
        let key: String
        let keyStart: Int
        let value: Range<Int>
        let object: ObjectSpan?
    }

    final class ObjectSpan {
        let open: Int
        var close = 0
        var members: [Member] = []
        init(open: Int) { self.open = open }
        /// The last member with this key (JSON parsers keep the last duplicate).
        func member(_ key: String) -> Member? { members.last { $0.key == key } }
    }

    struct ScanError: Error {}

    /// A minimal JSON scanner that records where each object member's value sits in the bytes.
    struct Scanner {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) {
            self.b = b
            if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        }

        mutating func document() throws -> ObjectSpan {
            skip()
            guard i < b.count, b[i] == UInt8(ascii: "{") else { throw ScanError() }
            let o = try object()
            skip()
            guard i == b.count else { throw ScanError() }
            return o
        }

        mutating func skip() { while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 } }

        mutating func object() throws -> ObjectSpan {
            let o = ObjectSpan(open: i)
            i += 1
            skip()
            if i < b.count, b[i] == UInt8(ascii: "}") { o.close = i; i += 1; return o }
            while true {
                skip()
                let keyStart = i
                let key = try string()
                skip()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw ScanError() }
                i += 1
                skip()
                let start = i
                let child = try value()
                o.members.append(Member(key: key, keyStart: keyStart, value: start..<i, object: child))
                skip()
                guard i < b.count else { throw ScanError() }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { o.close = i; i += 1; return o }
                throw ScanError()
            }
        }

        /// Skips one value; returns its span if it is an object.
        mutating func value() throws -> ObjectSpan? {
            guard i < b.count else { throw ScanError() }
            switch b[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["):
                i += 1
                skip()
                if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return nil }
                while true {
                    skip()
                    _ = try value()
                    skip()
                    guard i < b.count else { throw ScanError() }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "]") { i += 1; return nil }
                    throw ScanError()
                }
            case UInt8(ascii: "\""): _ = try string(); return nil
            default:
                let start = i
                while i < b.count, !([0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(b[i])) { i += 1 }
                guard i > start else { throw ScanError() }
                return nil
            }
        }

        mutating func string() throws -> String {
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw ScanError() }
            let start = i
            i += 1
            while i < b.count, b[i] != UInt8(ascii: "\"") {
                if b[i] == UInt8(ascii: "\\") { i += 1 }
                i += 1
            }
            guard i < b.count else { throw ScanError() }
            i += 1
            let raw = Data(b[start..<i])
            guard let s = (try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])) as? String else { throw ScanError() }
            return s
        }
    }
}
