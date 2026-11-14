import Foundation
import Testing
@testable import HmunmawiCore
/// Real network: only with HM_NET_TEST=1 (download speed and the 20 MB cap through the app's transport).
@Suite struct TransportSpeedTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HM_NET_TEST"] == "1"))
    func chunkedReadIsFullSpeedAndCapped() async throws {
        let t = URLSessionTransport()
        let t0 = Date()
        let (d, r) = try await t.send(URLRequest(url: URL(string: "https://speed.cloudflare.com/__down?bytes=5000000")!))
        print("NET 5 MB: \(d.count) bytes, status \(r.statusCode), \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        #expect(d.count == 5_000_000)
        await #expect(throws: WireError.self) {
            _ = try await t.send(URLRequest(url: URL(string: "https://speed.cloudflare.com/__down?bytes=25000000")!))
        }
    }
}
