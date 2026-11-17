// API credits (#31): what's left of the credits that come with Max (and any bought), read from
// the Claude Console. Anthropic has no official way to read the balance, so each account signs
// in to the Console once, in a window of its own, and the app reads the same addresses the
// Console's Billing page does. The sign-in stays in a WebKit data store of the account's own:
// the app never reads its cookies, and never sees the password.
//
// Off by default, and nothing runs while it's off. An account without credits (Pro, Free, none
// bought, or Max in its first 7 days, before the monthly ones are granted) shows nothing.
import AppKit
import SwiftUI
import WebKit
import os

let creditsLog = Logger(subsystem: "com.kevinabouhanna.ClaudeProfiles", category: "credits")

// MARK: - What the Console says

/// One API organization's balance, or several added together, in cents.
struct CreditBalance: Codable, Equatable {
    struct Promo: Codable, Equatable {
        var name: String?
        /// "subscription_api_credit" for the credits that come with a plan.
        var program: String?
        var remainingCents: Int
        var grantedCents: Int
        var expires: Date?
        var monthly: Bool { program == "subscription_api_credit" }
    }

    var currency: String
    var totalCents: Int
    var boughtCents: Int
    var promos: [Promo]
    var checkedAt: Date

    /// `/api/organizations/<org>/prepaid/credits`. Nil when it isn't that shape.
    static func parse(_ data: Data, checkedAt: Date) -> CreditBalance? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let total = cents(top["amount"]) else { return nil }
        let promos: [Promo] = (top["promo_tranches"] as? [[String: Any]] ?? []).compactMap { t in
            guard let remaining = cents(t["remaining_amount_minor_units"]) else { return nil }
            return Promo(
                name: t["name"] as? String, program: t["program_id"] as? String,
                remainingCents: remaining, grantedCents: cents(t["granted_amount_minor_units"]) ?? remaining,
                expires: (t["expires_at"] as? String).flatMap(parseISO)
            )
        }
        let promoTotal = promos.reduce(0) { $0 + $1.remainingCents }
        let bought = cents(top["amount_without_scoped_credits"]) ?? max(0, total - promoTotal)
        return CreditBalance(
            currency: (top["currency"] as? String) ?? "USD", totalCents: total,
            boughtCents: max(0, bought), promos: promos, checkedAt: checkedAt
        )
    }

    /// Several API organizations under one sign-in, as one balance.
    /// Only the first one's currency counts: dollars and euros don't add up (code review of #75).
    static func sum(_ given: [CreditBalance], checkedAt: Date) -> CreditBalance {
        let all = given.filter { $0.currency == given.first?.currency }
        return CreditBalance(
            currency: all.first?.currency ?? "USD",
            totalCents: all.reduce(0) { $0 + $1.totalCents },
            boughtCents: all.reduce(0) { $0 + $1.boughtCents },
            promos: all.flatMap(\.promos), checkedAt: checkedAt
        )
    }

    private static func cents(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    /// What's left now: a monthly credit past its expiry is gone, even before the next check.
    func leftCents(now: Date) -> Int {
        let expired = promos.filter { ($0.expires ?? .distantFuture) <= now }.reduce(0) { $0 + $1.remainingCents }
        return max(0, totalCents - expired)
    }
}

/// `/api/organizations`: every organization of the signed-in user.
struct ConsoleOrgs: Equatable {
    /// All of them, the claude.ai one included: it's the same as cswap's `organizationUuid`.
    var all: [String]
    /// The ones with API credits (capability "api").
    var api: [String]

    static func parse(_ data: Data) -> ConsoleOrgs? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var orgs = ConsoleOrgs(all: [], api: [])
        for org in list {
            // Only real ids: they go into the next address.
            guard let id = org["uuid"] as? String, UUID(uuidString: id) != nil else { continue }
            orgs.all.append(id.lowercased())
            if (org["capabilities"] as? [String] ?? []).contains("api") { orgs.api.append(id.lowercased()) }
        }
        return orgs
    }

    /// Is this Console sign-in the same account as cswap's? Without an organization from
    /// cswap there's nothing to compare, so yes.
    func matches(_ organizationUuid: String?) -> Bool {
        guard let want = organizationUuid?.lowercased(), !want.isEmpty else { return true }
        return all.contains(want)
    }
}

