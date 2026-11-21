import Foundation
import HmunmawiCore
import Testing
@testable import HmunmawiApp

@Suite struct MenuBarFeedTests {
    func ev(_ kind: String, app: String?) -> StoredEvent {
        StoredEvent(id: 1, source: "t", kind: kind, app: app,
                    payload: .object(["title": .string("Pocket Garden 4.1.8: In review → Ready for distribution")]), occurredAt: 0)
    }

    /// A version update from App Store Connect has no app of its own: it must not be labelled as Hmunmawi.
    @Test func versionUpdatesAreHeadedAppStoreConnect() {
        #expect(MenuBarPanel.heading(ev("asc.webhook", app: nil)) == "App Store Connect")
        #expect(MenuBarPanel.heading(ev("asc.webhook", app: "")) == "App Store Connect")
    }

    @Test func eventsWithAnAppKeepTheirApp() {
        #expect(MenuBarPanel.heading(ev("revenue.renewal", app: "Pocket Garden")) == "Pocket Garden")
        #expect(MenuBarPanel.heading(ev("asc.webhook", app: "Pocket Garden")) == "Pocket Garden")
        #expect(MenuBarPanel.heading(ev("system.note", app: nil)) == "Hmunmawi")
    }
}
