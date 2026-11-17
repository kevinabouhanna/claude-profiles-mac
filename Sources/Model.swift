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
    var usage: Usage?
    var usageFetchedAt: String?
    /// True when `usage` is the last good reading carried over by `Store`, because
    /// cswap couldn't read a fresh one (usually a sign-in token being renewed).
    var carriedOver = false
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

    /// cswap's `usageStatus` in plain words, for the dropdown. Nil when usage is fine.
    var statusMessage: String? {
        switch usageStatus {
        case nil, "ok": return nil
        case "token_expired":
            return "Claude's sign-in token is renewed every few hours and is being renewed now. This clears on its own."
        case "relogin_required":
            return "This account needs to sign in again: run claude in Terminal, then /login."
        case "keychain_unavailable":
            return "Can't read the Keychain right now. This clears once the Mac is unlocked."
        case "foreign_credential":
            return "Claude Code is signed in to a different account than this one. Switching accounts fixes it."
        case "no_credentials":
            return "No saved sign-in for this account."
        case "api_key":
            return "API key account: there's no plan usage to show."
        case "unavailable":
            return "Couldn't reach Claude to read usage. Trying again on the next refresh."
        case let other?:
            return other.replacingOccurrences(of: "_", with: " ").capitalized + "."
        }
    }

    /// The same, in a few words, for the account list in Settings.
    var statusShort: String? {
        switch usageStatus {
        case nil, "ok": return nil
        case "token_expired": return "Renewing sign-in"
        case "relogin_required": return "Needs to sign in again"
        case "keychain_unavailable": return "Keychain locked"
        case "foreign_credential": return "Signed in as another account"
        case "no_credentials": return "No saved sign-in"
        case "api_key": return "API key account"
        case "unavailable": return "Usage unavailable"
        case let other?: return other.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Statuses that mean "try again later", not "something's wrong with this account":
/// for these, `Store` keeps showing the last good reading.
let passingUsageStatuses: Set<String> = ["token_expired", "unavailable", "keychain_unavailable"]
/// How old a carried-over reading may get before it's dropped.
let carryOverLimit: TimeInterval = 6 * 3600

/// The time the app takes as now. The snapshot modes set it to their fixture's `now`, so
/// what they draw ("Resets Today 5:21 PM", the pace) is the same on every run.
nonisolated(unsafe) var clock: () -> Date = { Date() }

/// "just now", "12 min ago", "3 h ago".
func ageText(since date: Date, now: Date = clock()) -> String {
    let minutes = Int(now.timeIntervalSince(date) / 60)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    return "\(minutes / 60) h ago"
}

/// Account order is cswap's slot numbers: rotation and `cswap list` go by them.
enum SlotOrder {
    /// The `cswap move <slot> <target>` steps that put the accounts now in `slots`
    /// (their numbers, in list order) into `order` (the same numbers, rearranged).
    /// A move onto an occupied slot swaps the two, so the slots keep their numbers
    /// and only who sits in them changes.
    static func moves(slots: [Int], order: [Int]) -> [(from: Int, to: Int)] {
        let targets = slots.sorted()
        var occupant = targets  // occupant[k]: whose account now sits in targets[k]
        var steps: [(from: Int, to: Int)] = []
        for (k, wanted) in order.enumerated() where k < targets.count {
            guard let i = occupant.firstIndex(of: wanted), i != k else { continue }
            steps.append((targets[i], targets[k]))
            occupant.swapAt(i, k)
        }
        return steps
    }
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

// MARK: - Per-model limits

/// Per-model weekly limits (cswap's `scoped`, such as Fable's) you've chosen to hide
/// from the dropdown and the menu bar. Stored as the hidden names, so "never set"
/// (Fable hidden) differs from an empty list (everything shown).
enum ModelLimits {
    private static let key = "hiddenModelLimits"
    static let hiddenByDefault = ["Fable"]

    static var hidden: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? hiddenByDefault)
    }

    static func isHidden(_ name: String?, in hidden: Set<String> = hidden) -> Bool {
        hidden.contains(name ?? "")
    }

    /// The limits to show for an account, in cswap's order.
    static func visible(_ account: Account, hiding hidden: Set<String> = hidden) -> [RawWindow] {
        (account.usage?.scoped ?? []).filter { !isHidden($0.name, in: hidden) }
    }

    /// Every model name worth a toggle: what cswap reports now, plus anything hidden.
    static func known(in accounts: [Account]) -> [String] {
        let reported = accounts.flatMap { $0.usage?.scoped ?? [] }.compactMap(\.name)
        return Array(Set(reported).union(hidden).union(hiddenByDefault)).sorted()
    }

    @MainActor
    static func set(_ name: String, shown: Bool) {
        var all = hidden
        if shown { all.remove(name) } else { all.insert(name) }
        UserDefaults.standard.set(all.sorted(), forKey: key)
        Store.shared.objectWillChange.send()
        Prefs.shared.onStyleChange?()  // the menu bar can show them
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
    /// How close you are to running out (#20): the colour of the number, the bar and the sentence.
    let severity: Severity

    enum Severity { case fine, warning, critical }

    /// The 5-hour session goes by how much is used: Auto-Switch moves you when it's nearly
    /// full, so that's what the colour warns about, not how fast you got there.
    static func sessionSeverity(_ used: Double) -> Severity {
        used >= 80 ? .critical : (used >= 40 ? .warning : .fine)
    }

    /// A week goes by whether it lasts until its reset: orange when it runs out before,
    /// red when a day or more before, or nearly all used. Only once the forecast shows,
    /// so the colour never says something the sentence under the bar doesn't.
    static func weeklySeverity(_ used: Double, runsOut: Date?, reset: Date?) -> Severity {
        if used >= 90 { return .critical }
        guard let runsOut, let reset, runsOut < reset else { return .fine }
        return reset.timeIntervalSince(runsOut) > 86400 ? .critical : .warning
    }

    init(raw: RawWindow?, period: TimeInterval, fetchedAt: Date?, now: Date = clock()) {
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
        let session = period != weekPeriod
        // runsOut: nil while there's no forecast, or it lasts until the reset.
        func rate(runsOut: Date?) -> Severity {
            session ? Self.sessionSeverity(measured) : Self.weeklySeverity(measured, runsOut: runsOut, reset: reset)
        }

        guard let reset else {
            pacePct = nil
            forecast = nil
            severity = rate(runsOut: nil)
            return
        }

        let start = reset - period
        let fraction = min(1, max(0, measuredAt.timeIntervalSince(start) / period))
        let pace = fraction * 100
        pacePct = pace
        let delta = measured - pace

        // Straight-line projection: wildly noisy in the first moments of a window.
        guard fraction >= 0.05 else {
            forecast = measured == 0 ? "Nothing used yet" : nil
            severity = rate(runsOut: nil)
            return
        }
        if measured == 0 {
            forecast = "Nothing used yet"
            severity = rate(runsOut: nil)
            return
        }
        let projected = measured / fraction
        let gap = Int(abs(delta).rounded())
        if projected >= 100 {
            let out = start + period * fraction * (100 / measured)
            severity = rate(runsOut: out)
            if measured >= 100 {
                forecast = "Limit reached"
            } else if gap < 1 {
                // Runs out within moments of the reset: a time a few minutes before it reads
                // like a warning that "On pace" contradicts.
                forecast = "On pace · runs out about when it resets"
            } else {
                forecast = "\(gap)% over pace · runs out \(formatWhen(out))"
            }
        } else {
            severity = rate(runsOut: nil)
            let lead = gap >= 1 ? "\(gap)% under pace" : "On pace"
            forecast = "\(lead) · on track for \(Int(projected.rounded()))%"
        }
    }

    var display: Int { Int(pct.rounded()) }
}

func formatWhen(_ date: Date, now: Date = clock()) -> String {
    let cal = Calendar.current
    let time = DateFormatter()
    time.dateFormat = "h:mm a"
    let clock = time.string(from: date)
    if cal.isDate(date, inSameDayAs: now) { return "Today \(clock)" }
    if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
        return "Tomorrow \(clock)"
    }
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