enum CreditsProblem: String, Codable {
    /// The Console asked to sign in again.
    case signedOut
    /// The Console is signed in to another account than cswap's.
    case wrongAccount
    /// Anything else: offline, the Console changed, a timeout.
    case failed
}

/// What the app knows about one account's credits, kept between launches.
struct CreditsRecord: Codable, Equatable {
    /// The last good reading.
    var balance: CreditBalance?
    /// Why the last check failed; nil when it worked.
    var problem: CreditsProblem?
    /// When the app last tried, worked or not.
    var triedAt: Date?
}

// MARK: - What the dropdown shows

struct CreditsLine: Equatable {
    var amount: String
    var details: [String]
    var warning: String?
}

/// Made once (rule 3).
private let expiryFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f
}()

enum Credits {
    /// Never more often than this, nor than the usage refresh (rule 6).
    static let minimumInterval: TimeInterval = 15 * 60
    /// A check gives up after this.
    static let timeout: TimeInterval = 30
    /// The Console's address. console.anthropic.com now sends you here.
    static let console = "https://platform.claude.com"

    static func money(_ cents: Int, _ currency: String) -> String {
        let amount = String(format: "%.2f", Double(cents) / 100)
        return currency == "USD" ? "$\(amount)" : "\(amount) \(currency)"
    }

    /// The dropdown's card for an account, or nil when there's nothing to show: the setting is
    /// off, it's never been read, or there are no credits (Pro, Max in its first 7 days).
    static func line(_ record: CreditsRecord?, enabled: Bool, now: Date = clock()) -> CreditsLine? {
        guard enabled, let record, let balance = record.balance else { return nil }
        let left = balance.leftCents(now: now)
        guard left > 0 else { return nil }
        var details: [String] = []
        for promo in balance.promos where promo.remainingCents > 0 && (promo.expires ?? .distantFuture) > now {
            let kind = promo.monthly ? "Monthly credit" : "Promotional credit"
            let of = promo.grantedCents > promo.remainingCents ? " of \(money(promo.grantedCents, balance.currency))" : ""
            let ends = promo.expires.map { ", expires \(expiryFormatter.string(from: $0))" } ?? ""
            details.append("\(kind): \(money(promo.remainingCents, balance.currency))\(of)\(ends)")
        }
        if balance.boughtCents > 0 {
            details.append("Bought: \(money(balance.boughtCents, balance.currency))")
        }
        return CreditsLine(
            amount: "\(money(left, balance.currency)) left", details: details,
            warning: warning(record, now: now)
        )
    }

    /// Why the number may be behind, or nil while it's current.
    static func warning(_ record: CreditsRecord, now: Date = clock()) -> String? {
        let since = record.balance.map { ageText(since: $0.checkedAt, now: now) } ?? "never"
        switch record.problem {
        case .signedOut?: return "Console sign-in expired: sign in again in Settings"
        case .wrongAccount?: return "The Console is signed in to another account"
        case .failed?: return "Couldn't check · \(since)"
        case nil:
            guard let checked = record.balance?.checkedAt, now.timeIntervalSince(checked) > 2 * 3600 else { return nil }
            return "Last checked \(since)"
        }
    }

    /// The account's line in Settings, in a few words.
    static func status(_ record: CreditsRecord?, signedIn: Bool, checking: Bool, now: Date = clock()) -> String {
        if !signedIn { return "Not signed in to the Console" }
        guard let record, record.triedAt != nil else { return checking ? "Checking…" : "Signed in" }
        switch record.problem {
        case .signedOut?: return "Sign-in expired"
        case .wrongAccount?: return "Signed in as another account"
        default: break
        }
        var text: String
        if let balance = record.balance {
            let left = balance.leftCents(now: now)
            text = left > 0 ? "\(money(left, balance.currency)) left" : "No API credits yet"
            text += record.problem == .failed
                ? " · couldn't check, \(ageText(since: record.triedAt ?? balance.checkedAt, now: now))"
                : " · checked \(ageText(since: balance.checkedAt, now: now))"
        } else {
            text = "Couldn't check"
        }
        return checking ? "Checking…" : text
    }
}

