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

/// How old a reading may get before the app says so (#34): 10 minutes, twice the longest
/// refresh Settings offers. cswap can keep handing over its last reading for an hour when
/// Claude's server asks it to wait; a normal reading is never older than a refresh or so.
let staleLimit: TimeInterval = 600

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
    /// When the reading was taken, if that's longer ago than `staleLimit` (#34); nil while fresh.
    let checkedAt: Date?
    var isOld: Bool { checkedAt != nil }

    enum Severity { case fine, warning, critical }

    /// The thresholds, which Settings also states (#20).
    static let warningAt = 40.0, criticalAt = 80.0
    /// Running out this close to the reset counts as lasting until it: 3% of the window,
    /// 9 minutes of a session or 5 hours of a week, so a reading on pace doesn't flicker.
    static let closeToReset = 0.03

    /// By how much is used, before a window's forecast shows (its first 5%): too early to
    /// trust a projection, so 85% in the first hours is red and 6% green.
    static func levelSeverity(_ used: Double) -> Severity {
        used >= criticalAt ? .critical : (used >= warningAt ? .warning : .fine)
    }

    /// A week this many points over pace, and running out before its reset, is red (#70):
    /// clearly in trouble, not a forecast run long from a small lead.
    static let weeklyFarOverPace = 15.0

    /// A session or a week with a forecast (#68, #70): orange only when it runs out before its
    /// reset, so 44% on track for 64% is green. Red from 80% used, whatever the pace, as the
    /// limit is close; and a week far over pace (27 points), but not one barely over (2 points
    /// on day two, whose straight line also runs out days early). `early` is how long before
    /// the reset it runs out; nil when it lasts. `overPace`: points ahead of an even pace.
    static func forecastSeverity(_ used: Double, early: TimeInterval?, overPace: Double, week: Bool) -> Severity {
        if used >= criticalAt { return .critical }
        guard early != nil else { return .fine }
        return week && overPace >= weeklyFarOverPace ? .critical : .warning
    }

    /// How you're using a window now (#30), from the readings the app remembers.
    enum RecentUse: Equatable {
        /// Not gone up since `since` for longer than `idleAfter`: no run-out time.
        case idle(since: Date)
        /// Points per second over the last `lookback`.
        case rate(Double)
    }

    /// A week's pace is the last day's ("if you keep going like this"), so a night's sleep
    /// is in it; a session's the last hour's. Unchanged for 12 hours, or 30 minutes, is idle.
    static func lookback(_ period: TimeInterval) -> TimeInterval { period == weekPeriod ? 86400 : 3600 }
    static func idleAfter(_ period: TimeInterval) -> TimeInterval { period == weekPeriod ? 12 * 3600 : 1800 }

    /// Nil when too little is remembered to say, or the readings don't match this one.
    static func recentUse(
        _ history: [Reading], measured: Double, at measuredAt: Date, start: Date, period: TimeInterval
    ) -> RecentUse? {
        let readings = history.filter { $0.at >= start && $0.at <= measuredAt }
        guard let last = readings.last, last.pct == measured else { return nil }
        // The last reading is when this figure was first seen: still unchanged since.
        if measuredAt.timeIntervalSince(last.at) >= idleAfter(period) { return .idle(since: last.at) }
        let from = measuredAt - lookback(period)
        let rate: Double
        if from <= start {
            rate = measured / max(1, measuredAt.timeIntervalSince(start))  // the window is younger
        } else if let then = readings.last(where: { $0.at <= from }) {
            rate = (measured - then.pct) / lookback(period)
        } else if let first = readings.first, measuredAt.timeIntervalSince(first.at) >= lookback(period) / 4 {
            // Remembered for less than the lookback (the app is new here): what there is.
            rate = (measured - first.pct) / measuredAt.timeIntervalSince(first.at)
        } else {
            return nil
        }
        return rate > 0 ? .rate(rate) : .idle(since: last.at)
    }

    init(
        raw: RawWindow?, period: TimeInterval, fetchedAt: Date?, now: Date = clock(),
        staleAfter: TimeInterval = staleLimit, history: [Reading]? = nil
    ) {
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
        // A reset that has passed since makes the reading's 0 certain, so it isn't old.
        let old = now.timeIntervalSince(measuredAt) > staleAfter
        checkedAt = old ? measuredAt : nil
        var pace: Double?
        var text: String?
        var hasForecast = false
        var early: TimeInterval?
        var delta = 0.0

        if let reset {
            let start = reset - period
            let fraction = min(1, max(0, measuredAt.timeIntervalSince(start) / period))
            pace = fraction * 100
            delta = measured - fraction * 100
            if measured == 0 {
                text = "Nothing used yet"
                hasForecast = true
            } else if fraction >= 0.05 {  // a projection is wildly noisy before this
                hasForecast = true
                let gap = Int(abs(delta).rounded())
                let lead = gap < 1 ? "On pace" : "\(gap)% \(delta > 0 ? "over" : "under") pace"
                // How fast it's going up now (#30); without enough remembered, the straight
                // line from the window's start, as before.
                let rate: Double
                switch history.flatMap({ Self.recentUse($0, measured: measured, at: measuredAt, start: start, period: period) }) {
                case .idle(let since)?:
                    rate = 0
                    text = "\(lead) · not used for \(idleText(measuredAt.timeIntervalSince(since)))"
                case .rate(let r)?:
                    rate = r
                case nil:
                    rate = measured / max(1, measuredAt.timeIntervalSince(start))
                }
                if measured >= 100 {
                    text = "Limit reached"
                } else if rate > 0 {
                    let projected = measured + rate * reset.timeIntervalSince(measuredAt)
                    if projected >= 100 {
                        let out = measuredAt + (100 - measured) / rate
                        let before = reset.timeIntervalSince(out)
                        if out <= now {
                            // Worked out from an earlier reading, its run-out time has passed.
                            text = "May have run out by now"
                            early = before
                        } else if before < period * Self.closeToReset {
                            // A time minutes before the reset would read as a warning.
                            text = "\(lead) · runs out about when it resets"
                        } else {
                            text = "\(lead) · runs out \(formatWhen(out))"
                            early = before
                        }
                    } else {
                        text = "\(lead) · on track for \(Int(projected.rounded()))%"
                    }
                }
            }
        }
        pacePct = pace
        forecast = text
        // Orange always matches a "runs out" sentence; red adds "nearly at the limit" (80%).
        severity = hasForecast
            ? Self.forecastSeverity(measured, early: early, overPace: delta, week: period == weekPeriod)
            : Self.levelSeverity(measured)
    }

    var display: Int { Int(pct.rounded()) }
}

