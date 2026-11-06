// The Settings window. It's built only from system components (NavigationSplitView,
// grouped Form, standard controls and sheets), so macOS supplies the Liquid Glass
// sidebar, toolbar and control styling itself. Avoid custom chrome here.
import AppKit
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case general, accounts, menuBar, autoSwitch, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .menuBar: return "Menu Bar"
        case .autoSwitch: return "Auto-Switch"
        case .history: return "History"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "person.2"
        case .menuBar: return "menubar.rectangle"
        case .autoSwitch: return "arrow.triangle.2.circlepath"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

@MainActor
final class SettingsUI: ObservableObject {
    static let shared = SettingsUI()
    @Published var pane: Pane? = .general {
        didSet { SettingsWindow.visibleWindow?.title = (pane ?? .general).title }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static var visibleWindow: NSWindow? { window?.isVisible == true ? window : nil }

    static func make() -> NSWindow {
        if let window { return window }
        let hosting = NSHostingController(rootView: SettingsRoot())
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.displayMode = .iconOnly
        w.toolbar = toolbar  // gives the sidebar its full-height Liquid Glass treatment
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.title = (SettingsUI.shared.pane ?? .general).title
        w.setContentSize(NSSize(width: 760, height: 580))
        w.minSize = NSSize(width: 680, height: 440)
        w.center()
        w.setFrameAutosaveName("SettingsWindow")
        window = w
        return w
    }

    static func show(pane: Pane? = nil) {
        if let pane { SettingsUI.shared.pane = pane }
        let w = make()
        AutoConfig.shared.load()
        Store.shared.refresh()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

struct SettingsRoot: View {
    @ObservedObject var ui = SettingsUI.shared
    @ObservedObject var flow = AddAccountFlow.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $ui.pane) {
                ForEach(Pane.allCases) { pane in
                    NavigationLink(value: pane) { Label(pane.title, systemImage: pane.icon) }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch ui.pane ?? .general {
                case .general: GeneralPane()
                case .accounts: AccountsPane()
                case .menuBar: MenuBarPane()
                case .autoSwitch: AutoSwitchPane()
                case .history: HistoryPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle((ui.pane ?? .general).title)
        }
        .sheet(isPresented: $flow.presented) { AddAccountSheet(flow: flow) }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { store.openAtLogin }, set: store.setOpenAtLogin))
            }
            Section("Usage") {
                Picker("Refresh Every", selection: $prefs.refreshInterval) {
                    Text("30 Seconds").tag(30)
                    Text("1 Minute").tag(60)
                    Text("5 Minutes").tag(300)
                }
                LabeledContent("Last Updated") {
                    HStack {
                        Text(store.lastUpdated.map { formatWhen($0) } ?? "Never").foregroundStyle(.secondary)
                        Button("Refresh Now") { store.refresh() }.disabled(store.loading)
                    }
                }
            }
            Section("Notifications") {
                Toggle(isOn: $prefs.notifyOnSwitch) {
                    Text("Notify When the Account Changes")
                    Text("Includes switches made by Auto-Switch.")
                }
            }
            Section("About") {
                LabeledContent("Accounts Managed By", value: store.cswapVersion.isEmpty ? "claude-swap" : store.cswapVersion)
                LabeledContent("Claude Usage Bar") {
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
        }
    }
}

// MARK: - Accounts

struct AccountsPane: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var flow = AddAccountFlow.shared

    var body: some View {
        Form {
            Section {
                if store.accounts.isEmpty {
                    Text("No accounts yet.").foregroundStyle(.secondary)
                }
                ForEach(store.accounts) { SettingsAccountRow(store: store, account: $0) }
            } header: {
                Text("Accounts")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add Account…") { flow.begin() }
                }
            }
            Section("Switch Account") {
                LabeledContent {
                    Button("Rotate") { store.switchUsing(strategy: nil) }
                } label: {
                    Text("Next Account")
                    Text("Moves to the next account in order.")
                }
                LabeledContent {
                    Button("Switch") { store.switchUsing(strategy: "best") }
                } label: {
                    Text("Most Available")
                    Text("Jumps to the account with the most usage left.")
                }
                LabeledContent {
                    Button("Switch") { store.switchUsing(strategy: "next-available") }
                } label: {
                    Text("Next Available")
                    Text("Moves to the next account that hasn't reached a limit.")
                }
            }
            .disabled(store.accounts.count < 2 || store.busy)
        }
    }
}

