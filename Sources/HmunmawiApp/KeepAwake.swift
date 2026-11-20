import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// "Keep this Mac awake for routines" (Settings → General): Off (default), While plugged in, or Always.
/// Holds one macOS power assertion against idle sleep while it applies; the screen may still sleep, and closing a
/// laptop's lid still sleeps the Mac. Released the moment it no longer applies (switched off, or on battery in
/// "While plugged in" mode).
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()
    nonisolated static let modeKey = "HMKeepAwake"
    enum Mode: String, CaseIterable { case off, pluggedIn = "plugged-in", always }

    private var assertion: IOPMAssertionID = 0
    private var held = false
    private var timer: Timer?

    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "off") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey); apply() }
    }

    /// Whether the assertion is held right now (for Settings and `hm status`).
    var isHolding: Bool { held }

    func start() {
        apply()
        // Power source changes (plugging in, unplugging) are picked up within a minute.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in KeepAwake.shared.apply() } }
    }

    nonisolated static func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    nonisolated static func shouldHold(_ mode: Mode, onAC: Bool) -> Bool {
        switch mode { case .off: false; case .always: true; case .pluggedIn: onAC }
    }

    func apply() {
        let want = Self.shouldHold(mode, onAC: Self.onACPower())
        if want && !held {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Hmunmawi keeps this Mac awake so your routines run on time (Settings → General)" as CFString, &id)
            if r == kIOReturnSuccess { assertion = id; held = true }
        } else if !want && held {
            IOPMAssertionRelease(assertion)
            held = false; assertion = 0
        }
    }
}
