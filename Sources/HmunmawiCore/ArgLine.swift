/// Splits an argument line like a shell would for plain words and quotes ("a b" 'c d' e), nothing else:
/// no variables, globs or pipes, since nothing is run through a shell.
public enum ArgLine {
    public static func split(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil, has = false
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; has = true
            } else if ch == " " || ch == "\t" {
                if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
            } else { cur.append(ch) }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }
}