// MARK: - Keeping it current

@MainActor
final class CreditsMonitor: ObservableObject {
    static let shared = CreditsMonitor()
    private static let recordsKey = "apiCredits"
    private static let signInsKey = "apiCreditsSignIns"

    /// By account email (`nicknameKey`), like nicknames: it stays put when slots are swapped.
    @Published private(set) var records: [String: CreditsRecord]
    /// Each signed-in account's WebKit data store, by account email.
    @Published private(set) var signIns: [String: UUID]
    @Published private(set) var checking: Set<String> = []

    private var timer: Timer?
    private var queue: [String] = []
    private var running = false

    private init() {
        let d = UserDefaults.standard
        records = (d.dictionary(forKey: Self.recordsKey)).flatMap(Self.decode) ?? [:]
        signIns = (d.dictionary(forKey: Self.signInsKey) as? [String: String] ?? [:])
            .compactMapValues(UUID.init(uuidString:))
    }

    /// The setting, mirrored here so the dropdown watches this alone, not every setting
    /// (code review of #75).
    @Published private(set) var enabled = Prefs.shared.showAPICredits

    /// Nothing for an account signed out of the Console, whatever is stored for it.
    func line(for account: Account) -> CreditsLine? {
        guard isSignedIn(account) else { return nil }
        return Credits.line(records[account.nicknameKey], enabled: enabled)
    }

    func isSignedIn(_ account: Account) -> Bool { signIns[account.nicknameKey] != nil }

    var interval: TimeInterval { max(Credits.minimumInterval, TimeInterval(Prefs.shared.refreshInterval)) }