struct SettingsAccountRow: View {
    @ObservedObject var store: Store
    let account: Account

    private var isActive: Bool { account.active == true }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if isActive {
                    Text("Active").foregroundStyle(.green).font(.callout.weight(.medium))
                } else {
                    Button("Switch") { store.switchTo(account) }.disabled(store.busy)
                }
                Menu {
                    Button("Rename…", action: rename)
                    if account.disabled == true {
                        Button("Include in Auto-Switch") { store.perform(["enable", String(account.number)], failure: "Couldn't update this account.") }
                    } else {
                        Button("Exclude from Auto-Switch") { store.perform(["disable", String(account.number)], failure: "Couldn't update this account.") }
                    }
                    if isActive {
                        Button("Save Current Login") { store.perform(["add"], failure: "Couldn't save the current login.") }
                    }
                    Divider()
                    Button("Remove…", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More options")
            }
        } label: {
            HStack(spacing: 10) {
                Text(account.initials)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.quaternary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName).lineLimit(1).truncationMode(.middle)
                    if let email = account.secondaryName {
                        Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if account.usage != nil {
            parts.append("Session \(account.session?.display ?? 0)%, Weekly \(account.weekly?.display ?? 0)%")
        } else if let status = account.usageStatus {
            parts.append(status.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        if account.disabled == true { parts.append("Excluded from Auto-Switch") }
        return parts.joined(separator: " · ")
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename Account"
        alert.informativeText = "Choose a name for \(account.email ?? "this account"), like Work or Personal. It's shown in the menu bar dropdown instead of the email. Leave it empty to go back to the email."
        let field = NSTextField(string: account.nickname ?? account.alias ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = "Personal"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let account = account
        guard let window = SettingsWindow.visibleWindow else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            Task { @MainActor in Nicknames.set(name, for: account) }
        }
    }

    private func remove() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(account.displayName)?"
        alert.informativeText = isActive
            ? "This is your active account. claude-swap will delete its saved login, and you'd need to add it again to switch back."
            : "claude-swap will delete its saved login. You'd need to sign in and add it again to use it."
        let confirm = alert.addButton(withTitle: "Remove")
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let number = String(account.number)
        let name = account.displayName
        guard let window = SettingsWindow.visibleWindow else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            // `cswap remove` asks for its own confirmation on stdin.
            Task { @MainActor in Store.shared.perform(["remove", number], stdin: "y\n", failure: "Couldn't remove \(name).") }
        }
    }
}

// MARK: - Add account

@MainActor
final class AddAccountFlow: ObservableObject {
    static let shared = AddAccountFlow()

    enum Step: Equatable {
        case choose, preparing, waitingForBrowser, saving
        case finished(String)
        case failed(String)
    }

    @Published var presented = false
    @Published var step: Step = .choose
    @Published var email = ""
    @Published var useToken = false
    @Published var tokenEmail = ""
    @Published var token = ""

    private var login: Process?
    private var cancelled = false

    var isWorking: Bool { [.preparing, .waitingForBrowser, .saving].contains(step) }

    func begin() {
        step = .choose
        email = ""
        tokenEmail = ""
        token = ""
        useToken = false
        presented = true
    }

    func close() {
        cancel()
        token = ""
        presented = false
    }

    func cancel() {
        cancelled = true
        login?.terminate()
        login = nil
    }

    private struct AuthStatus: Decodable {
        let loggedIn: Bool?
        let email: String?
    }

    nonisolated private static func authStatus() -> AuthStatus? {
        let r = CLI.run(CLI.claude, ["auth", "status"], mergeStderr: false, timeout: 30)
        return try? JSONDecoder().decode(AuthStatus.self, from: r.out)
    }

