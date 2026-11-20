import Foundation

/// "Check my workspace Python": finds the Python environments (venvs) your scripts and Mac jobs run with and
/// tells a working one from one a Python upgrade broke (Homebrew removed the Python it was made from). Pure
/// apart from the file checks it is given.
public enum PythonEnv {
    public enum Health: Equatable, Sendable {
        case ok
        case broken(String)
        public var isOK: Bool { self == .ok }
    }

    /// The venv folder for an interpreter path ("/x/.venv/bin/python3" -> "/x/.venv") when that folder has a
    /// pyvenv.cfg (or a `.venv`/`venv` name), else nil.
    public static func root(ofInterpreter path: String, exists: (String) -> Bool) -> String? {
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix("/"), (p as NSString).lastPathComponent.wholeMatch(of: /python[0-9.]*/) != nil else { return nil }
        let bin = (p as NSString).deletingLastPathComponent
        guard (bin as NSString).lastPathComponent == "bin" else { return nil }
        let root = (bin as NSString).deletingLastPathComponent
        let name = (root as NSString).lastPathComponent
        return exists(root + "/pyvenv.cfg") || [".venv", "venv", "env", ".env"].contains(name) ? root : nil
    }

    /// Interpreter paths named in a command: the program itself and any argument that is one.
    public static func interpreters(program: String, args: [String]) -> [String] {
        ([program] + args).filter { ($0 as NSString).lastPathComponent.wholeMatch(of: /python[0-9.]*/) != nil && $0.hasPrefix("/") }
    }

    /// The interpreter in a script's first line ("#!/x/.venv/bin/python" -> that path; "#!/usr/bin/env python3" -> nil).
    public static func shebang(_ firstLine: String) -> String? {
        guard firstLine.hasPrefix("#!") else { return nil }
        let parts = firstLine.dropFirst(2).split(separator: " ").map(String.init)
        guard let first = parts.first, !first.hasSuffix("/env") else { return nil }
        return first
    }

    /// `home = /opt/homebrew/opt/python@3.14/bin` from pyvenv.cfg.
    public static func home(fromConfig text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "home" { return parts[1] }
        }
        return nil
    }

    /// Whether a venv still works: its interpreter exists (a link to a removed Python doesn't) and the Python it
    /// was made from is still there.
    public static func health(root: String, exists: (String) -> Bool, read: (String) -> String?) -> Health {
        let candidates = ["python3", "python"].map { root + "/bin/" + $0 }
        guard candidates.contains(where: exists) else {
            return .broken("its Python is gone (\(root)/bin/python3 points to a Python that was removed or upgraded)")
        }
        if let cfg = read(root + "/pyvenv.cfg"), let home = home(fromConfig: cfg), !exists(home) {
            return .broken("the Python it was made from is gone (\(home))")
        }
        return .ok
    }

    /// Where the package list of a working venv is kept (one file per venv, named after its path).
    public static func lockName(_ root: String) -> String {
        let safe = root.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(safe.suffix(120)) + ".txt"
    }

    /// The repair, as commands: keep the broken folder aside (never deleted), make a fresh venv with the current
    /// python3, and put the same packages back from the saved list when there is one.
    public static func repairSteps(root: String, python3: String, lock: String?, day: String) -> [[String]] {
        var steps: [[String]] = [["/bin/mv", root, root + ".broken-" + day], [python3, "-m", "venv", root]]
        if let lock { steps.append([root + "/bin/python3", "-m", "pip", "install", "--disable-pip-version-check", "-r", lock]) }
        return steps
    }

    /// The same, as one line you can paste into Terminal.
    public static func repairCommand(root: String, lock: String?, day: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var line = "mv \(q(root)) \(q(root + ".broken-" + day)) && python3 -m venv \(q(root))"
        if let lock { line += " && \(q(root + "/bin/python3")) -m pip install -r \(q(lock))" }
        return line
    }
}
