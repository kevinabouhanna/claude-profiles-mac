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

struct Avatar: View {
    let account: Account
    var body: some View {
        Text(account.initials)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.primary.opacity(0.85))
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.primary.opacity(0.12)))
    }
}

/// Whether the account list is open. Not `@State`: this builds with plain swiftc,
/// which can't load SwiftUI's macros. Shared, so the dropdown can close it.
@MainActor
final class AccountPickerState: ObservableObject {
    static let shared = AccountPickerState()
    @Published var open = false
}

/// The active account, which opens into every account with a Switch button.
struct AccountPicker: View {
    @ObservedObject var store: Store
    @ObservedObject private var state = AccountPickerState.shared
    private var open: Bool {
        get { state.open }
        nonmutating set { state.open = newValue }
    }

    private var canOpen: Bool { store.accounts.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if canOpen { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } } label: {
                HStack(spacing: 9) {
                    if let active = store.activeAccount {
                        Avatar(account: active)
                        names(active)
                    } else {
                        Text("Choose an account").font(.system(size: 12, weight: .medium)).foregroundColor(.primary)
                    }
                    Spacer(minLength: 4)
                    if canOpen {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.6))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(canOpen ? (open ? "Hide accounts" : "Show all accounts") : "")

            if open {
                Divider().padding(.horizontal, 8)
                VStack(spacing: 2) {
                    ForEach(store.accounts) { AccountRow(store: store, account: $0) { open = false } }
                }
                .padding(.vertical, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Palette.card)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.cardLine))
        )
        .onChange(of: store.accounts.count) { _, count in if count < 2 { open = false } }
    }

    private func names(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(account.displayName)
                .font(.system(size: 12, weight: .medium)).foregroundColor(.primary)
                .lineLimit(1).truncationMode(.middle)
            if let email = account.secondaryName {
                Text(email).font(.system(size: 10)).foregroundColor(.primary.opacity(0.5))
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

struct AccountRow: View {
    @ObservedObject var store: Store
    let account: Account
    var switched: () -> Void = {}

    var body: some View {
        HStack(spacing: 9) {
            Avatar(account: account)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(account.numbers)
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundColor(.primary.opacity(0.55))
            }
            Spacer(minLength: 4)
            if account.active == true {
                Text("Active")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Palette.green)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Palette.green.opacity(0.16)))
            } else {
                Button("Switch") {
                    store.switchTo(account)
                    switched()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.14)))
                .disabled(store.busy)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .help(account.email ?? account.displayName)
    }
}

struct PanelView: View {
    @ObservedObject var store: Store
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let problem = store.problem {
                Text(problem).font(.system(size: 11)).foregroundColor(Palette.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !store.accounts.isEmpty { AccountPicker(store: store) }
            if let active = store.activeAccount {
                cards(for: active)
            } else if store.problem == nil {
                Text(store.accounts.isEmpty ? "No accounts yet. Add one in Settings." : "No active account.")
                    .font(.system(size: 12)).foregroundColor(.primary.opacity(0.6))
            }
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
        ForEach(Array((account.usage?.scoped ?? []).enumerated()), id: \.offset) { _, raw in
            UsageCard(
                title: raw.name ?? "Model",
                badge: "Weekly",
                window: Window(raw: raw, period: weekPeriod, fetchedAt: account.fetchedDate)
            )
        }
        if account.session == nil && account.weekly == nil {
            Text("No usage available: \(account.usageStatus ?? "unknown").")
                .font(.system(size: 12)).foregroundColor(Palette.orange)
        }
    }
}
