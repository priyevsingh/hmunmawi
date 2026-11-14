import Foundation

/// What Apple actually paid to your bank, per fiscal month, as App Store Connect's Payments page shows it
/// ("The amount displayed is in your bank account currency"). Apple's API doesn't offer this, so the app reads the
/// page's own data through your signed-in Safari (see Payouts). Pure parsing, so it can be tested.
public enum BankPayments {
    public struct Paid: Equatable, Sendable {
        public let month: String      // "2026-09", Apple's fiscal month
        public let amount: Double
        public let currency: String
        public let paidOn: String     // "2026-10-29"
    }

    /// The JavaScript run in the App Store Connect tab: finds your provider and vendor numbers, then each month's
    /// payment summary for the last `months` months. Returns compact JSON lines, or "ERR <reason>".
    public static func script(months: Int = 18) -> String {
        """
        (function(){function g(u){var x=new XMLHttpRequest();x.open('GET',u,false);x.send();if(x.status!=200)throw 'HTTP '+x.status;return JSON.parse(x.responseText);}\
        try{var b='/WebObjects/iTunesConnect.woa/ra/';var d=g(b+'user/detail');var p=d.data&&(d.data.contentProviderId||(d.data.contentProvider||{}).contentProviderId);if(!p)return 'ERR signin';\
        var vs=(g(b+'paymentConsolidation/providers/'+p+'/sapVendorNumbers').data||[]).map(function(v){return v.sapVendorNumber;});var out=[];var now=new Date();\
        for(var i=0;i<\(max(1, min(months, 36)));i++){var t=new Date(now.getFullYear(),now.getMonth()-i,1);var y=t.getFullYear(),m=t.getMonth()+1;\
        vs.forEach(function(v){try{var r=g(b+'paymentConsolidation/providers/'+p+'/sapVendorNumbers/'+v+'?year='+y+'&month='+m).data;\
        (r&&r.reportSummaries||[]).forEach(function(s){out.push({m:y+'-'+(m<10?'0':'')+m,s:s.status,a:s.amount,c:s.currency,d:(s.paidOrExpectingPaymentDate||'').slice(0,10)});});}catch(e){}});}\
        return JSON.stringify(out);}catch(e){return 'ERR '+e;}})()
        """
    }

    /// Paid months only (not pending or estimated), amounts as numbers. One entry per month and currency.
    public static func parse(_ text: String) -> [Paid] {
        guard let data = text.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return rows.compactMap { r in
            guard (r["s"] as? String) == "PAID", let m = r["m"] as? String, m.wholeMatch(of: /\d{4}-\d{2}/) != nil,
                  let c = r["c"] as? String, c.wholeMatch(of: /[A-Z]{3}/) != nil,
                  let a = Double(((r["a"] as? String) ?? "").replacingOccurrences(of: ",", with: "")), a > 0, a < 1e12,
                  seen.insert(m + c).inserted else { return nil }
            return Paid(month: m, amount: a, currency: c, paidOn: (r["d"] as? String) ?? "")
        }.sorted { $0.month < $1.month }
    }
}
