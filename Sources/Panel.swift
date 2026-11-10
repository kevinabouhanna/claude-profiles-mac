// The dropdown shown when you click the numbers in the menu bar.
import AppKit
import SwiftUI

enum Palette {
    static let card = Color.primary.opacity(0.055)
    static let cardLine = Color.primary.opacity(0.08)
    static let track = Color.primary.opacity(0.14)
    // Darker in light mode: the dark mode values are too pale to read on light glass.
    static let green = adaptive(dark: (0.25, 0.78, 0.42), light: (0.09, 0.50, 0.22))
    static let orange = adaptive(dark: (0.96, 0.62, 0.22), light: (0.72, 0.38, 0.02))
    static let red = adaptive(dark: (0.94, 0.33, 0.31), light: (0.76, 0.15, 0.14))
    /// The selected tab: white on light glass, a lighter grey on dark.
    static let selectedTab = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.17) : NSColor(white: 1, alpha: 1)
    })

    private static func adaptive(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    static func tint(_ s: Window.Severity) -> Color {
        switch s {
        case .fine: return green
        case .overPace: return orange
        case .critical: return red
        }
    }
}

struct PaceBar: View {
    let pct: Double
    let pacePct: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track).frame(height: 5)
                Capsule().fill(tint).frame(width: max(pct > 0 ? 5 : 0, w * min(pct, 100) / 100), height: 5)
                if let pacePct {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary)
                        .frame(width: 2.5, height: 13)
                        .offset(x: min(w - 2.5, w * pacePct / 100))
                }
            }
            .frame(height: 13)
        }
        .frame(height: 13)
    }
}

struct UsageCard: View {
    let title: String
    var subtitle: String?
    var badge: String?
    let window: Window

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary.opacity(0.65))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                Spacer()
                Text("\(window.display)%")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Palette.tint(window.severity))
            }
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundColor(.primary.opacity(0.55))
            }
            PaceBar(pct: window.pct, pacePct: window.pacePct, tint: Palette.tint(window.severity))
            VStack(alignment: .leading, spacing: 2) {
                if let forecast = window.forecast {
                    Text(forecast)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(window.severity == .fine ? .primary.opacity(0.8) : Palette.tint(window.severity))
                }
                Text(window.resetsAt.map { "Resets \(formatWhen($0))" } ?? "Starts when you next use Claude")
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.5))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Palette.card)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.cardLine))
        )
    }
}

/// Which account's usage the cards show, and when the dropdown last closed.
/// Not `@State`: this builds with plain swiftc, which can't load SwiftUI's macros.
/// Shared, so the dropdown can reset it when it closes.
@MainActor
final class AccountPickerState: ObservableObject {
    static let shared = AccountPickerState()
    /// The account picked in the tabs to look at, by number. Nil means the active one.
    @Published var viewing: Int?
    /// A switch after this reads "Now using" in the status bar.
    @Published private(set) var closedAt = Date()

    /// Back to the active account, for the next time the dropdown opens.
    func reset() {
        if viewing != nil { viewing = nil }
        closedAt = Date()
    }

    /// The account the cards show: the one picked, or the active one if none was
    /// picked or it has gone from the list.
    static func viewed(in accounts: [Account], viewing: Int?) -> Account? {
        accounts.first { $0.number == viewing } ?? accounts.first { $0.active == true }
    }

    /// How many tabs fit across the dropdown before the rest go in the arrow's menu.
    nonisolated static let maxTabs = 3

    /// The accounts that get a tab, in list order: the first `limit`, except that the
    /// active and viewed accounts always get one, taking the last places if needed.
    static func tabs(_ numbers: [Int], active: Int?, viewed: Int?, limit: Int = maxTabs) -> [Int] {
        guard numbers.count > limit else { return numbers }
        var pinned: [Int] = []
        for n in [active, viewed].compactMap({ $0 }) where numbers.contains(n) && !pinned.contains(n) {
            pinned.append(n)
        }
        var shown = Array(numbers.prefix(limit))
        for n in pinned where !shown.contains(n) {
            if let i = shown.lastIndex(where: { !pinned.contains($0) }) { shown.remove(at: i) }
            shown.append(n)
        }
        return numbers.filter(shown.contains)
    }
}

/// "18 · 47": an account's 5-hour and weekly numbers.
func usageNumbers(_ account: Account) -> String {
    "\(account.session.map { String($0.display) } ?? "–") · \(account.weekly.map { String($0.display) } ?? "–")"
}

/// One tab per account to choose whose usage the cards show. Looking only: switching
/// lives in the status bar. Accounts past `maxTabs` are behind the arrow at the end.
struct AccountTabs: View {
    @ObservedObject var store: Store
    @ObservedObject private var state = AccountPickerState.shared

    private func show(_ account: Account) {
        withAnimation(.easeInOut(duration: 0.15)) { state.viewing = account.number }
    }