    /// Sign-in replaces Claude Code's active login, and its refresh token rotates in
    /// use. So the current account gets saved first, or its stored login could go stale.
    func startBrowserSignIn() {
        cancelled = false
        step = .preparing
        let requested = email.trimmingCharacters(in: .whitespaces)
        Task.detached {
            let before = Self.authStatus()
            if before?.loggedIn == true {
                let saved = CLI.run(CLI.cswap, ["add"])
                guard saved.ok else {
                    await Self.fail("Couldn't save your current account first, so nothing was changed.\n\n\(saved.text)")
                    return
                }
            }
            let proceed = await MainActor.run { () -> Bool in
                let flow = AddAccountFlow.shared
                if flow.cancelled { flow.step = .choose; return false }
                flow.step = .waitingForBrowser
                return true
            }
            guard proceed else { return }

            var args = ["auth", "login", "--claudeai"]
            if !requested.isEmpty { args += ["--email", requested] }
            let signIn = CLI.run(CLI.claude, args, timeout: 900) { process in
                Task { @MainActor in AddAccountFlow.shared.login = process }
            }
            let wasCancelled = await MainActor.run { () -> Bool in
                let flow = AddAccountFlow.shared
                flow.login = nil
                if flow.cancelled { flow.step = .choose; return true }
                if signIn.ok { flow.step = .saving }
                return false
            }
            guard !wasCancelled else { return }
            guard signIn.ok else {
                // The output holds the sign-in URL, so it isn't shown.
                await Self.fail("Sign-in didn't finish. Your current account is unchanged.")
                return
            }

            let added = CLI.run(CLI.cswap, ["add"])
            let after = Self.authStatus()
            await MainActor.run {
                let flow = AddAccountFlow.shared
                Store.shared.refresh()
                if !added.ok {
                    flow.step = .failed("You signed in, but claude-swap couldn't save the account.\n\n\(added.text)")
                } else if let new = after?.email, new == before?.email {
                    flow.step = .failed("You signed in as \(new) again, so no new account was added. Choose a different account in your browser and try again.")
                } else {
                    flow.step = .finished(after?.email ?? "the new account")
                }
            }
        }
    }

    func startToken() {
        cancelled = false
        step = .saving
        let address = tokenEmail.trimmingCharacters(in: .whitespaces)
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        token = ""
        Task.detached {
            // The token goes over stdin so it never appears in a process listing.
            let r = CLI.run(CLI.cswap, ["add-token", "-", "--email", address], stdin: secret + "\n")
            await MainActor.run {
                Store.shared.refresh()
                AddAccountFlow.shared.step = r.ok ? .finished(address) : .failed(r.text)
            }
        }
    }

    private static func fail(_ message: String) async {
        await MainActor.run { AddAccountFlow.shared.step = .failed(message) }
    }
}

struct AddAccountSheet: View {
    @ObservedObject var flow: AddAccountFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Account").font(.title2.weight(.semibold))
            content
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .choose:
            if flow.useToken { tokenForm } else { browserForm }
        case .preparing:
            progress("Saving your current account…", detail: nil)
        case .waitingForBrowser:
            progress(
                "Finish signing in with your browser",
                detail: "If it signs you in to your current account, use a different account or a private window."
            )
        case .saving:
            progress("Saving the account…", detail: nil)
        case .finished(let email):
            Label("Added \(email)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.headline)
            Text("It's now your active account. Restart any running Claude Code sessions to use it right away.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons { Button("Done") { flow.close() }.keyboardShortcut(.defaultAction) }
        case .failed(let message):
            Label("Account Not Added", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.headline)
            Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Close") { flow.close() }.keyboardShortcut(.cancelAction)
                Button("Try Again") { flow.step = .choose }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var browserForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to another Claude account in your browser. It's saved to claude-swap and becomes your active account in Claude Code. Your current account stays saved, so you can switch back at any time.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent("Email") {
                TextField("Optional", text: $flow.email).textFieldStyle(.roundedBorder)
            }
            buttons {
                Button("Use Setup Token…") { flow.useToken = true }
                Spacer()
                Button("Cancel") { flow.close() }.keyboardShortcut(.cancelAction)
                Button("Sign In…") { flow.startBrowserSignIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(CLI.claude == nil)
            }
        }
    }