    /// Runs the timer only while there's something to check.
    func sync() {
        if enabled != Prefs.shared.showAPICredits { enabled = Prefs.shared.showAPICredits }
        timer?.invalidate()
        timer = nil
        guard enabled, !signIns.isEmpty else { return }
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in CreditsMonitor.shared.checkAll(olderThan: CreditsMonitor.shared.interval * 0.9) }
        }
        t.tolerance = interval * 0.1  // rule 4
        timer = t
        checkAll(olderThan: interval * 0.9)
    }

    /// Checks every signed-in account last tried longer ago than `age`, one at a time.
    func checkAll(olderThan age: TimeInterval) {
        guard enabled else { return }
        let now = clock()
        for account in Store.shared.accounts where isSignedIn(account) {
            let tried = records[account.nicknameKey]?.triedAt ?? .distantPast
            if now.timeIntervalSince(tried) >= age { enqueue(account.nicknameKey) }
        }
    }

    func checkNow(_ account: Account) { enqueue(account.nicknameKey) }

    private func enqueue(_ key: String) {
        guard !queue.contains(key), !checking.contains(key) else { return }
        queue.append(key)
        guard !running else { return }
        running = true
        Task { @MainActor in
            let monitor = CreditsMonitor.shared
            while !monitor.queue.isEmpty {
                let key = monitor.queue.removeFirst()
                guard monitor.enabled, let store = monitor.signIns[key],
                      let account = Store.shared.accounts.first(where: { $0.nicknameKey == key }) else { continue }
                monitor.checking.insert(key)
                let outcome = await ConsoleCheck.run(store: store, organizationUuid: account.organizationUuid)
                monitor.checking.remove(key)
                monitor.record(outcome, for: key)
            }
            monitor.running = false
        }
    }

    private func record(_ outcome: ConsoleCheck.Outcome, for key: String) {
        // Signed out while it ran (code review of #75): nothing to keep.
        guard signIns[key] != nil else { return }
        var record = records[key] ?? CreditsRecord()
        record.triedAt = clock()
        switch outcome {
        case .balance(let balance):
            record.balance = balance
            record.problem = nil
            creditsLog.notice("Checked API credits: \(balance.totalCents, privacy: .public) cents, \(balance.promos.count, privacy: .public) promotional")
        case .problem(let problem, let why):
            record.problem = problem
            creditsLog.error("Couldn't check API credits (\(problem.rawValue, privacy: .public)): \(why, privacy: .public)")
        }
        records[key] = record
        save()
    }

    // MARK: Signing in and out

    /// Opens the Console in a window of its own for this account: to sign in, or, once
    /// signed in, to look at the Billing page (which then stays open).
    func signIn(_ account: Account) {
        let key = account.nicknameKey
        let problem = records[key]?.problem
        let looking = signIns[key] != nil && problem != .signedOut && problem != .wrongAccount
        ConsoleSignInWindow.show(for: account, store: signIns[key] ?? UUID(), mode: looking ? .billing : .signIn)
    }

    /// Called by the sign-in window once the Console answers as signed in.
    func signedIn(_ account: Account, store: UUID) {
        signIns[account.nicknameKey] = store
        var record = records[account.nicknameKey] ?? CreditsRecord()
        record.problem = nil
        records[account.nicknameKey] = record
        save()
        sync()
        checkNow(account)
    }

    func signOut(_ account: Account) {
        let key = account.nicknameKey
        guard let store = signIns.removeValue(forKey: key) else { return }
        records[key] = nil
        save()
        sync()
        Self.remove(store)
    }

    /// A data store made for a sign-in that was given up.
    func discard(_ store: UUID) {
        guard !signIns.values.contains(store) else { return }
        Self.remove(store)
    }

    /// Deletes a data store, sign-in and all. WebKit refuses while a web view still uses it
    /// (a check running, a window closing), so it tries again a few times (code review of #75).
    private static func remove(_ store: UUID, attempt: Int = 1) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(attempt == 1 ? 1 : 5))
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: store)
            } catch {
                guard attempt < 4 else {
                    creditsLog.error("Couldn't delete a Console sign-in: \(error.localizedDescription, privacy: .public)")
                    return
                }
                remove(store, attempt: attempt + 1)
            }
        }
    }

    // MARK: Storage

    /// Kept as a property list of plain values, so a snapshot fixture's `defaults` can stand in.
    private func save() {
        let d = UserDefaults.standard
        d.set(signIns.mapValues(\.uuidString), forKey: Self.signInsKey)
        d.set(Self.encode(records), forKey: Self.recordsKey)
    }

    static func encode(_ records: [String: CreditsRecord]) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decode(_ plist: [String: Any]) -> [String: CreditsRecord]? {
        guard let data = try? JSONSerialization.data(withJSONObject: plist) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            guard let date = parseISO(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "not ISO 8601: \(s)"))
            }
            return date
        }
        return try? decoder.decode([String: CreditsRecord].self, from: data)
    }
}

// MARK: - One check

/// Reads one account's balance with a short-lived web view on its own sign-in: it opens the
/// Console's list of organizations as a page (so WebKit sends the sign-in itself, as a browser
/// would), then asks for each API organization's credits from there. Gone when it's done.
@MainActor
final class ConsoleCheck: NSObject, WKNavigationDelegate {
    enum Outcome {
        case balance(CreditBalance)
        case problem(CreditsProblem, String)
    }

    private let web: WKWebView
    private var status: Int?
    private var waiter: CheckedContinuation<Bool, Never>?

