import Foundation
import Testing
@testable import HmunmawiApp

@Test func ascWebhookBackoffIsBounded() {
    for attempt in 0..<20 {
        let d = AscWebhookStream.backoffDelay(attempt: attempt, cap: 120)
        #expect(d >= 0 && d <= 120)
    }
    let high = AscWebhookStream.backoffDelay(attempt: 50, cap: 120)
    #expect(high <= 120)
}

@Test func ascWebhookBackoffGrowsOnAverage() {
    var sumLow = 0.0, sumHigh = 0.0
    for _ in 0..<200 {
        sumLow += AscWebhookStream.backoffDelay(attempt: 1, cap: 120)
        sumHigh += AscWebhookStream.backoffDelay(attempt: 8, cap: 120)
    }
    #expect(sumHigh / 200 > sumLow / 200)
}
