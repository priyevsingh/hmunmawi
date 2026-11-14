// UI test driver for Hmunmawi through the macOS Accessibility API (the same API VoiceOver uses).
// Build:  swiftc -O scripts/uitest/ax.swift -o build/ax
// Use:    build/ax list            prints every button and static text in Hmunmawi's windows
//         build/ax press "Allow"   presses the first enabled button with that title (or help/description)
//         build/ax menubar         opens Hmunmawi's menu bar panel; build/ax windows lists its window numbers
//         HM_AX_BUNDLE=<bundle id> points it at another copy (scripts/fresh-copy.sh uses ….freshtest)
// Needs Accessibility permission for the process that runs it.
import AppKit
import ApplicationServices

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) ?? []
}

func label(_ element: AXUIElement) -> String {
    let parts: [String?] = [attribute(element, kAXTitleAttribute), attribute(element, kAXDescriptionAttribute),
                            attribute(element, kAXValueAttribute) as String?, attribute(element, kAXHelpAttribute)]
    return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
}

func walk(_ element: AXUIElement, depth: Int = 0, visit: (AXUIElement, String, Int) -> Bool) -> Bool {
    let role: String = attribute(element, kAXRoleAttribute) ?? ""
    if visit(element, role, depth) { return true }
    guard depth < 40 else { return false }
    for child in children(element) where walk(child, depth: depth + 1, visit: visit) { return true }
    return false
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("This process needs Accessibility permission.\n".utf8))
    exit(2)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: ProcessInfo.processInfo.environment["HM_AX_BUNDLE"] ?? "io.github.priyevsingh.Hmunmawi").first else {
    FileHandle.standardError.write(Data("Hmunmawi is not running.\n".utf8))
    exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
let windows: [AXUIElement] = attribute(root, kAXWindowsAttribute) ?? []
let args = CommandLine.arguments.dropFirst()

switch args.first {
case "menubar":
    // ax menubar  — clicks Hmunmawi's own menu bar icon (its status item), opening its panel.
    guard let bar: AXUIElement = attribute(root, "AXExtrasMenuBar") else { print("no menu bar icon"); exit(1) }
    guard let item = children(bar).first else { print("no menu bar icon"); exit(1) }
    print(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? "opened" : "press failed")
case "windows":
    // ax windows  — window number, size and title of each on-screen Hmunmawi window (for screencapture -l).
    let info = (CGWindowListCopyWindowInfo(ProcessInfo.processInfo.environment["HM_AX_ALL"] == nil ? [.optionOnScreenOnly] : [.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in info where (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier {
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        print("\(w[kCGWindowNumber as String] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0) layer=\(w[kCGWindowLayer as String] ?? 0) \(w[kCGWindowName as String] ?? "")")
    }
case "list":
    for window in windows {
        _ = walk(window) { element, role, depth in
            if [kAXButtonRole, kAXStaticTextRole, kAXRadioButtonRole, kAXCheckBoxRole].contains(role) {
                let text = label(element)
                if !text.isEmpty { print(String(repeating: "  ", count: min(depth, 12)) + "[\(role.replacingOccurrences(of: "AX", with: ""))] \(text)") }
            }
            return false
        }
    }
case "disclose":
    // ax disclose [nth]  — presses the nth disclosure triangle (a SwiftUI DisclosureGroup) in Hmunmawi's windows.
    let nth = Int(args.dropFirst().first ?? "1").map { $0 - 1 } ?? 0
    var found: [AXUIElement] = []
    for window in windows { _ = walk(window) { element, role, _ in if role == "AXDisclosureTriangle" { found.append(element) }; return false } }
    guard nth < found.count else { print("no disclosure triangle \(nth + 1) (\(found.count) found)"); exit(1) }
    print(AXUIElementPerformAction(found[nth], kAXPressAction as CFString) == .success ? "opened \(nth + 1) of \(found.count)" : "press failed")
case "press":
    guard let title = args.dropFirst().first else { print("usage: ax press <title> [nth]"); exit(2) }
    let skip = Int(args.dropFirst(2).first ?? "1").map { $0 - 1 } ?? 0
    var pressed = false
    // Exact title first ("Today" must not hit "Today's story"), then a partial match.
    for exact in [true, false] where !pressed {
        var left = skip
        for window in windows where !pressed {
            pressed = walk(window) { element, role, _ in
                let text = label(element)
                let names = text.components(separatedBy: " | ")
                guard [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole].contains(role),
                      exact ? names.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) : text.localizedCaseInsensitiveContains(title),
                      (attribute(element, kAXEnabledAttribute) as Bool?) ?? true else { return false }
                if left > 0 { left -= 1; return false }
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
        }
    }
    print(pressed ? "pressed \(title)" : "no enabled button titled \(title)")
    exit(pressed ? 0 : 1)
case "fill":
    // ax fill "<field label>" < file   — focuses the text field with that label and types the file's text
    // (keystrokes, so the app's own field and Save path are used; the text is never printed).
    guard let title = args.dropFirst().first else { print("usage: ax fill <label> < valuefile"); exit(2) }
    let value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    var field: AXUIElement?
    for window in windows where field == nil {
        _ = walk(window) { element, role, _ in
            guard role == kAXTextFieldRole || role == "AXSecureTextField" else { return false }
            let text = [attribute(element, kAXTitleAttribute) as String?, attribute(element, kAXDescriptionAttribute) as String?,
                        attribute(element, "AXPlaceholderValue") as String?].compactMap { $0 }.joined(separator: " ")
            guard text.localizedCaseInsensitiveContains(title) else { return false }
            field = element
            return true
        }
    }
    guard let field else { print("no field labelled \(title)"); exit(1) }
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(300_000)
    let src = CGEventSource(stateID: .hidSystemState)
    for chunk in stride(from: 0, to: value.utf16.count, by: 16) {
        let units = Array(value.utf16)[chunk..<min(chunk + 16, value.utf16.count)]
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
            e?.flags = []
            units.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            e?.post(tap: .cghidEventTap)
        }
        usleep(8_000)
    }
    print("filled \(title) (\(value.count) characters)")
case "scroll-to":
    // ax scroll-to "<static text>"  — scrolls Hmunmawi's main scroll view so that text is near the top (AX only:
    // sets the vertical scroll bar value; no clicks or key events). Used to screenshot cards below the fold.
    guard let title = args.dropFirst().first else { print("usage: ax scroll-to <text>"); exit(2) }
    var target: AXUIElement?
    var area: AXUIElement?
    for window in windows where target == nil {
        _ = walk(window) { element, role, _ in
            if role == kAXScrollAreaRole as String, area == nil { area = element }
            if role == kAXStaticTextRole, label(element).localizedCaseInsensitiveContains(title) { target = element; return true }
            return false
        }
    }
    guard let target, let area else { print("no text \(title) or no scroll area"); exit(1) }
    func frame(_ e: AXUIElement) -> CGRect? {
        guard let p: AXValue = attribute(e, kAXPositionAttribute), let s: AXValue = attribute(e, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pt); AXValueGetValue(s, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
    guard let bar: AXUIElement = attribute(area, kAXVerticalScrollBarAttribute) else { print("no vertical scroll bar"); exit(1) }
    // Binary-search the bar value (0...1) until the target sits in the top part of the visible area.
    var lo = 0.0, hi = 1.0
    for _ in 0..<18 {
        let mid = (lo + hi) / 2
        AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: mid))
        usleep(120_000)
        guard let t = frame(target), let a = frame(area) else { break }
        let offset = t.minY - a.minY
        if offset > 80 { lo = mid } else if offset < 20 { hi = mid } else { break }
    }
    print("scrolled to \(title)")
default:
    print("usage: ax list | ax press <title> [nth] | ax fill <label> < file | ax scroll-to <text>")
}