    private init(store: UUID) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: store)
        config.applicationNameForUserAgent = ConsoleSignInWindow.userAgentSuffix
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        super.init()
        web.navigationDelegate = self
    }

    static func run(store: UUID, organizationUuid: String?) async -> Outcome {
        let check = ConsoleCheck(store: store)
        let timeout = DispatchWorkItem { [weak check] in check?.finish(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Credits.timeout, execute: timeout)
        defer {
            timeout.cancel()
            check.web.stopLoading()
            check.web.navigationDelegate = nil
        }
        return await check.read(organizationUuid)
    }

    private func read(_ organizationUuid: String?) async -> Outcome {
        guard let url = URL(string: Credits.console + "/api/organizations") else { return .problem(.failed, "bad address") }
        let loaded = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            waiter = c
            web.load(URLRequest(url: url, timeoutInterval: Credits.timeout))
        }
        guard loaded else { return .problem(.failed, "the Console didn't answer") }
        let text = (try? await web.evaluateJavaScript("document.body ? document.body.innerText : ''")) as? String ?? ""
        let path = web.url?.path ?? ""
        let orgs = ConsoleOrgs.parse(Data(text.utf8))
        if status == 401 || (status == 403 && orgs == nil && text.hasPrefix("{")) || !path.hasPrefix("/api/") {
            return .problem(.signedOut, "status \(status ?? 0), at \(path)")
        }
        guard status == 200, let orgs else { return .problem(.failed, "organizations: status \(status ?? 0)") }
        guard orgs.matches(organizationUuid) else { return .problem(.wrongAccount, "no matching organization") }
        let now = clock()
        var balances: [CreditBalance] = []
        for org in orgs.api {
            let answer = try? await web.callAsyncJavaScript(
                """
                const r = await fetch(path, {credentials: 'same-origin', signal: AbortSignal.timeout(15000)});
                return [r.redirected ? 401 : r.status, await r.text()];
                """,
                arguments: ["path": "/api/organizations/\(org)/prepaid/credits"], in: nil, contentWorld: .defaultClient
            )
            guard let pair = answer as? [Any], pair.count == 2, let code = (pair[0] as? NSNumber)?.intValue,
                  let body = pair[1] as? String else { return .problem(.failed, "credits: no answer") }
            // 401, or sent on to the sign-in page (code review of #75).
            if code == 401 { return .problem(.signedOut, "credits: signed out") }
            guard code == 200, let balance = CreditBalance.parse(Data(body.utf8), checkedAt: now) else {
                return .problem(.failed, "credits: status \(code)")
            }
            balances.append(balance)
        }
        // No API organization at all: nothing to show, the same as a zero balance.
        return .balance(CreditBalance.sum(balances, checkedAt: now))
    }

    private func finish(_ ok: Bool) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: ok)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        status = (navigationResponse.response as? HTTPURLResponse)?.statusCode
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }
}

// MARK: - The sign-in window

