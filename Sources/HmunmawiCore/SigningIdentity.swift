import Foundation
import Security

/// Which certificate signed this copy of the app. macOS ties each privacy grant (Files and Folders, Full Disk Access,
/// Calendar, Accessibility, Automation) and each Keychain item's access list to that signature, so moving between a
/// development build, the release build or a new certificate means grants made earlier no longer match.
public enum SigningIdentity {
    /// "<certificate name> (<team id>)" of the running app, or nil when unsigned or ad-hoc signed.
    public static func current() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        var name: CFString?
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            SecCertificateCopyCommonName(leaf, &name)
        }
        let n = (name as String?) ?? ""
        if n.isEmpty && team == nil { return nil }
        return "\(n)\(team.map { " (\($0))" } ?? "")".trimmingCharacters(in: .whitespaces)
    }

    /// The permissions to switch on again after the signature changed, exactly as System Settings names them.
    public static let regrantList: [String] = [
        "System Settings → Privacy & Security → Full Disk Access → Hmunmawi",
        "System Settings → Privacy & Security → Files & Folders → Hmunmawi (Documents, Desktop, Downloads)",
        "System Settings → Privacy & Security → Calendars → Hmunmawi",
        "System Settings → Privacy & Security → Accessibility → Hmunmawi",
        "System Settings → Privacy & Security → Automation → Hmunmawi (Messages, Safari, Calendar)",
    ]

    /// What to tell the person when the signature differs from the last launch; nil when it is the same or first run.
    public static func changeNote(previous: String?, current: String?) -> String? {
        guard let previous, !previous.isEmpty, let current, !current.isEmpty, previous != current else { return nil }
        return "Hmunmawi is now signed as \(current) (before: \(previous)). Saved keys carry over by themselves, but macOS asks again for each privacy permission. Switch these on again if a connection or routine says it can't reach something:\n"
            + regrantList.map { "• " + $0 }.joined(separator: "\n")
    }
}
