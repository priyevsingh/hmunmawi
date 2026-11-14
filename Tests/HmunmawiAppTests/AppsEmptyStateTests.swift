import Foundation
import Testing
@testable import HmunmawiApp

/// Apps' empty state: a website project is told where its numbers are, not that an app name is missing.
@Suite @MainActor struct AppsEmptyStateTests {
    @Test func websiteProjectSaysItIsAWebsite() {
        let site = Project(name: "Hill Trails", kind: .website, members: ["Hill Trails", "hilltrails"])
        let e = AppsPager.emptyState(site)
        #expect(e.title == "Hill Trails is a website")
        #expect(e.detail.contains("on Today") && !e.detail.contains("add the app's name"))
    }

    @Test func appsProjectWithoutAppsKeepsTheMembersHint() {
        let e = AppsPager.emptyState(Project(name: "New", kind: .apps, members: ["Nope"]))
        #expect(e.title == "No apps in this project" && e.detail.contains("Settings → Projects"))
    }
}

@Suite struct OutreachProjectCountTests {
    @Test func newSuggestionsCountOnlyThePickedProjectsApps() {
        func s(_ id: String, _ app: String, _ state: String = "new") -> OSuggestion {
            OSuggestion(id: id, entry: id, outlet: "O", app: app, kind: "no reply", why: "", day: "2026-11-10", sure: true, state: state)
        }
        let all = [s("1", "Pulse Diary"), s("2", "Pocket Garden"), s("3", "Pulse Diary", "done")]
        #expect(Outreach.newCount(all) { _ in true } == 2)
        #expect(Outreach.newCount(all) { $0 == "Hill Trails" } == 0)
    }
}

@Suite @MainActor struct AutomationsProjectKeyTests {
    @Test func switchingProjectChangesTheMapKey() {
        let all = FlowModel.memoKey(day: 1, live: true, mode: nil, project: nil)
        let site = FlowModel.memoKey(day: 1, live: true, mode: nil, project: "6F951D96")
        #expect(all != site)
        #expect(all == FlowModel.memoKey(day: 1, live: true, mode: nil, project: nil))
    }
}