/// The Console's Billing page, in a window of its own, on the account's own WebKit data store.
/// It closes by itself once the Console answers as signed in.
@MainActor
final class ConsoleSignInWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    /// Identifies the web view as Safari, which Google's sign-in asks for.
    static let userAgentSuffix = "Version/26.0 Safari/605.1.15"
    private static var open: [String: ConsoleSignInWindow] = [:]

    enum Mode {
        /// Closes by itself once signed in as the account.
        case signIn
        /// Already signed in: the Billing page, to look at. Stays open.
        case billing
        /// A made-up account's, for a look in a VM: nothing is kept (`-previewConsoleSignIn`).
        case preview
    }

    private let account: Account
    private let store: UUID
    private let mode: Mode
    private let note: NSTextField
    private let window: NSWindow
    private let web: WKWebView
    private var popups: [NSWindow] = []
    private var done = false
    /// The Console's email-code sign-in finishes without loading a new page, so while the
    /// window is open it also asks every few seconds. Only while it's open (rule 6 is for
    /// the background; this is a person signing in).
    private var poll: Timer?

    static func show(for account: Account, store: UUID, mode: Mode) {
        if let existing = open[account.nicknameKey] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let sheet = ConsoleSignInWindow(account: account, store: store, mode: mode)
        open[account.nicknameKey] = sheet
        NSApp.activate()
        sheet.window.makeKeyAndOrderFront(nil)
    }

    private init(account: Account, store: UUID, mode: Mode) {
        self.account = account
        self.store = store
        self.mode = mode
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: store)
        config.applicationNameForUserAgent = Self.userAgentSuffix
        web = WKWebView(frame: .zero, configuration: config)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
        )
        let who = account.email.map { "as \($0)" } ?? "with this account"
        note = NSTextField(wrappingLabelWithString: mode == .billing ? """
            The Console's Billing page for \(account.displayName). Close this window when you're done.
            """ : """
            Sign in \(who), the way you sign in to claude.ai. Claude Profiles only reads your API \
            credit balance from the Console; your sign-in stays in this window's own storage, and \
            the app never sees your password. This window closes once you're signed in.
            """)
        super.init()
        window.title = mode == .billing ? "Claude Console" : "Sign In to the Claude Console"
        window.isReleasedWhenClosed = false
        window.delegate = self

        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        let content = NSView()
        for view in [note, web] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        window.contentView = content
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            web.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 10),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.center()
        web.navigationDelegate = self
        web.uiDelegate = self
        if let url = URL(string: Credits.console + "/settings/billing") { web.load(URLRequest(url: url)) }
        if mode != .billing {
            let t = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkSignedIn() }
            }
            t.tolerance = 1  // rule 4
            poll = t
        }
    }

    /// Signed in once the Console's own list of organizations answers, as a list, without being
    /// sent on to the sign-in page, and it's this account's (code review of #75).
    private func checkSignedIn() {
        guard !done, mode != .billing, web.url?.host?.hasSuffix("platform.claude.com") == true else { return }
        Task { @MainActor in
            let answer = try? await web.callAsyncJavaScript(
                """
                const r = await fetch('/api/organizations', {credentials: 'same-origin'});
                return r.ok && !r.redirected ? await r.text() : '';
                """,
                arguments: [:], in: nil, contentWorld: .defaultClient
            )
            guard !done, let text = answer as? String, let orgs = ConsoleOrgs.parse(Data(text.utf8)) else { return }
            guard orgs.matches(account.organizationUuid) else {
                let who = account.email ?? account.displayName
                note.stringValue = """
                    This Console is signed in to a different account than \(who). Sign out of it (your \
                    name at the bottom left, then Log out) and sign in as \(who).
                    """
                note.textColor = .systemOrange
                return
            }
            done = true
            poll?.invalidate()
            if mode == .signIn { CreditsMonitor.shared.signedIn(account, store: store) }
            window.close()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === web { checkSignedIn() }
    }

    /// Sign-in pages that open a window of their own (Google's, say) get one.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.uiDelegate = self
        let w = NSWindow(
            contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        w.isReleasedWhenClosed = false
        w.title = "Sign In"
        w.contentView = popup
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let w = popups.first(where: { $0.contentView === webView }) {
            w.close()
            popups.removeAll { $0 === w }
            checkSignedIn()
        }
    }

    func windowWillClose(_ notification: Notification) {
        popups.forEach { $0.close() }
        popups.removeAll()
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        if !done || mode == .preview { CreditsMonitor.shared.discard(store) }
        poll?.invalidate()
        poll = nil
        Self.open[account.nicknameKey] = nil
    }
}

// MARK: - The dropdown's card

struct CreditsCard: View {
    let line: CreditsLine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("API Credits").font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                Spacer()
                Text(line.amount)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(.primary)
            }
            ForEach(line.details, id: \.self) { detail in
                Text(detail).font(.system(size: 11)).foregroundColor(.primary.opacity(0.55))
            }
            if let warning = line.warning {
                Text(warning).font(.system(size: 11, weight: .medium)).foregroundColor(Palette.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Palette.card)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.cardLine))
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings

/// Settings → General → API Credits.
struct CreditsSection: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var credits = CreditsMonitor.shared

    var body: some View {
        Section {
            Toggle(isOn: $prefs.showAPICredits) {
                Text("Show API Credits")
                Text("The API credits that come with Max, and any you've bought, read from the Claude Console. Each account signs in to the Console once. Nothing is checked while this is off.")
            }
            if prefs.showAPICredits {
                ForEach(store.accounts) { account in
                    row(account)
                }
            }
        } header: {
            Text("API Credits")
        } footer: {
            if prefs.showAPICredits {
                Text("An account without API credits (Pro, or Max in its first week) shows nothing in the dropdown until it has some.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ account: Account) -> some View {
        let signedIn = credits.isSignedIn(account)
        let key = account.nicknameKey
        return LabeledContent {
            if signedIn {
                Menu {
                    Button("Check Now") { credits.checkNow(account) }
                    Button("Open Billing Page…") { credits.signIn(account) }
                    Divider()
                    Button("Sign Out", role: .destructive) { credits.signOut(account) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More options")
            } else {
                Button("Sign In…") { credits.signIn(account) }
            }
        } label: {
            Text(account.displayName)
            Text(Credits.status(credits.records[key], signedIn: signedIn, checking: credits.checking.contains(key)))
        }
    }
}
