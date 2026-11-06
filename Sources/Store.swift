// Runs cswap, holds the account list, and manages the auto-switch process.
// This app holds no credentials: everything goes through the cswap and claude CLIs.
import AppKit
import Combine
import ServiceManagement
import UserNotifications

enum CLI {
    private static func find(_ name: String) -> String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static let cswap = find("cswap")
    static let claude = find("claude")

    struct Result {
        let ok: Bool
        let out: Data
        /// Output safe to show the user: any token is masked.
        var text: String {
            String(decoding: out, as: UTF8.self)
                .replacingOccurrences(of: #"sk-ant-[A-Za-z0-9_\-]+"#, with: "[token]", options: .regularExpression)
                .replacingOccurrences(of: #"\u{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Blocking; call off the main thread. `stdin` is how secrets get passed, never argv.
    static func run(
        _ executable: String?, _ args: [String], stdin: String? = nil, mergeStderr: Bool = true,
        timeout: TimeInterval = 60, onStart: ((Process) -> Void)? = nil
    ) -> Result {
        guard let executable else { return Result(ok: false, out: Data("Command not found.".utf8)) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        let input = stdin.map { _ in Pipe() }
        p.standardInput = input ?? FileHandle.nullDevice
        do { try p.run() } catch {
            return Result(ok: false, out: Data(error.localizedDescription.utf8))
        }
        onStart?(p)
        if let input, let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()  // before wait: a full pipe would deadlock
        p.waitUntilExit()
        killer.cancel()
        return Result(ok: p.terminationStatus == 0, out: data)
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var accounts: [Account] = []
    @Published var problem: String?
    @Published var loading = false
    @Published var busy = false
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var lastUpdated: Date?
    @Published var cswapVersion = ""

    private var timer: Timer?
    private(set) var refreshCount = 0
    private var lastActive: Int?

    var activeAccount: Account? { accounts.first { $0.active == true } }

    func start() {
        refresh()
        rescheduleTimer()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in Store.shared.refresh() }
        }
        Task.detached {
            let v = CLI.run(CLI.cswap, ["--version"]).text
            await MainActor.run { Store.shared.cswapVersion = v }
        }
    }

    /// Only re-reads cswap's usage store, which enforces its own API poll floor.
    func rescheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(Prefs.shared.refreshInterval), repeats: true) { _ in
            Task { @MainActor in Store.shared.refresh() }
        }
        // Leeway lets macOS batch this wakeup with others, which saves energy.
        timer?.tolerance = TimeInterval(Prefs.shared.refreshInterval) * 0.1
    }

    func load(_ data: Data) -> Bool {
        guard let parsed = try? JSONDecoder().decode(ListOutput.self, from: data) else { return false }
        accounts = parsed.accounts
        lastUpdated = Date()
        let active = activeAccount
        if let previous = lastActive, let active, active.number != previous, Prefs.shared.notifyOnSwitch {
            Notifier.post(
                "Now using \(active.displayName)",
                "Takes effect within about 30 seconds. Restart Claude Code to apply it right away."
            )
        }
        lastActive = active?.number
        return true
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        refreshCount += 1
        Task.detached {
            let result = CLI.run(CLI.cswap, ["list", "--json"], mergeStderr: false)
            await MainActor.run {
                let store = Store.shared
                store.loading = false
                if CLI.cswap == nil {
                    store.problem = "cswap not found. Install claude-swap first."
                } else if result.ok && store.load(result.out) {
                    store.problem = nil
                } else {
                    store.problem = "Couldn't read usage from cswap. Showing the last reading."
                }
            }
        }
    }

    /// Runs a cswap action, shows its message if it fails, then reloads.
    func perform(_ args: [String], stdin: String? = nil, failure: String) {
        guard !busy else { return }
        busy = true
        Task.detached {
            let result = CLI.run(CLI.cswap, args, stdin: stdin)
            await MainActor.run {
                let store = Store.shared
                store.busy = false
                if !result.ok { store.report(failure, detail: result.text) }
                store.refresh()
            }
        }
    }

    func switchTo(_ account: Account) {
        perform(["switch", String(account.number)], failure: "Couldn't switch to \(account.displayName).")
    }

    /// nil rotates to the next account; otherwise "best" or "next-available".
    func switchUsing(strategy: String?) {
        let args = strategy.map { ["switch", "--strategy", $0] } ?? ["switch"]
        perform(args, failure: "Couldn't switch accounts.")
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            openAtLogin = on
        } catch {
            report("Couldn't change Open at Login.", detail: error.localizedDescription)
        }
    }

