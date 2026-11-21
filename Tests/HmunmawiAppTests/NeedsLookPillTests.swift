import Foundation
import Testing
@testable import HmunmawiApp

/// A script's "needs a look" is amber in the pill, never red "needs fixing" (1.5.7).
@Suite struct NeedsLookPillTests {
    @Test func amberNotRed() {
        let t = HealthTruth.make(connected: 3, brokenConnections: [], badChecks: [], cautionChecks: ["Needs a look: Site content"],
                                 recovering: false, isDemo: false)
        #expect(t.dot == .attention && t.headline == "1 needs a look")
        let cleared = HealthTruth.make(connected: 3, brokenConnections: [], badChecks: [], cautionChecks: [], recovering: false, isDemo: false)
        #expect(cleared.dot == .good)
    }
}