    var body: some View {
        let viewed = AccountPickerState.viewed(in: store.accounts, viewing: state.viewing)
        let shown = AccountPickerState.tabs(
            store.accounts.map(\.number), active: store.activeAccount?.number, viewed: viewed?.number)
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(store.accounts.filter { shown.contains($0.number) }) { account in
                    tab(account, selected: account.number == viewed?.number)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
            if shown.count < store.accounts.count {
                overflow(viewed)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show usage for")
    }

    private func tab(_ account: Account, selected: Bool) -> some View {
        let inUse = account.active == true
        return HStack(spacing: 5) {
            if inUse {
                Circle().fill(Palette.green).frame(width: 6, height: 6)
            }
            Text(account.displayName)
                .lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.primary.opacity(selected ? 1 : 0.7))
        .padding(.horizontal, 6).padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Palette.selectedTab : Color.clear)
                .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { show(account) }
        .help(account.secondaryName.map { "\(account.displayName) · \($0)" } ?? account.displayName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(inUse ? "\(account.displayName), in use" : account.displayName)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { show(account) }
    }

    /// Every account, like a browser's list of tabs. Only there when the tabs don't fit.
    private func overflow(_ viewed: Account?) -> some View {
        Menu {
            Picker("Show usage for", selection: Binding(
                get: { viewed?.number ?? -1 },
                set: { number in
                    if let account = store.accounts.first(where: { $0.number == number }) { show(account) }
                }
            )) {
                ForEach(store.accounts) { account in
                    Text(account.active == true ? "\(account.displayName) · in use" : account.displayName)
                        .tag(account.number)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.primary.opacity(0.7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 26)
        .help("All accounts")
        .accessibilityLabel("All accounts")
    }
}

/// The bottom of the dropdown: which account Claude Code is using, whatever the cards
/// show, and the only place in the dropdown that switches.
struct StatusBar: View {
    @ObservedObject var store: Store
    @ObservedObject private var state = AccountPickerState.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        let active = store.activeAccount
        let switchedAt = store.switchedAt.flatMap { $0 > state.closedAt ? $0 : nil }
        let title = store.switching
            ?? active.map { switchedAt == nil ? "Using \($0.displayName)" : "Now using \($0.displayName)" }
            ?? "No account in use"
        // One short line: the Switch menu leaves room for little more than "Switched Today 3:12 PM".
        let detail = switchedAt.map { "Switched \(formatWhen($0))" }
            ?? (active == nil ? "Pick one to switch to" : prefs.autoSwitchEnabled ? "Auto-Switch on" : "Claude Code")
        let tint = active == nil ? Color.primary : Palette.green

        HStack(spacing: 8) {
            Group {
                if store.switching != nil {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.6))
                } else if switchedAt != nil {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundColor(Palette.green)
                } else {
                    Circle().fill(tint.opacity(active == nil ? 0.3 : 1)).frame(width: 9, height: 9)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11)).foregroundColor(.primary.opacity(0.55))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(store.switching
                ?? active.map { switchedAt == nil ? "Claude Code is using \($0.displayName)" : "Claude Code now uses \($0.displayName)" }
                ?? "No account in use")
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if store.accounts.count > 1 {
                switchMenu
            }
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 9)
        .frame(minHeight: 50)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.13))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.28)))
        )
    }

    /// Every account with its numbers, a check on the one in use. Picking one switches.
    private var switchMenu: some View {
        Menu {
            Picker("Switch Claude Code to", selection: Binding(
                get: { store.activeAccount?.number ?? -1 },
                set: { number in
                    if let account = store.accounts.first(where: { $0.number == number }), account.active != true {
                        store.switchTo(account)
                    }
                }
            )) {
                ForEach(store.accounts) { account in
                    Text("\(account.displayName)   \(usageNumbers(account))").tag(account.number)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Most Available") { store.switchUsing(strategy: "best") }
        } label: {
            Text("Switch")
        }
        .menuStyle(.button)
        .menuIndicator(.visible)
        .controlSize(.small)
        .fixedSize()
        .disabled(store.busy)
        .help("Switch the account Claude Code uses")
        .accessibilityLabel("Switch account")
    }
}

struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject private var picker = AccountPickerState.shared
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let problem = store.problem {
                Text(problem).font(.system(size: 11)).foregroundColor(Palette.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.accounts.count > 1 { AccountTabs(store: store) }
            if let viewed = AccountPickerState.viewed(in: store.accounts, viewing: picker.viewing) {
                cards(for: viewed)
            } else if store.problem == nil && store.accounts.isEmpty {
                Text("No accounts yet. Add one in Settings.")
                    .font(.system(size: 12)).foregroundColor(.primary.opacity(0.6))
            }
            if !store.accounts.isEmpty { StatusBar(store: store) }
        }
        .padding(14)
        .frame(width: 320)  // no background: the popover's Liquid Glass shows through, arrow included
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Claude Profiles").font(.system(size: 15, weight: .bold)).foregroundColor(.primary)
            Spacer()
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise").foregroundColor(.primary.opacity(store.loading ? 0.3 : 0.75))
            }
            .buttonStyle(.plain)
            .help("Refresh")
            Button(action: openSettings) {
                Image(systemName: "gearshape.fill").foregroundColor(.primary.opacity(0.75))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    @ViewBuilder
    private func cards(for account: Account) -> some View {
        if let session = account.session {
            UsageCard(title: "Session Usage", subtitle: "5-hour rolling window", window: session)
        }
        if let weekly = account.weekly {
            UsageCard(title: "All models", badge: "Weekly", window: weekly)
        }
        ForEach(Array(ModelLimits.visible(account).enumerated()), id: \.offset) { _, raw in
            UsageCard(
                title: raw.name ?? "Model",
                badge: "Weekly",
                window: Window(raw: raw, period: weekPeriod, fetchedAt: account.fetchedDate)
            )
        }
        if account.carriedOver {
            let age = account.fetchedDate.map { ageText(since: $0) } ?? "earlier"
            Text("Last reading, from \(age). \(account.statusMessage ?? "")")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if account.session == nil && account.weekly == nil {
            Text(account.statusMessage ?? "No usage available yet.")
                .font(.system(size: 12)).foregroundColor(Palette.orange)
        }
    }
}
