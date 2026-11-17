// Remembers each account's usage readings, so the forecast can follow how you're using an
// account now rather than a straight line from the start of its window (#30).
import Foundation

/// A usage figure and when cswap read it.
struct Reading: Equatable {
    let at: Date
    let pct: Double
}

/// cswap only gives the latest reading, so the app keeps its own short record: a reading is
/// added only when it differs from the last, and dropped once its window resets. A reading's
/// time is when that figure was first seen, so the last one says how long usage has stood still.
final class UsageHistory {
    /// Remembers nothing and saves nothing until launch swaps in one backed by the app's
    /// settings, so the snapshot modes and the self-test never read or write Kevin's.
    nonisolated(unsafe) static var shared = UsageHistory(defaults: nil)
    private static let key = "usageHistory"
    /// Plenty for a week at one reading per point used.
    static let limit = 200

    private let defaults: UserDefaults?
    private(set) var all: [String: [Reading]]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        // Stored as flat [time, pct, time, pct…] lists: property-list friendly and small.
        let saved = defaults?.dictionary(forKey: Self.key) as? [String: [Double]] ?? [:]
        all = saved.mapValues { flat in
            stride(from: 0, to: flat.count - 1, by: 2).map {
                Reading(at: Date(timeIntervalSince1970: flat[$0]), pct: flat[$0 + 1])
            }
        }
    }

    /// The window names readings are kept under: "5h", "7d" and "model:<name>".
    static func name(model: String?) -> String { "model:\(model ?? "")" }

    func readings(_ account: Account, _ window: String) -> [Reading] {
        all["\(account.nicknameKey)|\(window)"] ?? []
    }

    /// Adds every account's new readings after a refresh, and saves only when one changed:
    /// a few times an hour at most while an account is in use, never while it's idle.
    @discardableResult
    func record(_ accounts: [Account], now: Date = clock()) -> Bool {
        var changed = false
        for account in accounts where !account.carriedOver {
            guard let usage = account.usage, let at = account.fetchedDate else { continue }
            var windows: [(String, RawWindow, TimeInterval)] = []
            if let w = usage.fiveHour { windows.append(("5h", w, fiveHourPeriod)) }
            if let w = usage.sevenDay { windows.append(("7d", w, weekPeriod)) }
            for w in usage.scoped ?? [] { windows.append((Self.name(model: w.name), w, weekPeriod)) }
            for (name, raw, period) in windows {
                let key = "\(account.nicknameKey)|\(name)"
                let before = all[key] ?? []
                let after = Self.adding(Reading(at: at, pct: raw.pct), to: before,
                                        resetsAt: raw.resetsAt.flatMap(parseISO), period: period)
                if after != before {
                    all[key] = after.isEmpty ? nil : after
                    changed = true
                }
            }
        }
        // Accounts removed, or not read for a week: nothing of theirs is still useful.
        for (key, list) in all where (list.last?.at ?? .distantPast) < now - weekPeriod {
            all[key] = nil
            changed = true
        }
        if changed, let defaults {
            defaults.set(all.mapValues { $0.flatMap { [$0.at.timeIntervalSince1970, $0.pct] } }, forKey: Self.key)
        }
        return changed
    }

    /// One window's list with a new reading: only readings from the window it belongs to,
    /// and the reading only when it says something new.
    static func adding(_ reading: Reading, to list: [Reading], resetsAt: Date?, period: TimeInterval) -> [Reading] {
        // No reset (a session not started), or one that has passed: nothing is used in this window.
        guard let reset = resetsAt, reset > reading.at else { return [] }
        var list = list.filter { $0.at >= reset - period }
        if let last = list.last {
            if reading.at <= last.at || reading.pct == last.pct { return list }
            if reading.pct < last.pct { list = [] }  // a reset cswap's time didn't show
        }
        list.append(reading)
        return Array(list.suffix(limit))
    }
}