    /// An alert over Settings when it's open, otherwise a line in the dropdown.
    func report(_ message: String, detail: String) {
        if let window = SettingsWindow.visibleWindow {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = message
            alert.informativeText = String(detail.suffix(600))
            alert.beginSheetModal(for: window)
        } else {
            problem = detail.isEmpty ? message : "\(message) \(String(detail.suffix(200)))"
        }
    }
}

enum Notifier {
    static func post(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

// MARK: - Auto-switch

/// Runs the same engine as the old menu bar app, `cswap auto`, as a child process.
@MainActor
final class AutoSwitcher: ObservableObject {
    static let shared = AutoSwitcher()
    private static let pidKey = "autoSwitchPID"

    @Published private(set) var running = false
    var extraArgs: [String] = []
    private var process: Process?
    var pid: Int32? { process?.processIdentifier }
    private var restartWork: DispatchWorkItem?

    /// A previous run that crashed can leave its child behind; two engines would fight.
    func cleanUpOrphan() {
        let pid = UserDefaults.standard.integer(forKey: Self.pidKey)
        guard pid > 0 else { return }
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
        let command = CLI.run("/bin/ps", ["-p", String(pid), "-o", "command="]).text
        if command.contains("cswap auto") { kill(pid_t(pid), SIGTERM) }
    }

    func sync() {
        if Prefs.shared.autoSwitchEnabled { start() } else { stop() }
    }

    func start() {
        restartWork?.cancel()
        guard process == nil, let cswap = CLI.cswap else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cswap)
        p.arguments = ["auto"] + extraArgs
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { finished in
            Task { @MainActor in AutoSwitcher.shared.didExit(finished) }
        }
        do {
            try p.run()
            process = p
            running = true
            UserDefaults.standard.set(Int(p.processIdentifier), forKey: Self.pidKey)
        } catch {
            running = false
        }
    }

    func stop() {
        restartWork?.cancel()
        guard let p = process else { return }
        process = nil
        running = false
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
        p.terminate()
    }

    /// `cswap auto` reads its settings at startup, so changes need a restart.
    func restartIfRunning() {
        guard process != nil else { return }
        stop()
        restartWork?.cancel()
        let work = DispatchWorkItem { AutoSwitcher.shared.sync() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func didExit(_ finished: Process) {
        guard finished === process else { return }  // we stopped it on purpose
        process = nil
        running = false
        // Unexpected exit: try again shortly rather than quietly staying off.
        let work = DispatchWorkItem { AutoSwitcher.shared.sync() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }
}

/// claude-swap's own `autoswitch.*` settings, shared with the CLI.
@MainActor
final class AutoConfig: ObservableObject {
    static let shared = AutoConfig()

    @Published private(set) var values: [String: Any] = [:]
    private static let queue = DispatchQueue(label: "cswap.config")  // keeps writes in order

    private struct Listing: Decodable {
        struct Item: Decodable {
            let key: String
            let double: Double?
            let string: String?
            let bool: Bool?
            enum CodingKeys: String, CodingKey { case key, value }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                key = try c.decode(String.self, forKey: .key)
                bool = try? c.decode(Bool.self, forKey: .value)
                double = bool == nil ? try? c.decode(Double.self, forKey: .value) : nil
                string = try? c.decode(String.self, forKey: .value)
            }
        }
        let settings: [Item]
    }

    func load() {
        Task.detached {
            let result = CLI.run(CLI.cswap, ["config", "list", "--json"], mergeStderr: false)
            guard let listing = try? JSONDecoder().decode(Listing.self, from: result.out) else { return }
            var next: [String: Any] = [:]
            for item in listing.settings {
                if let v: Any = item.bool ?? item.double ?? item.string { next[item.key] = v }
            }
            let loaded = next
            await MainActor.run { AutoConfig.shared.values = loaded }
        }
    }

    func number(_ key: String, default fallback: Double) -> Double { values[key] as? Double ?? fallback }
    func string(_ key: String, default fallback: String) -> String { values[key] as? String ?? fallback }
    func bool(_ key: String) -> Bool { values[key] as? Bool ?? false }
    func isSet(_ key: String) -> Bool { values[key] != nil }

    /// A nil value removes the setting so it goes back to claude-swap's default.
    func set(_ key: String, _ value: Any?) {
        if let value { values[key] = value } else { values[key] = nil }
        let args: [String]
        switch value {
        case nil: args = ["config", "unset", key]
        case let d as Double: args = ["config", "set", key, d == d.rounded() ? String(Int(d)) : String(d)]
        case let b as Bool: args = ["config", "set", key, b ? "true" : "false"]
        default: args = ["config", "set", key, "\(value!)"]
        }
        Self.queue.async {
            let result = CLI.run(CLI.cswap, args)
            Task { @MainActor in
                if !result.ok { Store.shared.report("Couldn't save that setting.", detail: result.text) }
                AutoConfig.shared.load()
                AutoSwitcher.shared.restartIfRunning()
            }
        }
    }
}

// MARK: - Switch history

struct SwitchEvent: Identifiable {
    let id = UUID()
    let from: Int
    let to: Int
    let when: String
}

enum SwitchLog {
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude-swap-backup/claude-swap.log")
    }

    static func parse(_ text: String, limit: Int = 50) -> [SwitchEvent] {
        guard let regex = try? NSRegularExpression(pattern: #"Switched from account (\d+) to (\d+)"#) else { return [] }
        var events: [SwitchEvent] = []
        text.enumerateLines { line, _ in
            let range = NSRange(line.startIndex..., in: line)
            guard let m = regex.firstMatch(in: line, range: range),
                  let a = Range(m.range(at: 1), in: line), let b = Range(m.range(at: 2), in: line),
                  let from = Int(line[a]), let to = Int(line[b])
            else { return }
            let stamp = line.components(separatedBy: " - ").first ?? ""
            events.append(SwitchEvent(from: from, to: to, when: String(stamp.prefix(16))))
        }
        return Array(events.suffix(limit).reversed())
    }

    static func read() -> [SwitchEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
        return parse(String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self))
    }
}
