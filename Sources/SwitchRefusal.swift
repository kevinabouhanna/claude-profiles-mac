// Why cswap refused a switch, in plain words, and the background Claude behind it.
import Foundation
import os

/// Switches that stopped another app's Claude, so a helper that died can be traced here.
let switchLog = Logger(subsystem: "com.kevinabouhanna.ClaudeProfiles", category: "switch")

/// cswap refuses a switch when a Claude is running on the target account's own login
/// (a session profile, as `cswap run` makes) and that login has been renewed past
/// cswap's saved copy: activating the saved copy would sign Claude Code out (#61).
struct SwitchRefusal {
    /// The account cswap refused to switch to, by number.
    let account: Int?
    /// The Claude processes running on that account's own login, as cswap names them.
    let pids: [Int32]

    /// A Claude process cswap named, as `ps` sees it.
    struct Helper {
        let pid: Int32
        /// The app it runs under, if any ("Home Control").
        let app: String?
        /// Started by an app to answer in the background (`claude -p`, no terminal), so
        /// stopping it costs no one a conversation: the app starts another when it needs one.
        let background: Bool
    }

    /// The refusal in cswap's failure text, else nil (any other failure keeps cswap's words).
    static func parse(_ text: String) -> SwitchRefusal? {
        guard text.contains("session-mode Claude instance (PID") || text.contains("rotated past the stored backup")
        else { return nil }
        let account = firstCapture(#"Account-(\d+) \([^)]*\) has a"#, in: text).flatMap { Int($0) }
        let pids = firstCapture(#"\(PIDs? ([\d, ]+)\)"#, in: text)
            .map { $0.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } } ?? []
        return SwitchRefusal(account: account, pids: pids)
    }

    /// What to tell the user, in plain words.
    func explain(names: [Int: String], helpers: [Helper]) -> String {
        let name = account.flatMap { names[$0] } ?? account.map { "Account \($0)" } ?? "that account"
        let apps = Array(Set(helpers.compactMap(\.app))).sorted()
        let who: String
        let fix: String
        if !apps.isEmpty {
            let list = apps.joined(separator: " and ")
            who = "\(list) \(apps.count == 1 ? "is" : "are") using"
            fix = "Quit \(list)"
        } else if pids.count > 1 {
            who = "Claude (processes \(pids.map(String.init).joined(separator: ", "))) are using"
            fix = "Quit them"
        } else if let pid = pids.first {
            who = "Claude (process \(pid)) is using"
            fix = "Quit it"
        } else {
            who = "a Claude is using"
            fix = "Quit it"
        }
        return "Couldn't switch to \(name): \(who) \(name)'s own sign-in, which is newer than the saved one. \(fix), then switch again."
    }

    /// Only on a refused switch, so the regex is made then, not kept.
    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: Looking the processes up

    /// Two `ps` runs whatever the number of processes: one for every process's parent and
    /// path (to find each one's app), one for the named processes' terminal and arguments.
    static func lookUp(_ pids: [Int32]) -> [Helper] {
        guard !pids.isEmpty else { return [] }
        let table = processTable(CLI.run("/bin/ps", ["-axo", "pid=,ppid=,comm="], mergeStderr: false, timeout: 10).text)
        let details = CLI.run("/bin/ps", ["-ww", "-o", "pid=,tty=,args=", "-p", pids.map(String.init).joined(separator: ",")],
                              mergeStderr: false, timeout: 10).text
        var running: [Int32: (tty: String, args: String)] = [:]
        details.enumerateLines { line, _ in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { return }
            running[pid] = (String(parts[1]), String(parts[2]))
        }
        return pids.compactMap { pid in
            guard let r = running[pid] else { return nil }  // gone already
            return Helper(pid: pid, app: app(of: pid, in: table), background: isBackground(tty: r.tty, args: r.args))
        }
    }

    /// `ps -axo pid=,ppid=,comm=` as each process's parent and executable.
    static func processTable(_ text: String) -> [Int32: (ppid: Int32, comm: String)] {
        var table: [Int32: (ppid: Int32, comm: String)] = [:]
        text.enumerateLines { line, _ in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return }
            table[pid] = (ppid, String(parts[2]))
        }
        return table
    }

    /// The first `.app` among a process and its parents.
    static func app(of pid: Int32, in table: [Int32: (ppid: Int32, comm: String)]) -> String? {
        var current = pid
        for _ in 0..<12 {
            guard current > 1, let entry = table[current] else { return nil }
            if let app = appName(fromPath: entry.comm) { return app }
            current = entry.ppid
        }
        return nil
    }

    /// "Home Control" from "/Applications/Home Control.app/Contents/MacOS/Home Control".
    static func appName(fromPath path: String) -> String? {
        guard let end = path.range(of: ".app/") else { return nil }
        return path[..<end.lowerBound].split(separator: "/").last.map(String.init)
    }

    /// No terminal, and Claude in print mode: a helper an app keeps, not a conversation.
    static func isBackground(tty: String, args: String) -> Bool {
        let words = args.split(separator: " ")
        return tty == "??" && (words.contains("-p") || words.contains("--print"))
    }

    /// Apps known to keep Claude helpers ready and start them again on their own when one
    /// stops, so stopping one costs at most the answer it was giving. Any other app's
    /// Claude (an agent runner, a script) may be someone's work: never stopped, only named.
    static let restartingApps: Set<String> = ["Home Control"]

    /// Stop and retry only when every Claude cswap named is such a helper, or has gone.
    static func canStop(_ refusal: SwitchRefusal, _ helpers: [Helper]) -> Bool {
        guard !refusal.pids.isEmpty else { return false }
        return helpers.allSatisfy { $0.background && $0.app.map(restartingApps.contains) == true }
    }

    // MARK: Stopping them

    /// Asks the processes to quit and waits up to `limit` for them to go; true when they have.
    static func stop(_ pids: [Int32], limit: TimeInterval = 5) -> Bool {
        for pid in pids { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if pids.allSatisfy(gone) { return true }
            usleep(100_000)
        }
        return false
    }

    /// Exited, even if its app hasn't collected it yet (a zombie still answers `kill(pid, 0)`).
    static func gone(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return true }
        return size == 0 || Int32(info.kp_proc.p_stat) == SZOMB
    }
}

