import Testing
@testable import HmunmawiCore

@Suite struct BankPaymentsTests {
    @Test func keepsOnlyPaidMonthsAsNumbers() {
        let text = """
        [{"m":"2026-09","s":"PAID","a":"26,846.69","c":"INR","d":"2026-10-29"},
         {"m":"2026-10","s":"PENDING_PAYMENT","a":"24,140.38","c":"INR","d":""},
         {"m":"2026-10","s":"NOT_ADVICED_PAYMENT","a":"15.59","c":"USD","d":""},
         {"m":"2026-09","s":"PAID","a":"26,846.69","c":"INR","d":"2026-10-29"},
         {"m":"bad","s":"PAID","a":"1","c":"INR"}, {"m":"2026-08","s":"PAID","a":"-5","c":"INR"}]
        """
        let p = BankPayments.parse(text)
        #expect(p == [.init(month: "2026-09", amount: 26846.69, currency: "INR", paidOn: "2026-10-29")])
        #expect(BankPayments.parse("ERR signin").isEmpty && BankPayments.parse("<html>").isEmpty)
    }
    @Test func scriptAsksForAtMost36Months() {
        #expect(BankPayments.script(months: 99).contains("i<36"))
        #expect(!BankPayments.script().contains("\""))   // safe inside AppleScript's double-quoted string
    }
}
