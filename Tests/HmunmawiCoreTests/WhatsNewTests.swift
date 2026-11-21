import Foundation
import Testing
@testable import HmunmawiCore

/// What's new after an update, Start here on a fresh install (1.5.4).
@Suite struct WhatsNewTests {
    static let notes = WhatsNew.Notes(
        versions: ["1.6.0", "1.5.10", "1.5.4", "1.5.3", "1.5.2", "1.5.1", "1.5.0"].map { WhatsNew.Version(version: $0, items: [.init(title: "t\($0)", detail: "d")]) },
        start_here: [.init(title: "Today", detail: "d", action: "page:today")])

    @Test func versionsCompareByNumber() {
        #expect(WhatsNew.compare("1.10.0", "1.9.9") == .orderedDescending)
        #expect(WhatsNew.compare("1.5", "1.5.0") == .orderedSame)
        #expect(WhatsNew.compare("1.5.3", "1.5.4") == .orderedAscending)
        #expect(WhatsNew.compare("2", "1.99.99") == .orderedDescending)
    }

    @Test func showsOnlyVersionsSinceTheLastSeenOneNewestFirst() {
        let e = WhatsNew.entries(Self.notes, after: "1.5.2", upTo: "1.5.10")
        #expect(e.map(\.version) == ["1.5.10", "1.5.4", "1.5.3"])        // not 1.6.0 (newer than this app), not 1.5.2
        let many = WhatsNew.entries(Self.notes, after: "0.1", upTo: "1.6.0")
        #expect(many.count == WhatsNew.maxVersions && many.first?.version == "1.6.0")
    }

    @Test func decideFreshUpdateAndUnchanged() {
        #expect(WhatsNew.decide(Self.notes, lastSeen: nil, current: "1.5.4", freshInstall: true) == .startHere(Self.notes.start_here))
        // Updated from a version before this feature: only this version's notes, not the whole history.
        #expect(WhatsNew.decide(Self.notes, lastSeen: nil, current: "1.5.4", freshInstall: false)
                == .whatsNew([Self.notes.versions[2]]))
        if case .whatsNew(let v) = WhatsNew.decide(Self.notes, lastSeen: "1.5.1", current: "1.5.4", freshInstall: false) {
            #expect(v.map(\.version) == ["1.5.4", "1.5.3", "1.5.2"])
        } else { Issue.record("expected what's new") }
        #expect(WhatsNew.decide(Self.notes, lastSeen: "1.5.4", current: "1.5.4", freshInstall: false) == .none)
        #expect(WhatsNew.decide(Self.notes, lastSeen: "1.6.0", current: "1.5.4", freshInstall: false) == .none)   // went back a version
        #expect(WhatsNew.decide(Self.notes, lastSeen: "1.5.4", current: "1.5.5", freshInstall: false) == .none)  // no notes for 1.5.5
    }

    @Test func dismissingMarksTheVersionSeen() {
        let d = UserDefaults(suiteName: "hm-whatsnew-\(UUID().uuidString)")!
        let store = WhatsNew.Store(defaults: d)
        #expect(store.lastSeen == nil)
        store.markSeen("1.5.4")
        #expect(store.lastSeen == "1.5.4")
        #expect(WhatsNew.decide(Self.notes, lastSeen: store.lastSeen, current: "1.5.4", freshInstall: false) == .none)
    }
}