/// Made once (rule 3): every Window with a forecast formats a time, on every redraw.
private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f
}()
private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f
}()

func formatWhen(_ date: Date, now: Date = clock()) -> String {
    let cal = Calendar.current
    let clock = timeFormatter.string(from: date)
    if cal.isDate(date, inSameDayAs: now) { return "Today \(clock)" }
    if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
        return "Tomorrow \(clock)"
    }
    return "\(dayFormatter.string(from: date)), \(clock)"
}

/// "40 min", "14 h", "3 days": how long usage has stood still, at least.
func idleText(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    return hours < 48 ? "\(hours) h" : "\(hours / 24) days"
}

extension Account {
    var session: Window? {
        usage?.fiveHour.map {
            Window(raw: $0, period: fiveHourPeriod, fetchedAt: fetchedDate,
                   history: UsageHistory.shared.readings(self, "5h"))
        }
    }
    var weekly: Window? {
        usage?.sevenDay.map {
            Window(raw: $0, period: weekPeriod, fetchedAt: fetchedDate,
                   history: UsageHistory.shared.readings(self, "7d"))
        }
    }
    /// A per-model weekly limit, such as Fable's.
    func modelWindow(_ raw: RawWindow) -> Window {
        Window(raw: raw, period: weekPeriod, fetchedAt: fetchedDate,
               history: UsageHistory.shared.readings(self, UsageHistory.name(model: raw.name)))
    }
}

