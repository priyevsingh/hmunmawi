import Foundation
import Testing
@testable import HmunmawiApp

/// The MCP tools' command lists (Sources/hmunmawi-cli/main.swift) must name every command in the agent guide, so a new
/// command can't be left unreachable over MCP again (plan-remove was, in 1.5.0).
@Suite struct MCPToolListTests {
    static func set(_ name: String, in source: String) -> Set<String> {
        guard let start = source.range(of: "let \(name)"), let eq = source[start.upperBound...].range(of: "= ["),
              let close = source[eq.upperBound...].firstIndex(of: "]") else { return [] }
        let body = source[eq.upperBound..<close]
        return Set(body.matches(of: /"([a-z][a-z0-9-]*)"/).map { String($0.output.1) })
    }

    @Test func everyGuideCommandHasATool() throws {
        let main = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/hmunmawi-cli/main.swift")
        let source = try String(contentsOf: main, encoding: .utf8)
        let read = Self.set("readCommands", in: source), change = Self.set("changeCommands", in: source), act = Self.set("actCommands", in: source)
        #expect(read.isDisjoint(with: change) && act.isDisjoint(with: change))
        let guide = AgentGuide.commands.flatMap { row in
            (row["name"] ?? "").split(separator: " ").first.map { $0.split(separator: "|").map(String.init) } ?? []
        }
        let viaKeysOnly: Set<String> = ["set-key"]   // keys never go through MCP (they'd end up in the chat)
        for c in Set(guide).subtracting(viaKeysOnly) {
            #expect(read.contains(c) || change.contains(c) || act.contains(c), "\(c) has no MCP tool")
        }
        #expect(change.contains("plan-remove") && read.contains("mail-status") && read.contains("wall-plan"))
    }
}
