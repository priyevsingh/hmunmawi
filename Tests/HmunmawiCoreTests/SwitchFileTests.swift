import Foundation
import Testing
@testable import HmunmawiCore

private let sample = """
{
  "_comment": "Which social jobs run. Flip a value to true to turn it back on.",
  "instagram_warmup": false,
  "discord": false,
  "new_instagram_carousels": false,
  "instagram_drafts": false,
  "extra_list": [1, "two", {"three": true}],
  "warmed_up": {
    "since": "2026-01-01",
    "reddit": true,
    "discord": true,
    "instagram": true
  }
}

"""

private func tempFile(_ text: String?) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "switchfile-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "switches.json")
    if let text { try Data(text.utf8).write(to: url) }
    return url
}

private func object(_ url: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

@Suite struct SwitchFileTests {
    @Test func readsCurrentValuesAndDefaults() throws {
        let url = try tempFile(sample)
        let loaded = try SwitchFile.load(url).get()
        let byID = Dictionary(uniqueKeysWithValues: loaded.switches.map { ($0.id, $0) })
        #expect(byID["discord"]?.value == false && byID["discord"]?.isSet == true)
        #expect(byID["warmed_up.reddit"]?.value == true)
        #expect(byID["warmed_up.instagram"]?.group == SwitchFile.warmupGroup)
        // Core channels missing from the file show their default (on) and are marked not set.
        #expect(byID["reddit"]?.value == true && byID["reddit"]?.isSet == false)
        #expect(byID["youtube_shorts"]?.value == true && byID["x"]?.value == true && byID["instagram"]?.value == true)
        // Notes, strings and lists are never switches.
        #expect(byID["_comment"] == nil && byID["warmed_up.since"] == nil && byID["extra_list"] == nil)
        #expect(loaded.comment?.hasPrefix("Which social jobs") == true)
    }

    @Test func flipKeepsEverythingElseByteForByte() throws {
        let url = try tempFile(sample)
        _ = try SwitchFile.set(["discord"], to: true, in: url).get()
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after == sample.replacingOccurrences(of: "\"discord\": false", with: "\"discord\": true"))
        _ = try SwitchFile.set(["discord"], to: false, in: url).get()
        #expect(try String(contentsOf: url, encoding: .utf8) == sample)   // round trip restores the exact bytes
    }

    @Test func nestedFlipRoundTrip() throws {
        let url = try tempFile(sample)
        let loaded = try SwitchFile.set(["warmed_up", "instagram"], to: false, in: url).get()
        #expect(loaded.switches.first { $0.id == "warmed_up.instagram" }?.value == false)
        let obj = try object(url)
        #expect((obj["warmed_up"] as? [String: Any])?["since"] as? String == "2026-01-01")
        #expect((obj["warmed_up"] as? [String: Any])?["reddit"] as? Bool == true)
        _ = try SwitchFile.set(["warmed_up", "instagram"], to: true, in: url).get()
        #expect(try String(contentsOf: url, encoding: .utf8) == sample)
    }

    @Test func missingKeyIsAddedKeepingUnknownKeys() throws {
        let url = try tempFile(sample)
        _ = try SwitchFile.set(["x"], to: false, in: url).get()
        let obj = try object(url)
        #expect(obj["x"] as? Bool == false)
        #expect(obj["_comment"] as? String == "Which social jobs run. Flip a value to true to turn it back on.")
        #expect((obj["extra_list"] as? [Any])?.count == 3)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\n  },\n  \"x\": false\n}"))   // same indentation as the other keys
        #expect(try SwitchFile.load(url).get().switches.first { $0.id == "x" }?.isSet == true)
    }

    @Test func missingNestedObjectIsCreated() throws {
        let url = try tempFile(#"{"_comment": "c", "reddit": true}"#)
        _ = try SwitchFile.set(["warmed_up", "reddit"], to: true, in: url).get()
        let obj = try object(url)
        #expect((obj["warmed_up"] as? [String: Any])?["reddit"] as? Bool == true)
        #expect(obj["_comment"] as? String == "c")
    }

    @Test func emptyObjectGetsTheKey() throws {
        let url = try tempFile("{}")
        _ = try SwitchFile.set(["reddit"], to: false, in: url).get()
        #expect(try object(url)["reddit"] as? Bool == false)
    }

    @Test func missingFile() throws {
        let url = try tempFile(nil)
        #expect(SwitchFile.load(url) == .failure(.missing))
        #expect(SwitchFile.set(["discord"], to: true, in: url) == .failure(.missing))
        #expect(!FileManager.default.fileExists(atPath: url.path))   // never created
    }

    @Test func badJSONIsLeftAlone() throws {
        let broken = "{ \"discord\": false, "
        let url = try tempFile(broken)
        guard case .failure(.notJSON) = SwitchFile.load(url) else { Issue.record("expected notJSON"); return }
        guard case .failure(.notJSON) = SwitchFile.set(["discord"], to: true, in: url) else { Issue.record("expected notJSON"); return }
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)
        let arrayURL = try tempFile("[true]")
        #expect(SwitchFile.load(arrayURL) == .failure(.notObject))
    }

    @Test func refusesToOverwriteNonBooleans() throws {
        let text = #"{"discord": "sometimes", "warmed_up": "yes", "_comment": "c"}"#
        let url = try tempFile(text)
        #expect(SwitchFile.set(["discord"], to: true, in: url) == .failure(.notSwitch("discord")))
        #expect(SwitchFile.set(["warmed_up", "reddit"], to: true, in: url) == .failure(.notSwitch("warmed_up")))
        #expect(SwitchFile.set(["_comment"], to: true, in: url) == .failure(.notSwitch("_comment")))
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        let ids = try SwitchFile.load(url).get().switches.map(\.id)
        #expect(!ids.contains("discord") && !ids.contains("warmed_up.reddit"))
    }

    @Test func atomicWriteKeepsPermissionsAndLeavesNoTempFiles() throws {
        let url = try tempFile(sample)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        _ = try SwitchFile.set(["instagram_drafts"], to: true, in: url).get()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // An atomic write replaces the file (new inode) instead of rewriting it in place.
        #expect(attrs[.systemFileNumber] as? Int != before)
        let left = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(left == ["switches.json"])
    }

    @Test func writesThroughASymlink() throws {
        let url = try tempFile(sample)
        let link = url.deletingLastPathComponent().appending(path: "link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        _ = try SwitchFile.set(["discord"], to: true, in: link).get()
        #expect(try object(url)["discord"] as? Bool == true)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test func otherWorkspacesExposeTheirOwnSwitches() throws {
        let text = #"{"newsletter": true, "jobs": {"nightly_backup": false}, "_help": {"newsletter": "Weekly mail to subscribers."}, "_labels": {"jobs.nightly_backup": "Nightly backup"}}"#
        let url = try tempFile(text)
        let s = try SwitchFile.load(url).get().switches
        #expect(s.map(\.id) == ["jobs.nightly_backup", "newsletter"])   // no social defaults for an unrelated file
        #expect(s.first { $0.id == "newsletter" }?.help == "Weekly mail to subscribers.")
        #expect(s.first { $0.id == "jobs.nightly_backup" }?.label == "Nightly backup")
        _ = try SwitchFile.set(["jobs", "nightly_backup"], to: true, in: url).get()
        #expect((try object(url)["jobs"] as? [String: Any])?["nightly_backup"] as? Bool == true)
    }

    @Test func escapedStringsDoNotConfuseTheScanner() throws {
        let text = #"{"_comment": "quote \" brace } comma , \\", "discord": false}"#
        let url = try tempFile(text)
        _ = try SwitchFile.set(["discord"], to: true, in: url).get()
        #expect(try String(contentsOf: url, encoding: .utf8) == text.replacingOccurrences(of: "false", with: "true"))
    }

    @Test func locatesTheFile() throws {
        let hub = FileManager.default.temporaryDirectory.appending(path: "hub-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hub.appending(path: "config"), withIntermediateDirectories: true)
        var owner = OwnerConfig(enabled: true)
        owner.hubRoot = hub.path
        #expect(SwitchFile.locate(chosen: nil, owner: owner) == nil)
        try Data("{}".utf8).write(to: hub.appending(path: "config/social_channels.json"))
        #expect(SwitchFile.locate(chosen: nil, owner: owner)?.lastPathComponent == "social_channels.json")
        try Data("{}".utf8).write(to: hub.appending(path: "config/hmunmawi-switches.json"))
        #expect(SwitchFile.locate(chosen: nil, owner: owner)?.lastPathComponent == "hmunmawi-switches.json")
        owner.switchFile = "config/mine.json"
        #expect(SwitchFile.locate(chosen: nil, owner: owner)?.path == hub.appending(path: "config/mine.json").path)
        #expect(SwitchFile.locate(chosen: "/tmp/chosen.json", owner: owner)?.path == "/tmp/chosen.json")
        #expect(SwitchFile.locate(chosen: nil, owner: OwnerConfig()) == nil)   // a normal install without owner settings
    }
}
