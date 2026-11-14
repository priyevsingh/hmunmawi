import Foundation
import Testing

@Suite struct AIPolicyPortableTests {
    @Test func portablePolicyRoundtripWithoutHubPaths() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "hm-ai-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let policy = tmp.appending(path: "ai_policy.json")
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/HmunmawiApp/Resources/ai_policy.py")
        #expect(FileManager.default.isReadableFile(atPath: script.path))
        var env = ProcessInfo.processInfo.environment
        env["AI_POLICY_FILE"] = policy.path
        func run(_ args: [String]) throws -> Data {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [script.path] + args
            proc.environment = env
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()
            #expect(proc.terminationStatus == 0)
            return out.fileHandleForReading.readDataToEndOfFile()
        }
        _ = try run(["set-pause", "--account", "claude-local", "--until", "2099-01-01T00:00:00Z", "--reason", "portable test"])
        let data = try run(["status", "--account", "claude-local"])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["blocked"] as? Bool == true)
        #expect(obj?["account_id"] as? String == "claude-local")
    }
}
