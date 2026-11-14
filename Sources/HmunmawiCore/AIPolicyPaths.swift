import Foundation

/// Where the shared AI pause policy file lives: the owner's job-data folder (owner.json `jobsData`) when their own
/// policy script is used, else Hmunmawi's folder.
public enum AIPolicyPaths {
    /// The owner's hub copy of ai_policy.py (owner Macs only; see OwnerConfig).
    public static var hubScript: URL? { OwnerConfig.current.hubURL?.appending(path: "scripts/ai_policy.py", directoryHint: .notDirectory) }

    public static var usesHubAdapter: Bool { hubScript.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false }

    public static var policyFile: URL {
        if usesHubAdapter, let dir = OwnerConfig.current.jobsDataURL {
            return dir.appending(path: "ai_policy.json", directoryHint: .notDirectory)
        }
        return URL.applicationSupportDirectory.appending(path: "Hmunmawi/ai_policy.json", directoryHint: .notDirectory)
    }
}
