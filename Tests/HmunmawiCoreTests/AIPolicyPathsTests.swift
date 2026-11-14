import Foundation
import HmunmawiCore
import Testing

@Suite struct AIPolicyPathsTests {
    @Test func portablePolicyFileUsesHmunmawiWhenNoHub() {
        let path = AIPolicyPaths.policyFile.path
        #expect(path.hasSuffix("ai_policy.json"))
    }

    @Test func hubScriptOnlyWithOwnerHub() {
        OwnerConfig.override = OwnerConfig()
        defer { OwnerConfig.override = nil }
        #expect(AIPolicyPaths.hubScript == nil && !AIPolicyPaths.usesHubAdapter)
        var o = OwnerConfig(enabled: true); o.hubRoot = "/tmp/example-hub"
        OwnerConfig.override = o
        #expect(AIPolicyPaths.hubScript?.path == "/tmp/example-hub/scripts/ai_policy.py")
    }
}
