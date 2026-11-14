// Developer helper for your own Mac: every fresh build of Hmunmawi is a "new" app to macOS, so it asks again for
// the permissions you already gave. This presses Allow on those prompts for you after a rebuild. It only touches
// prompts whose text names Hmunmawi; never password or Keychain prompts, never other apps. Needs Accessibility
// permission for the Terminal you run it from. macOS sometimes ignores the first press, so it tries up to 4 times.
// Run:  swift scripts/uitest/allow-prompts.swift      Exit 0 = none left, 1 = one still waiting.
import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func text(_ e: AXUIElement, _ d: Int = 0) -> String {
    guard d < 8 else { return "" }
    var s = (attr(e, kAXValueAttribute) as? String).map { $0 + " " } ?? ""
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { s += text(c, d + 1) }
    return s
}
func allowButton(_ e: AXUIElement, _ d: Int = 0) -> AXUIElement? {
    guard d < 8 else { return nil }
    if (attr(e, kAXRoleAttribute) as? String) == "AXButton", (attr(e, kAXTitleAttribute) as? String) == "Allow" { return e }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let b = allowButton(c, d + 1) { return b } }
    return nil
}
/// Hmunmawi's prompts that are waiting now: (description, Allow button).
func waiting() -> [(String, AXUIElement)] {
    var out: [(String, AXUIElement)] = []
    for app in NSWorkspace.shared.runningApplications where ["com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent"].contains(app.bundleIdentifier ?? "") {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        for w in (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            let t = text(w)
            guard t.contains("Hmunmawi"), let b = allowButton(w) else { continue }
            out.append((t.trimmingCharacters(in: .whitespaces), b))
        }
    }
    return out
}

for attempt in 1...4 {
    let now = waiting()
    if now.isEmpty { print(attempt == 1 ? "No prompt waiting." : "Allowed."); exit(0) }
    for (t, b) in now { print("Allow (try \(attempt)): \(t.prefix(90))"); _ = AXUIElementPerformAction(b, kAXPressAction as CFString) }
    Thread.sleep(forTimeInterval: 1.5)
}
let left = waiting()
if left.isEmpty { print("Allowed."); exit(0) }
print("Still waiting for the owner: \(left.map { $0.0.prefix(90) }.joined(separator: "; "))"); exit(1)