    private var tokenForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an account from a token made with `claude setup-token`. It doesn't change the account you're using now.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent("Email") {
                TextField("name@example.com", text: $flow.tokenEmail).textFieldStyle(.roundedBorder)
            }
            LabeledContent("Token") {
                SecureField("sk-ant-oat01-…", text: $flow.token).textFieldStyle(.roundedBorder)
            }
            buttons {
                Button("Use Browser…") { flow.useToken = false }
                Spacer()
                Button("Cancel") { flow.close() }.keyboardShortcut(.cancelAction)
                Button("Add") { flow.startToken() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.tokenEmail.isEmpty || flow.token.isEmpty)
            }
        }
    }

    private func progress(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(title).font(.headline)
            }
            if let detail {
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            buttons { Button("Cancel") { flow.cancel() }.keyboardShortcut(.cancelAction) }
        }
    }

    private func buttons<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Spacer(minLength: 0)
            content()
        }
    }
}

// MARK: - Menu Bar

struct MenuBarPane: View {
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var store = Store.shared

    private func color(_ keyPath: WritableKeyPath<TitleStyle, String>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: nsColor(hex: prefs.style[keyPath: keyPath])) },
            set: { prefs.style[keyPath: keyPath] = hexString(NSColor($0)) }
        )
    }

    private func lightColor(session: Bool) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: nsColor(hex: prefs.style.customHex(session: session, dark: false))) },
            set: {
                let hex = hexString(NSColor($0))
                if session { prefs.style.sessionHexLight = hex } else { prefs.style.weeklyHexLight = hex }
            }
        )
    }

    private func customColorRow(_ title: String, session: Bool) -> some View {
        LabeledContent(title) {
            HStack(spacing: 18) {
                ColorPicker("Light", selection: lightColor(session: session), supportsOpacity: false)
                ColorPicker("Dark", selection: color(session ? \.sessionHex : \.weeklyHex), supportsOpacity: false)
            }
            .fixedSize()
        }
    }

    var body: some View {
        Form {
            Section("Preview") {
                preview(dark: prefs.menuBarIsDark)
                    .padding(.vertical, 2)
            }
            Section("Numbers") {
                Picker("Show", selection: $prefs.style.content) {
                    ForEach(TitleContent.allCases) { Text($0.label).tag($0) }
                }
                Toggle(isOn: $prefs.style.showRemaining) {
                    Text("Show Remaining")
                    Text("Shows what's left instead of what you've used.")
                }
                Toggle("Include Per-Model Limits", isOn: $prefs.style.showModelLimits)
            }
            Section("Layout") {
                Picker("Arrangement", selection: $prefs.style.layout) {
                    ForEach(TitleLayout.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Separator", selection: $prefs.style.separator) {
                    Text("Dot  ·").tag("·")
                    Text("Bar  |").tag("|")
                    Text("Slash  /").tag("/")
                    Text("Space").tag("")
                }
                .disabled(prefs.style.content != .both || prefs.style.layout == .stacked)
                Toggle("Show Weekly First", isOn: $prefs.style.weeklyFirst)
                    .disabled(prefs.style.content != .both)
                Toggle("Show 5h and 7d Labels", isOn: $prefs.style.showLabels)
                Toggle("Show Percent Sign", isOn: $prefs.style.showPercent)
                Toggle("Show Account Name", isOn: $prefs.style.showName)
            }
            Section("Text") {
                Picker("Size", selection: $prefs.style.size) {
                    ForEach(TitleSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Weight", selection: $prefs.style.weight) {
                    ForEach(TitleWeight.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Color") {
                Picker("Color", selection: $prefs.style.colorMode) {
                    ForEach(TitleColorMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                switch prefs.style.colorMode {
                case .system:
                    Text("Numbers follow the menu bar's own light or dark color.")
                        .font(.callout).foregroundStyle(.secondary)
                case .usage:
                    Text("Green when under pace, orange when over pace, and red when far over pace or almost out.")
                        .font(.callout).foregroundStyle(.secondary)
                case .custom:
                    customColorRow("Session", session: true)
                    customColorRow("Weekly", session: false)
                    Text("Each number uses its Light color on a light menu bar and its Dark color on a dark one.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { prefs.style = TitleStyle() }
                }
            }
        }
    }

    private func preview(dark: Bool) -> some View {
        Image(nsImage: MenuBarImage.render(store.activeAccount, prefs.style, dark: dark, template: false))
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(dark ? Color(white: 0.16) : Color(white: 0.92))
            )
    }
}

// MARK: - Auto-Switch

struct AutoSwitchPane: View {
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var config = AutoConfig.shared
    @ObservedObject var auto = AutoSwitcher.shared
    @ObservedObject var store = Store.shared

    private func number(_ key: String, default fallback: Double) -> Binding<Double> {
        Binding(get: { config.number(key, default: fallback) }, set: { config.set(key, $0) })
    }

    private var threshold: Double { config.number("autoswitch.threshold", default: 90) }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $prefs.autoSwitchEnabled) {
                    Text("Switch Accounts Automatically")
                    Text(summary)
                }
            } footer: {
                if store.accounts.count < 2 {
                    Text("Add a second account for Auto-Switch to have somewhere to go.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("When to Switch") {
                percentRow("Switch at Session Usage", key: "autoswitch.threshold", fallback: 90)
                Toggle(
                    "Use a Separate Weekly Limit",
                    isOn: Binding(
                        get: { config.isSet("autoswitch.weeklyThreshold") },
                        set: { config.set("autoswitch.weeklyThreshold", $0 ? threshold : nil) }
                    )
                )
                if config.isSet("autoswitch.weeklyThreshold") {
                    percentRow("Switch at Weekly Usage", key: "autoswitch.weeklyThreshold", fallback: threshold)
                }
                Toggle(
                    "Also Watch Per-Model Limits",
                    isOn: Binding(
                        get: { config.isSet("autoswitch.model") },
                        set: { config.set("autoswitch.model", $0 ? "all" : nil) }
                    )
                )
            }
            Section("Which Account") {
                Picker("Choose", selection: Binding(
                    get: { config.string("autoswitch.strategy", default: "best") },
                    set: { config.set("autoswitch.strategy", $0) }
                )) {
                    Text("Most Available").tag("best")
                    Text("Use Up One at a Time").tag("consume-first")
                    Text("By Priority, One at a Time").tag("priority-consume-first")
                }
                Toggle(isOn: Binding(
                    get: { config.bool("autoswitch.includeApiKeyAccounts") },
                    set: { config.set("autoswitch.includeApiKeyAccounts", $0) }
                )) {
                    Text("Include API Key Accounts")
                    Text("These accounts bill per token.")
                }
            }
            Section("Timing") {
                Picker("Check Every", selection: number("autoswitch.intervalSeconds", default: 60)) {
                    Text("30 Seconds").tag(30.0)
                    Text("1 Minute").tag(60.0)
                    Text("2 Minutes").tag(120.0)
                    Text("5 Minutes").tag(300.0)
                }
                Picker("Wait Between Switches", selection: number("autoswitch.cooldownSeconds", default: 300)) {
                    Text("None").tag(0.0)
                    Text("1 Minute").tag(60.0)
                    Text("5 Minutes").tag(300.0)
                    Text("15 Minutes").tag(900.0)
                    Text("30 Minutes").tag(1800.0)
                }
            }
        }
    }

    private func percentRow(_ title: String, key: String, fallback: Double) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text("\(Int(config.number(key, default: fallback)))%").monospacedDigit()
                Stepper(title, value: number(key, default: fallback), in: 50...99, step: 1).labelsHidden()
            }
        }
    }

    private var summary: String {
        guard prefs.autoSwitchEnabled else { return "Off. You choose when to switch." }
        return auto.running ? "On. Watching your usage in the background." : "Starting…"
    }
}

// MARK: - History

struct HistoryPane: View {
    @ObservedObject var store = Store.shared

    var body: some View {
        let events = SwitchLog.read()
        Form {
            Section {
                if events.isEmpty {
                    Text("No switches yet.").foregroundStyle(.secondary)
                }
                ForEach(events) { event in
                    LabeledContent("\(name(event.from)) → \(name(event.to))", value: event.when)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Show Log in Finder") {
                        let log = SwitchLog.url
                        if FileManager.default.fileExists(atPath: log.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([log])
                        } else {
                            NSWorkspace.shared.open(log.deletingLastPathComponent())
                        }
                    }
                }
            }
        }
    }

    private func name(_ number: Int) -> String {
        store.accounts.first { $0.number == number }?.displayName ?? "Account \(number)"
    }
}
