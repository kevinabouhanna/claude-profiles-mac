// Decodes `cswap list --json` and works out pace for each usage window.
import Foundation

// MARK: - cswap JSON

struct ListOutput: Decodable {
    let accounts: [Account]
}

struct Account: Decodable, Identifiable {
    let number: Int
    let email: String?
    let organizationName: String?
    let alias: String?
    let disabled: Bool?
    let active: Bool?
    let usageStatus: String?
    let usage: Usage?
    let usageFetchedAt: String?
    var id: Int { number }

    enum CodingKeys: String, CodingKey {
        case number, email, organizationName, alias, disabled, active, usageStatus, usage, usageFetchedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        email = try? c.decode(String.self, forKey: .email)
        organizationName = try? c.decode(String.self, forKey: .organizationName)
        alias = try? c.decode(String.self, forKey: .alias)
        disabled = try? c.decode(Bool.self, forKey: .disabled)
        active = try? c.decode(Bool.self, forKey: .active)
        usageStatus = try? c.decode(String.self, forKey: .usageStatus)
        usage = try? c.decode(Usage.self, forKey: .usage)  // absent or a sentinel when not "ok"
        usageFetchedAt = try? c.decode(String.self, forKey: .usageFetchedAt)
    }

    var displayName: String { nickname ?? alias ?? email ?? organizationName ?? "Account \(number)" }
    var nickname: String? { Nicknames.name(for: self) }
    /// What a nickname is stored under: the email, which stays put when slots are swapped.
    var nicknameKey: String { email ?? "account-\(number)" }
    /// The email, shown under a nickname or alias so you can still tell accounts apart.
    var secondaryName: String? { displayName != email ? email : nil }
    var initials: String {
        let words = displayName.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).prefix(2)
        return (words.count > 1 && nickname != nil ? words.map { String($0.prefix(1)) }.joined() : String(displayName.prefix(2))).uppercased()
    }
    var fetchedDate: Date? { usageFetchedAt.flatMap(parseISO) }
}

struct Usage: Decodable {
    let fiveHour: RawWindow?
    let sevenDay: RawWindow?
    let scoped: [RawWindow]?
}

struct RawWindow: Decodable {
    let pct: Double
    let resetsAt: String?
    let name: String?
}

/// cswap emits both `...Z` and `....442230+00:00`; the fraction is irrelevant here
/// and ISO8601DateFormatter is picky about its length, so drop it.
/// Made once: building a formatter loads ICU's locale data, which is costly to repeat.
/// ISO8601DateFormatter is thread-safe.
nonisolated(unsafe) private let isoFormatter = ISO8601DateFormatter()

func parseISO(_ s: String) -> Date? {
    let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return isoFormatter.date(from: trimmed)
}

// MARK: - Nicknames

/// Names you give accounts in this app. Unlike `cswap alias` they can be any text,
/// spaces included, and they only change what this app shows.
enum Nicknames {
    private static let key = "accountNicknames"

    static func name(for account: Account) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[account.nicknameKey]
    }

    @MainActor
    static func set(_ name: String, for account: Account) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        all[account.nicknameKey] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(all, forKey: key)
        Store.shared.objectWillChange.send()
        Prefs.shared.onStyleChange?()  // the menu bar can show the name
    }
}

// MARK: - Pace

let fiveHourPeriod: TimeInterval = 5 * 3600
let weekPeriod: TimeInterval = 7 * 86400

/// One usage window with its pace worked out.
struct Window {
    let pct: Double
    let resetsAt: Date?
    /// Where even usage would put you right now (the bar's tick), 0...100. Nil when unknown.
    let pacePct: Double?
    /// The sentence under the bar. Nil when there is nothing meaningful to say yet.
    let forecast: String?
    let severity: Severity

    enum Severity { case fine, overPace, critical }

    init(raw: RawWindow?, period: TimeInterval, fetchedAt: Date?, now: Date = Date()) {
        var measured = raw?.pct ?? 0
        var reset = raw?.resetsAt.flatMap(parseISO)
        var measuredAt = fetchedAt ?? now

        // The reading predates a reset that has since passed, so nothing is used in
        // the new window yet. Weekly resets are a fixed cadence; a 5h window only
        // starts again on next use, so it has no known reset until then.
        if let r = reset, r <= now {
            measured = 0
            measuredAt = now
            if period == weekPeriod {
                var next = r
                while next <= now { next += period }
                reset = next
            } else {
                reset = nil
            }
        }

        pct = measured
        resetsAt = reset

        guard let reset else {
            pacePct = nil
            forecast = nil
            severity = measured >= 90 ? .critical : .fine
            return
        }

        let start = reset - period
        let fraction = min(1, max(0, measuredAt.timeIntervalSince(start) / period))
        let pace = fraction * 100
        pacePct = pace

        let delta = measured - pace
        severity = measured >= 90 || delta >= 15 ? .critical : (delta >= 1 ? .overPace : .fine)

        // Straight-line projection: wildly noisy in the first moments of a window.
        guard fraction >= 0.05 else {
            forecast = measured == 0 ? "Nothing used yet" : nil
            return
        }
        if measured == 0 {
            forecast = "Nothing used yet"
            return
        }
        let projected = measured / fraction
        let gap = Int(abs(delta).rounded())
        if projected >= 100 {
            let runsOut = start + period * fraction * (100 / measured)
            let lead = gap >= 1 ? "\(gap)% over pace" : "On pace"
            forecast = measured >= 100 ? "Limit reached" : "\(lead) · runs out \(formatWhen(runsOut))"
        } else {
            let lead = gap >= 1 ? "\(gap)% under pace" : "On pace"
            forecast = "\(lead) · on track for \(Int(projected.rounded()))%"
        }
    }

    var display: Int { Int(pct.rounded()) }
}

func formatWhen(_ date: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let time = DateFormatter()
    time.dateFormat = "h:mm a"
    let clock = time.string(from: date)
    if cal.isDate(date, inSameDayAs: now) { return "Today \(clock)" }
    if cal.isDateInTomorrow(date) { return "Tomorrow \(clock)" }
    let day = DateFormatter()
    day.dateFormat = "MMM d"
    return "\(day.string(from: date)), \(clock)"
}

extension Account {
    var session: Window? {
        usage?.fiveHour.map { Window(raw: $0, period: fiveHourPeriod, fetchedAt: fetchedDate) }
    }
    var weekly: Window? {
        usage?.sevenDay.map { Window(raw: $0, period: weekPeriod, fetchedAt: fetchedDate) }
    }
}

