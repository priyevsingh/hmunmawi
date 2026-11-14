import Foundation

/// Only one Hmunmawi runs at a time. A new launch hands over to one already running with the same bundle id
/// (wherever its copy lives on disk) and quits. A copy with another Hmunmawi bundle id (a test copy such as
/// `….freshtest`) also yields to a running Hmunmawi, unless it is a test profile that explicitly asks to run
/// beside it (`HMUNMAWI_ALLOW_SECOND_INSTANCE=1`, set by scripts/fresh-copy.sh). The real app never yields to a
/// test copy, so a test copy can never keep the real one from starting.
public enum SingleInstance {
    public static let family = "io.github.priyevsingh.Hmunmawi"
    public static let overrideKey = "HMUNMAWI_ALLOW_SECOND_INSTANCE"

    public struct Running: Sendable, Equatable {
        public let pid: Int32
        public let bundleID: String
        public init(pid: Int32, bundleID: String) { self.pid = pid; self.bundleID = bundleID }
    }

    static func isFamily(_ id: String) -> Bool { id == family || id.hasPrefix(family + ".") && !id.hasPrefix(family + ".keys") }

    /// The running copy to hand over to, or nil to carry on starting.
    public static func handOverTo(myPID: Int32, myBundleID: String, running: [Running], testProfile: Bool,
                                  overrideAsked: Bool) -> Running? {
        let others = running.filter { $0.pid != myPID }
        if testProfile && overrideAsked { return nil }
        if let same = others.first(where: { $0.bundleID == myBundleID }) { return same }
        // A test copy (other bundle id in the family) steps aside for the real app or any other copy.
        guard myBundleID != family, isFamily(myBundleID) else { return nil }
        return others.first { isFamily($0.bundleID) }
    }
}
