// App entry point, the menu bar item, and debug modes for rendering and self-testing.
import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    /// Every redraw goes through `requestRedraw()`, which makes a feedback loop cheap by
    /// construction. Setting the button's image makes it report its appearance again, so
    /// redrawing on every report once looped forever and held a CPU core at 100%. Now an
    /// unchanged picture is never drawn twice, and requests are merged and rate-limited.
    private var redrawPending = false
    private var lastRedraw = Date.distantPast
    private var drawnKey: String?
    private(set) var redrawCount = 0
    private(set) var skippedRedraws = 0
    private var clickCount = 0
    /// Closes the dropdown on clicks in other apps, the menu bar included.
    private var outsideClickMonitor: Any?
    /// Pointer watchers that exist only while a revealed menu bar holds the focus
    /// the dropdown had. See `restoreFocusWhenMenuBarHides()`.
    private var menuBarMonitors: [Any] = []
    /// Invisible stand-in for the status item. See `anchorView(under:)`.
    private var anchorWindow: NSWindow?
    /// The app the dropdown opened over while Settings was open behind it, to hand
    /// focus back to on dismissal. See `closePopover(returningFocus:)`.
    private var appUnderPopover: NSRunningApplication?
    /// Set while the app activates for the dropdown, so `appDidBecomeActive` can
    /// tell that apart from Cmd-Tab.
    private var activatingForPopover = false
    /// Set while `closePopover` closes it, so `popoverShouldClose` can tell that
    /// apart from Esc.
    private var closingPopover = false

    override init() {
        super.init()
        guard let button = item.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let panel = PanelView(store: Store.shared) { [weak self] in
            self?.closePopover()
            SettingsWindow.show()
        }
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        // Semi-transient, not transient, so losing focus alone never closes it:
        // `appDidResignActive` makes that call, because an auto-hidden menu bar takes
        // focus just by appearing. Esc still closes it, and the monitor in
        // `togglePopover` handles clicks elsewhere.
        popover.behavior = .semitransient
        popover.animates = false
        popover.delegate = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)

        Store.shared.$accounts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.requestRedraw() }
            .store(in: &bag)
        // A failed refresh publishes no accounts, but the reading still ages: re-check it once
        // per refresh, so it dims even while cswap can't be read (#34). `redraw` skips it otherwise.
        Store.shared.$loading
            .removeDuplicates()
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.requestRedraw() }
            .store(in: &bag)
        Prefs.shared.onStyleChange = { [weak self] in self?.requestRedraw() }
        // Increase Contrast picks stronger usage colours (#63); `redraw` skips it if nothing changed.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.requestRedraw() }
        }
        // Not a reason to redraw by itself: `redraw` skips it unless light/dark changed.
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.requestRedraw() }
        }
        EnergyGuard.shared.start()
        requestRedraw()
        listenForTestCommands()
    }

    /// Lets a local test script drive the real UI: opening things only, nothing that
    /// changes an account. Accessibility on macOS 27 doesn't expose status items.
    private func listenForTestCommands() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(testCommand(_:)),
            name: Notification.Name("com.kevinabouhanna.ClaudeProfiles.test"), object: nil,
            suspensionBehavior: .deliverImmediately
        )
        // Addressed to this process alone, so the energy test never drives the copy in use.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(testCommand(_:)),
            name: Notification.Name("com.kevinabouhanna.ClaudeProfiles.test.\(getpid())"), object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func testCommand(_ note: Notification) {
        switch note.object as? String {
        case "settings": SettingsWindow.show()
        case "popover": if !popover.isShown { togglePopover() }
        case "close":
            closePopover()
            SettingsWindow.visibleWindow?.close()
        // Flips the button's appearance, the change that once started the redraw loop.
        case "appearance-dark": item.button?.appearance = NSAppearance(named: .darkAqua)
        case "appearance-light": item.button?.appearance = NSAppearance(named: .aqua)
        case "appearance-system": item.button?.appearance = nil
        case "counters":
            let guardState = EnergyGuard.shared
            let info = "redraws=\(redrawCount) skipped=\(skippedRedraws) refreshes=\(Store.shared.refreshCount) throttled=\(guardState.throttled) lastCPU=\(String(format: "%.2f", guardState.lastPercent)) peakCPU=\(String(format: "%.2f", guardState.peakPercent))\n"
            try? info.write(toFile: NSTemporaryDirectory() + "claude-profiles-counters-\(getpid()).txt", atomically: true, encoding: .utf8)
        case "status":
            let frame = item.button?.window?.frame ?? .zero
            let info = "frame=\(frame) image=\(item.button?.image?.size ?? .zero) visible=\(item.isVisible) popover=\(popover.isShown) popoverWindow=\(popover.contentViewController?.view.window?.frame ?? .zero) onScreen=\(popover.contentViewController?.view.window?.isVisible ?? false) clicks=\(clickCount) text=\(item.button?.toolTip ?? "")\n"
            try? info.write(toFile: NSTemporaryDirectory() + "claude-profiles-status.txt", atomically: true, encoding: .utf8)
        default: break
        }
    }

    /// The only way to ask for a redraw. Requests arriving together become one, and they're
    /// spaced at least `minimumInterval` apart: 0.25 s normally, 10 s if `EnergyGuard`
    /// has seen the app burning CPU.
    private func requestRedraw() {
        guard !redrawPending else { return }
        redrawPending = true
        let minimumInterval: TimeInterval = EnergyGuard.shared.throttled ? 10 : 0.25
        let delay = max(0, lastRedraw.addingTimeInterval(minimumInterval).timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.redrawPending = false
            self.lastRedraw = Date()
            self.redraw()
        }
    }

    private func redraw() {
        guard let button = item.button else { return }
        let style = Prefs.shared.style
        let account = Store.shared.activeAccount
        let dark = isDark(button)
        // Everything the picture depends on. The same key means the same image, so it
        // isn't drawn again; this is what ends a loop where drawing triggers a request.
        let key = [
            MenuBarImage.plainText(account, style), "\(style)", "\(dark)", "\(UsageColors.increaseContrast)",
            MenuBarImage.lookKey(account, style),  // colours, and old readings dimmed (#34)
            ModelLimits.hidden.sorted().joined(separator: ","),
        ].joined(separator: "|")
        guard key != drawnKey else {
            skippedRedraws += 1
            return
        }
        drawnKey = key
        redrawCount += 1
        if Prefs.shared.menuBarIsDark != dark { Prefs.shared.menuBarIsDark = dark }
        button.image = MenuBarImage.render(account, style, dark: dark, template: style.colorMode == .system)
        let text = MenuBarImage.plainText(account, style)
            + (MenuBarImage.showsOld(account, style) ? ", from an old reading" : "")
        button.toolTip = "Claude usage: \(text)"
        button.setAccessibilityLabel("Claude usage \(text)")
    }

    private func isDark(_ button: NSStatusBarButton) -> Bool {
        button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    @objc private func clicked() {
        clickCount += 1
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: Dropdown

    private func togglePopover() {
        if popover.isShown {
            closePopover(returningFocus: true)
            return
        }
        guard let button = item.button else { return }
        Store.shared.refresh()
        if !NSApp.isActive, SettingsWindow.visibleWindow != nil {
            appUnderPopover = NSWorkspace.shared.frontmostApplication
        }
        if let anchor = anchorView(under: button) {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        // An accessory app isn't active by default, so without this the dropdown
        // renders unfocused and swallows the first click.
        activateForPopover()
        clearInitialFocus()

        // A click on the status item itself is left to `clicked`, which toggles: with
        // an auto-hidden menu bar that click reaches this monitor too, and closing
        // here as well would have the same click reopen the dropdown.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.popover.isShown, !self.pointerIsOnStatusItem else { return }
                self.closePopover()
            }
        }
    }

    private var pointerIsOnStatusItem: Bool {
        guard let frame = item.button?.window?.frame else { return false }
        // `NSMouseInRect`, not `contains`: the top row of the item reports y == maxY,
        // which `contains` excludes.
        return NSMouseInRect(NSEvent.mouseLocation, frame, false)
    }

    /// Opens with nothing focused, so Refresh doesn't wear a focus ring. Tab still
    /// reaches it. Deferred a turn because SwiftUI assigns focus after the window shows.
    private func clearInitialFocus() {
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }

    /// An invisible window parked where the status item is, for the dropdown to anchor
    /// to. `NSPopover` re-anchors whenever its content size changes, and with an
    /// auto-hidden menu bar the status item is off screen by then, which throws the
    /// dropdown to the far left of the display. The item's position is read at click
    /// time, the one moment it's guaranteed to be on screen.
    private func anchorView(under button: NSStatusBarButton) -> NSView? {
        guard let itemWindow = button.window else { return nil }
        let rect = itemWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }

        let window = anchorWindow ?? {
            let w = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            // Above normal windows so the arrow isn't clipped; out of window lists so
            // it can't be cycled to.
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
            anchorWindow = w
            return w
        }()
        window.setFrame(rect, display: false)
        window.contentView = NSView(frame: NSRect(origin: .zero, size: rect.size))
        window.orderFrontRegardless()
        return window.contentView
    }

    /// Activates the app for the dropdown, leaving Settings where it was.
    ///
    /// The activation lands a moment after it's asked for, not during the call: on
    /// macOS 27.2 Settings came forward over the app in front of it just after the
    /// dropdown opened, though it had already been put back. So Settings stays off
    /// screen until `appDidBecomeActive` says the activation has happened.
    private func activateForPopover() {
        guard !NSApp.isActive else { return }
        activatingForPopover = true
        parkSettings()
        NSApp.activate(ignoringOtherApps: true)
        // macOS can turn the activation down, and then nothing else would bring
        // Settings back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.activatingForPopover else { return }
            self.activatingForPopover = false
            self.unparkSettings()
        }
    }

    /// Settings while it's off screen, with the window that was in front of it.
    private var parkedSettings: (window: NSWindow, inFront: Int)?

    /// Runs `change` without letting it bring Settings forward from behind another
    /// app's window. The dropdown closing while the app is active makes Settings
    /// key, which would.
    private func keepingSettingsInPlace(_ change: () -> Void) {
        parkSettings()
        change()
        unparkSettings()
    }

    /// Takes Settings off screen if another window covers it. Activating the app
    /// brings its main window forward; off screen at that moment, it's left alone.
    private func parkSettings() {
        guard parkedSettings == nil, let window = SettingsWindow.visibleWindow,
              window.attachedSheet == nil,
              let inFront = WindowStack.window(inFrontOf: window.windowNumber) else { return }
        window.orderOut(nil)
        parkedSettings = (window, inFront)
    }

    /// Puts Settings back below the window that was in front of it, unless it was
    /// shown in the meantime, by the dropdown's gear.
    private func unparkSettings() {
        guard let parked = parkedSettings else { return }
        parkedSettings = nil
        guard !parked.window.isVisible else { return }
        parked.window.order(.below, relativeTo: parked.inFront)
    }

    /// `returningFocus` is for a dismissal: Esc, or the status item clicked again. If
    /// it opened over another app with Settings behind, focus goes back to that app
    /// instead of to a window nobody can see.
    private func closePopover(returningFocus: Bool = false) {
        let returnTo = returningFocus && NSApp.isActive ? appUnderPopover : nil
        appUnderPopover = nil
        closingPopover = true
        if NSApp.isActive {
            keepingSettingsInPlace { popover.performClose(nil) }
        } else {
            popover.performClose(nil)
        }
        closingPopover = false
        returnTo?.activate(options: [])
    }

    /// Esc, which closes without going through `closePopover`. It's sent back through
    /// it, a turn later rather than from inside AppKit's own close.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard !closingPopover else { return true }
        DispatchQueue.main.async { [weak self] in self?.closePopover(returningFocus: true) }
        return false
    }

    /// Every way the dropdown closes ends here, so none can skip the cleanup.
    func popoverWillClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        stopWatchingMenuBar()
        anchorWindow?.orderOut(nil)
        AccountPickerState.shared.reset()  // opens on the active account next time
        Store.shared.clearActionProblem()
    }

    // MARK: Auto-hidden menu bar

    /// Decides whether losing focus closes the dropdown. An accessory app has no menu
    /// bar of its own, so when the pointer reveals a hidden one, macOS activates an app
    /// that has one. Losing focus with the pointer up in the menu bar is therefore the
    /// bar appearing, and the dropdown rides it out. Losing it anywhere else (Cmd-Tab,
    /// Spotlight, a notification) is a real switch and closes it. Clicks, menu bar
    /// clicks included, still close it through the outside-click monitor.
    @objc private func appDidResignActive() {
        guard popover.isShown else { return }
        if pointerIsInMenuBar {
            restoreFocusWhenMenuBarHides()
        } else {
            closePopover()
        }
    }

    /// Hands focus back once the pointer leaves the menu bar, or the next click in the
    /// dropdown would only activate the app. If the user has switched to another app in
    /// the meantime, the dropdown closes instead of taking focus back from it.
    private func restoreFocusWhenMenuBarHides() {
        guard menuBarMonitors.isEmpty else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let revealedFor = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pointerMoved = { [weak self] in
            guard let self, !self.pointerIsInMenuBar else { return }
            self.stopWatchingMenuBar()
            guard self.popover.isShown else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let switchedAway = revealedFor.map { $0 != ownPID && frontmost != $0 } ?? false
            if switchedAway {
                self.closePopover()
            } else {
                self.activateForPopover()
            }
        }
        // Both are needed: leaving over another app's window reaches only the global
        // monitor, and leaving straight down into the dropdown only the local one.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in pointerMoved() }) {
            menuBarMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            pointerMoved()
            return event
        }) {
            menuBarMonitors.append(local)
        }
    }

    /// Back to the app by Cmd-Tab or a click on Settings: Settings alone, with the
    /// dropdown closed if it rode out a switch away.
    @objc private func appDidBecomeActive() {
        guard !activatingForPopover else {
            activatingForPopover = false
            unparkSettings()
            return
        }
        guard let window = SettingsWindow.visibleWindow, NSApp.modalWindow == nil else { return }
        if popover.isShown { closePopover() }
        window.makeKeyAndOrderFront(nil)
    }

    private func stopWatchingMenuBar() {
        menuBarMonitors.forEach(NSEvent.removeMonitor)
        menuBarMonitors.removeAll()
    }

    /// Whether the pointer is up in the menu bar, whether or not it's showing.
    private var pointerIsInMenuBar: Bool {
        MenuBarStrip.contains(NSEvent.mouseLocation, screens: NSScreen.screens.map { screen in
            (screen.frame, MenuBarStrip.height(
                statusItemThickness: NSStatusBar.system.thickness,
                statusItemWindowHeight: item.button?.window?.frame.height,
                safeAreaTop: screen.safeAreaInsets.top))
        })
    }

    // MARK: Right-click menu

    private func showContextMenu() {
        // The outside-click monitor leaves status item clicks alone, so this would
        // otherwise open the menu over the dropdown.
        if popover.isShown { closePopover(returningFocus: true) }
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Profiles", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil  // keep left-click opening the dropdown
    }

    @objc private func openSettings() { SettingsWindow.show() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `scripts/energy-test.sh` runs a second copy with `-energyTest YES`. It shares this
        // Mac's settings, so it must leave the real copy's Auto-Switch process alone.
        let energyTest = UserDefaults.standard.bool(forKey: "energyTest")
        if !energyTest { Migration.fromClaudeUsageBar() }  // before anything reads settings
        NSApp.mainMenu = Self.makeMainMenu()
        if !energyTest { AutoSwitcher.shared.cleanUpOrphan() }
        status = StatusController()
        Store.shared.start()
        if !energyTest { AutoSwitcher.shared.sync() }
    }

    /// The Dock icon, there while Settings is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AutoSwitcher.shared.stop()
    }

    /// Shown while Settings is open and the app is in the Dock. Its key equivalents are
    /// also what make Cmd-V, Cmd-W and friends work in the Settings window.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "", action: nil, keyEquivalent: "")
        let app = NSMenu()
        app.addItem(withTitle: "About Claude Profiles", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        settings.target = NSApp.delegate
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Claude Profiles", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Claude Profiles", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = main.addItem(withTitle: "Window", action: nil, keyEquivalent: "")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        return main
    }

    @objc func showSettings() { SettingsWindow.show() }
}

/// This app used to be called Claude Usage Bar, under the bundle ID
/// `local.claude-usage-bar`. Settings, nicknames and the Auto-Switch PID live under the
/// bundle ID, so the first launch under the new one copies them across.
@MainActor
enum Migration {
    static let oldDomain = "local.claude-usage-bar"

    static func fromClaudeUsageBar() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromClaudeUsageBar") else { return }
        defaults.set(true, forKey: "migratedFromClaudeUsageBar")
        guard let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil && !key.hasPrefix("NS") {
            defaults.set(value, forKey: key)
        }
        // The old app was only ever run with Open at Login on, and that login item
        // belongs to the old bundle, so it's set up again for this one.
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
    }
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            let args = CommandLine.arguments
            if args.count > 1, args[1].hasPrefix("--") {
                _ = NSApplication.shared
                exit(Debug.run(Array(args.dropFirst())))
            }
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

// MARK: - Debug modes

/// Renders real views to PNGs and checks logic, without Screen Recording permission.
@MainActor
enum Debug {
    static func run(_ args: [String]) -> Int32 {
        switch args[0] {
        case "--snapshot-settings" where args.count == 3: return snapshotSettings(json: args[1], dir: args[2])
        case "--snapshot-titles" where args.count == 3: return snapshotTitles(json: args[1], dir: args[2])
        case "--snapshot-panel" where args.count == 3: return snapshotPanel(json: args[1], dir: args[2])
        case "--selftest" where args.count == 2: return selftest(json: args[1])
        default:
            print("usage: --snapshot-settings <list.json> <dir> | --snapshot-titles <list.json> <dir> | --snapshot-panel <list.json> <dir> | --selftest <list.json>")
            return 2
        }
    }

    /// `cswap list --json` output, and optionally what makes a snapshot the same on every
    /// run: `now`, the time the app takes as now (ISO 8601), and `defaults`, settings that
    /// stand in for this Mac's own for this run only (`accountNicknames`,
    /// `autoSwitchEnabled`, `hiddenModelLimits`…). Nothing is written to the real ones.
    private static func loadFixture(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("could not parse \(path)")
            return false
        }
        if let now = top["now"] as? String {
            guard let date = parseISO(now) else {
                print("\(path): now isn't an ISO 8601 date: \(now)")
                return false
            }
            clock = { date }
        }
        if let defaults = top["defaults"] as? [String: Any] {
            // The argument domain is read before the app's own and never saved.
            UserDefaults.standard.setVolatileDomain(defaults, forName: UserDefaults.argumentDomain)
        }
        guard Store.shared.load(data) else {
            print("could not parse \(path)")
            return false
        }
        return true
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func capture(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        FileManager.default.createFile(atPath: path, contents: rep.representation(using: .png, properties: [:]))
    }

    private static func snapshotSettings(json: String, dir: String) -> Int32 {
        guard loadFixture(json) else { return 1 }
        AutoConfig.shared.load()
        spin(1.5)
        let window = SettingsWindow.make()
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        for pane in Pane.allCases {
            SettingsUI.shared.pane = pane
            spin(0.8)
            capture(window.contentView?.superview ?? window.contentView!, to: "\(dir)/pane-\(pane.rawValue).png")
        }
        reportSidebar(window.contentView!)
        window.orderOut(nil)

        let flow = AddAccountFlow.shared
        let steps: [(String, () -> Void)] = [
            ("browser", { flow.step = .choose; flow.useToken = false }),
            ("token", { flow.step = .choose; flow.useToken = true }),
            ("waiting", { flow.step = .waitingForBrowser }),
            ("done", { flow.step = .finished("second@example.com") }),
        ]
        for (name, apply) in steps {
            apply()
            let host = NSHostingView(rootView: AddAccountSheet(flow: flow).background(Color(nsColor: .windowBackgroundColor)))
            let sheet = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 460, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            sheet.contentView = host
            sheet.setContentSize(host.fittingSize)
            sheet.orderFrontRegardless()
            spin(0.5)
            capture(host, to: "\(dir)/sheet-\(name).png")
            sheet.orderOut(nil)
        }
        return 0
    }

    /// Liquid Glass can't be captured this way, so check the sidebar's structure instead.
    private static func reportSidebar(_ root: NSView) {
        func walk(_ v: NSView) {
            if let table = v as? NSTableView {
                print("table: rows=\(table.numberOfRows) frame=\(table.frame) window=\(table.window != nil) hidden=\(table.isHiddenOrHasHiddenAncestor)")
                for row in 0..<table.numberOfRows {
                    let view = table.view(atColumn: 0, row: row, makeIfNecessary: true)
                    print("  row \(row): frame=\(view?.frame ?? .zero) \(view.map { String(describing: type(of: $0)) } ?? "nil") a11y=\(view?.accessibilityChildren()?.compactMap { ($0 as? NSAccessibilityElementProtocol) != nil ? ($0 as AnyObject).accessibilityLabel?() ?? nil : nil } ?? [])")
                }
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        print("toolbar: \(root.window?.toolbar != nil), title: \(root.window?.title ?? "")")
    }

    /// The dropdown on the active account, on each other account, just after a switch
    /// and during one. Draws only: nothing is switched.
    private static func snapshotPanel(json: String, dir: String) -> Int32 {
        guard loadFixture(json) else { return 1 }
        let state = AccountPickerState.shared
        let store = Store.shared
        func plain() { state.reset(); store.switchedAt = nil; store.switching = nil }
        var shots: [(String, () -> Void)] = [
            ("active", plain),
            ("switched", { plain(); store.switchedAt = clock().addingTimeInterval(1) }),
            ("switching", { plain(); store.switching = "Switching to \(store.accounts.last?.displayName ?? "")…" }),
        ]
        for account in store.accounts where account.active != true {
            shots.append(("account-\(account.number)", { plain(); state.viewing = account.number }))
        }
        for dark in [false, true] {
            for (name, apply) in shots {
                apply()
                let host = NSHostingView(rootView: PanelView(store: Store.shared).background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let holder = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 320, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
                holder.contentView = host
                holder.setContentSize(host.fittingSize)
                holder.orderFrontRegardless()
                spin(0.4)
                capture(host, to: "\(dir)/panel-\(name)-\(dark ? "dark" : "light").png")
                holder.orderOut(nil)
            }
        }
        plain()
        return 0
    }

    private static func snapshotTitles(json: String, dir: String) -> Int32 {
        guard loadFixture(json) else { return 1 }
        let account = Store.shared.activeAccount
        var variants: [(String, TitleStyle)] = [("default", TitleStyle())]
        var s = TitleStyle(); s.layout = .stacked; variants.append(("stacked", s))
        s = TitleStyle(); s.colorMode = .usage; variants.append(("usage", s))
        s = TitleStyle(); s.colorMode = .custom; s.sessionHex = "#FF2D92"; s.weeklyHex = "#00C7BE"
        variants.append(("custom", s))
        s = TitleStyle(); s.showLabels = true; s.showPercent = true; s.separator = "|"; variants.append(("labels", s))
        s = TitleStyle(); s.layout = .stacked; s.showLabels = true; s.showName = true; s.colorMode = .usage; variants.append(("stacked-labels-name", s))
        s = TitleStyle(); s.showModelLimits = true; s.weight = .bold; s.size = .large; variants.append(("large-bold-models", s))

        for (name, style) in variants {
            for dark in [false, true] {
                let image = MenuBarImage.render(account, style, dark: dark, template: false)
                let canvas = NSView(frame: NSRect(x: 0, y: 0, width: image.size.width + 24, height: 28))
                let bg = NSHostingView(rootView:
                    Image(nsImage: image)
                        .frame(width: image.size.width + 24, height: 28)
                        .background(dark ? Color(white: 0.16) : Color(white: 0.92))
                )
                bg.frame = canvas.bounds
                canvas.addSubview(bg)
                let holder = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: canvas.frame.width, height: 28), styleMask: .borderless, backing: .buffered, defer: false)
                holder.contentView = canvas
                holder.orderFrontRegardless()
                spin(0.1)
                capture(canvas, to: "\(dir)/title-\(name)-\(dark ? "dark" : "light").png")
                holder.orderOut(nil)
            }
            print("\(name): \(MenuBarImage.plainText(account, style))")
        }
        return 0
    }

    /// WCAG contrast between two colours, 1...21: 4.5 is the least for readable text.
    private static func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ c: NSColor) -> Double {
            guard let s = c.usingColorSpace(.sRGB) else { return 0 }
            func lin(_ v: CGFloat) -> Double { v <= 0.04045 ? Double(v) / 12.92 : pow((Double(v) + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func selftest(json: String) -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok    " : "FAIL  ") + name)
            if !ok { failures += 1 }
        }
        guard loadFixture(json) else { return 1 }
        let account = Store.shared.activeAccount

        // Menu bar text
        check("default is bare numbers", MenuBarImage.plainText(account, TitleStyle()).range(of: #"^\d+ · \d+$"#, options: .regularExpression) != nil)
        var s = TitleStyle(); s.showPercent = true
        check("percent sign is optional", MenuBarImage.plainText(account, s).contains("%"))
        s = TitleStyle(); s.content = .session
        check("session only has one number", !MenuBarImage.plainText(account, s).contains("·"))
        s = TitleStyle(); s.showRemaining = true
        let used = account?.session?.display ?? 0
        check("remaining inverts", MenuBarImage.plainText(account, s).hasPrefix("\(100 - used) "))
        s = TitleStyle(); s.showLabels = true
        check("labels", MenuBarImage.plainText(account, s).contains("5h ") && MenuBarImage.plainText(account, s).contains("7d "))
        check("no account shows dashes", MenuBarImage.plainText(nil, TitleStyle()) == "– · –")

        // Colors and images
        check("hex round trip", hexString(nsColor(hex: "#FF2D92")) == "#FF2D92")
        check("system color is a template", MenuBarImage.render(account, TitleStyle(), dark: true, template: true).isTemplate)
        s = TitleStyle(); s.colorMode = .custom
        check("custom color is not a template", !MenuBarImage.render(account, s, dark: true, template: false).isTemplate)
        s = TitleStyle(); s.layout = .stacked
        let image = MenuBarImage.render(account, s, dark: true, template: false)
        check("stacked fits the bar", image.size.height <= 22 && image.size.width > 0)
        // #63: readable on the darkest light bar and the lightest dark bar macOS shows.
        let severities: [Window.Severity] = [.fine, .warning, .critical]
        func readable(dark: Bool, high: Bool, on bar: String, at least: Double) -> Bool {
            severities.allSatisfy { contrastRatio(UsageColors.color($0, dark: dark, highContrast: high), nsColor(hex: bar)) >= least }
        }
        check("usage colours readable on a light bar", readable(dark: false, high: false, on: "#EBEBEB", at: 4.5))
        check("usage colours readable on a dark bar", readable(dark: true, high: false, on: "#2A2A2A", at: 4.5))
        check("increase contrast is stronger", readable(dark: false, high: true, on: "#EBEBEB", at: 7)
            && readable(dark: true, high: true, on: "#1E1E1E", at: 7))
        check("the dropdown uses the menu bar's colours", severities.allSatisfy { s in
            [false, true].allSatisfy { dark in
                guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return false }
                var shown = NSColor.clear
                appearance.performAsCurrentDrawingAppearance {
                    shown = NSColor(Palette.tint(s)).usingColorSpace(.sRGB) ?? .clear
                }
                let menuBar = UsageColors.color(s, dark: dark, highContrast: UsageColors.increaseContrast)
                return hexString(shown) == hexString(menuBar)
            }
        })

        // Pace
        let now = Date()
        func raw(_ pct: Double, resetIn: TimeInterval) -> RawWindow? {
            let f = ISO8601DateFormatter()
            let data = try? JSONSerialization.data(withJSONObject: ["pct": pct, "resetsAt": f.string(from: now.addingTimeInterval(resetIn))])
            return data.flatMap { try? JSONDecoder().decode(RawWindow.self, from: $0) }
        }
        let over = Window(raw: raw(70, resetIn: 2.5 * 3600), period: fiveHourPeriod, fetchedAt: now, now: now)
        check("pace tick at 50%", abs((over.pacePct ?? 0) - 50) < 0.5)
        check("over pace runs out", over.forecast?.contains("over pace") == true)
        let passed = Window(raw: raw(50, resetIn: -60), period: fiveHourPeriod, fetchedAt: now, now: now)
        check("passed 5h window reads 0", passed.pct == 0 && passed.resetsAt == nil)
        let week = Window(raw: raw(50, resetIn: -60), period: weekPeriod, fetchedAt: now, now: now)
        check("passed weekly window rolls forward", week.pct == 0 && (week.resetsAt ?? now) > now)

        // #20: colours say how close you are to running out. `gone` is the share of the window passed.
        func session(_ pct: Double, gone: Double) -> Window {
            Window(raw: raw(pct, resetIn: (1 - gone) * fiveHourPeriod), period: fiveHourPeriod, fetchedAt: now, now: now)
        }
        func weekly(_ pct: Double, gone: Double) -> Window {
            Window(raw: raw(pct, resetIn: (1 - gone) * weekPeriod), period: weekPeriod, fetchedAt: now, now: now)
        }
        check("session 48% is orange, however fast", session(48, gone: 0.31).severity == .warning)
        check("session 39% is green, however fast", session(39, gone: 0.05).severity == .fine)
        check("session 80% is red, even under pace", session(80, gone: 0.9).severity == .critical)
        check("weekly on track to last is green", weekly(71, gone: 0.74).severity == .fine)
        check("weekly out a few hours early is orange", weekly(82, gone: 0.78).severity == .warning)
        check("weekly out days early is red", weekly(50, gone: 0.3).severity == .critical)
        check("weekly 90% is red", weekly(90, gone: 0.95).severity == .critical)
        let dayOne = weekly(6, gone: 0.04)
        check("weekly 6% on day one is green, with no sentence", dayOne.severity == .fine && dayOne.forecast == nil)
        check("on pace says it lasts about until the reset",
              session(20, gone: 0.199).forecast == "On pace · runs out about when it resets")
        check("weekly 85% in the first hours is red", weekly(85, gone: 0.036).severity == .critical)
        let nearlyOnPace = weekly(10, gone: 0.0955)  // runs out ~7.5 h (4.5%) early
        check("a week running out hours early says when, in orange",
              nearlyOnPace.severity == .warning && nearlyOnPace.forecast?.contains("runs out about") == false)
        let onPace = weekly(50.01, gone: 0.5)  // runs out seconds early
        check("a week on pace stays green", onPace.severity == .fine && onPace.forecast?.contains("about when it resets") == true)
        check("a week out exactly a day early is red", Window.weeklySeverity(50, early: 86400) == .critical)

        // #34: an old reading says so. The 13 Nov case: 87% at 42% of the window, read at 10:37.
        func reading(_ pct: Double = 87, gone: Double = 0.42, age: TimeInterval) -> Window {
            Window(raw: raw(pct, resetIn: (1 - gone) * fiveHourPeriod - age), period: fiveHourPeriod,
                   fetchedAt: now.addingTimeInterval(-age), now: now)
        }
        check("a reading 15 min old is old", reading(age: 900).checkedAt == now.addingTimeInterval(-900))
        check("a reading 2 min old isn't", !reading(age: 120).isOld)
        check("old means over 10 minutes", staleLimit == 600 && !reading(age: 590).isOld && reading(age: 610).isOld)
        check("an old forecast's passed run-out says so", reading(age: 1800).forecast == "May have run out by now")
        // 95% at half the window runs out 8 minutes after the reading: 9 minutes on, it has passed.
        let recent = reading(95, gone: 0.5, age: 540)
        check("a recent reading's passed run-out says so too", !recent.isOld && recent.forecast == "May have run out by now")
        check("a fresh forecast still gives the time", reading(age: 60).forecast?.contains("% over pace · runs out ") == true)
        func weekRow(fetchedAgo: TimeInterval) -> Account? {
            let f = ISO8601DateFormatter()
            let json = #"{"number":7,"active":true,"usageStatus":"ok","usage":{"fiveHour":null,"sevenDay":{"pct":30,"resetsAt":"\#(f.string(from: clock().addingTimeInterval(3 * 86400)))"}},"usageFetchedAt":"\#(f.string(from: clock().addingTimeInterval(-fetchedAgo)))"}"#
            return try? JSONDecoder().decode(Account.self, from: Data(json.utf8))
        }
        if let fresh = weekRow(fetchedAgo: 30), let stale = weekRow(fetchedAgo: 3 * 3600),
           let staler = weekRow(fetchedAgo: 3 * 3600 + 300) {
            var usage = TitleStyle(); usage.colorMode = .usage; usage.content = .weekly
            let freshImage = MenuBarImage.render(fresh, usage, dark: true, template: false).tiffRepresentation
            let staleImage = MenuBarImage.render(stale, usage, dark: true, template: false).tiffRepresentation
            check("an old reading draws dimmed in the menu bar", freshImage != staleImage && MenuBarImage.showsOld(stale, usage))
            // The redraw key and plain text change when it turns old, then not as it ages.
            func key(_ a: Account) -> String { MenuBarImage.lookKey(a, usage) + MenuBarImage.plainText(a, usage) }
            check("turning old changes the redraw key once", key(fresh) != key(stale) && key(stale) == key(staler))
        } else {
            check("old reading fixtures decode", false)
        }

        // A passing token expiry keeps the last reading
        func row(_ json: String) -> Account? { try? JSONDecoder().decode(Account.self, from: Data(json.utf8)) }
        let fetched = ISO8601DateFormatter().string(from: now.addingTimeInterval(-600))
        let store = Store()
        let good = row(#"{"number":9,"email":"t@example.com","usageStatus":"ok","usage":{"fiveHour":{"pct":42}},"usageFetchedAt":"\#(fetched)"}"#)
        let expired = row(#"{"number":9,"email":"t@example.com","usageStatus":"token_expired"}"#)
        let relogin = row(#"{"number":9,"email":"t@example.com","usageStatus":"relogin_required"}"#)
        if let good, let expired, let relogin {
            _ = store.carryOver(good, now: now)
            let carried = store.carryOver(expired, now: now)
            check("expired token keeps the last reading", carried.carriedOver && carried.session?.display == 42)
            check("expired token explains itself", carried.statusMessage?.contains("clears on its own") == true)
            check("relogin is not carried over", !store.carryOver(relogin, now: now).carriedOver)
            check("old readings are dropped", !store.carryOver(expired, now: now.addingTimeInterval(carryOverLimit)).carriedOver)
        } else {
            check("usage fixtures decode", false)
        }
        check("age text", ageText(since: now.addingTimeInterval(-720), now: now) == "12 min ago")

        // Looking at another account
        let two = [row(#"{"number":1,"active":true}"#), row(#"{"number":2,"active":false}"#)].compactMap { $0 }
        check("cards show the active account by default", AccountPickerState.viewed(in: two, viewing: nil)?.number == 1)
        check("cards show the account picked", AccountPickerState.viewed(in: two, viewing: 2)?.number == 2)
        check("a picked account that's gone falls back", AccountPickerState.viewed(in: two, viewing: 9)?.number == 1)

        // Account tabs
        let five = [1, 2, 3, 4, 5]
        check("three accounts all get tabs", AccountPickerState.tabs([1, 2, 3], active: 3, viewed: 2) == [1, 2, 3])
        check("more accounts show the first three", AccountPickerState.tabs(five, active: 1, viewed: 1) == [1, 2, 3])
        check("the viewed account always has a tab", AccountPickerState.tabs(five, active: 1, viewed: 5) == [1, 2, 5])
        check("the active account always has a tab", AccountPickerState.tabs(five, active: 5, viewed: 1) == [1, 2, 5])
        check("active and viewed both keep tabs", AccountPickerState.tabs(five, active: 4, viewed: 5) == [1, 4, 5])
        check("tabs keep list order", AccountPickerState.tabs([5, 3, 1, 2], active: 1, viewed: 2) == [5, 1, 2])

        // Per-model limits
        let fable = row(#"{"number":3,"usage":{"scoped":[{"pct":40,"name":"Fable"},{"pct":10,"name":"Other"}]}}"#)
        if let fable {
            check("Fable is hidden by default", ModelLimits.hiddenByDefault.contains("Fable"))
            check("hidden limits are left out", ModelLimits.visible(fable, hiding: ["Fable"]).map(\.name) == ["Other"])
            check("shown limits stay", ModelLimits.visible(fable, hiding: []).count == 2)
            check("known models include hidden ones", ModelLimits.known(in: [fable]).contains("Fable"))
        } else {
            check("model limit fixture decodes", false)
        }

        // History parsing
        let log = "2026-06-27 02:06:11,123 - claude-swap - INFO - Switched from account 3 to 1\nnoise\n2026-06-28 09:00:00,000 - x - INFO - Switched from account 1 to 2"
        let events = SwitchLog.parse(log)
        check("history newest first", events.first?.to == 2 && events.first?.when == "2026-06-28 09:00")
        check("history skips noise", events.count == 2)

        // A switch cswap refuses for a session login, in plain words (#61)
        let refusal = "Error: Account-1 (me@example.com) has a live session-mode Claude instance (PID 62487, 62488), and its session profile's credential has rotated past the stored backup: the backup is a consumed generation."
        let parsed = SwitchRefusal.parse(refusal)
        check("refusal gives the account and processes", parsed?.account == 1 && parsed?.pids == [62487, 62488])
        let rotated = "Error: Account-2 (me@example.com) has a session profile whose credential has rotated past the stored backup, and it could not be adopted."
        check("refusal without processes is found", SwitchRefusal.parse(rotated)?.pids == [])
        check("other failures aren't explained", SwitchRefusal.parse("Error: session profile directory not found for Account-2") == nil)
        let tony = [SwitchRefusal.Helper(pid: 62487, app: "Home Control", background: true),
                    SwitchRefusal.Helper(pid: 62488, app: "Home Control", background: true)]
        let said = parsed?.explain(names: [1: "Personal"], helpers: tony)
        check("refusal names the account and the app", said == "Couldn't switch to Personal: Home Control is using Personal's own sign-in, which is newer than the saved one. Quit Home Control, then switch again.")
        let twoApps = parsed?.explain(names: [1: "Personal"], helpers: [tony[0], SwitchRefusal.Helper(pid: 9, app: "Terminal", background: false)])
        check("two apps are using it", twoApps?.contains("Home Control and Terminal are using Personal's") == true)
        check("refusal without an app names the processes", parsed?.explain(names: [:], helpers: [])
              .contains("Couldn't switch to Account 1: Claude (processes 62487, 62488) are using Account 1's") == true)
        check("app name from its executable", SwitchRefusal.appName(fromPath: "/Applications/Home Control.app/Contents/MacOS/Home Control") == "Home Control")
        check("no app for a bare tool", SwitchRefusal.appName(fromPath: "/Users/me/.local/bin/claude") == nil)
        let table = SwitchRefusal.processTable("""
                1     0 /sbin/launchd
              500     1 /Applications/Home Control.app/Contents/MacOS/Home Control
              600   500 /Users/me/.local/bin/cswap
              700   600 /Users/me/.local/bin/claude
              800     1 /Users/me/.local/bin/claude
            """)
        check("a process's app is found up its parents", SwitchRefusal.app(of: 700, in: table) == "Home Control")
        check("a process outside any app has none", SwitchRefusal.app(of: 800, in: table) == nil)
        check("an app's claude -p is a background helper", SwitchRefusal.isBackground(tty: "??", args: "/Users/me/.local/bin/claude -p --input-format stream-json"))
        check("a terminal's claude is not", !SwitchRefusal.isBackground(tty: "ttys001", args: "/Users/me/.local/bin/claude -p"))
        check("an interactive claude is not", !SwitchRefusal.isBackground(tty: "??", args: "/Users/me/.local/bin/claude --resume x"))
        check("print mode is seen past a path with spaces", SwitchRefusal.isBackground(tty: "??", args: "/Applications/My App.app/Contents/Resources/claude --output-format stream-json -p"))
        check("the refused account, not another named before it",
              SwitchRefusal.parse("Current: Account-2 (w@x) [Work]\nError: Account-1 (me@example.com) has a live session-mode Claude instance (PID 5).")?.account == 1)
        let runner = SwitchRefusal.Helper(pid: 62488, app: "Some Agent Runner", background: true)
        check("Home Control's helpers are stopped", parsed.map { SwitchRefusal.canStop($0, tony) } == true)
        check("another app's Claude is never stopped", parsed.map { SwitchRefusal.canStop($0, [tony[0], runner]) } == false)
        check("a terminal Claude is never stopped",
              parsed.map { SwitchRefusal.canStop($0, [SwitchRefusal.Helper(pid: 1, app: "Home Control", background: false)]) } == false)
        check("helpers already gone: switch again", parsed.map { SwitchRefusal.canStop($0, []) } == true)
        check("no processes named: nothing to stop", SwitchRefusal.parse(rotated).map { SwitchRefusal.canStop($0, []) } == false)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        if (try? sleeper.run()) != nil {
            let pid = sleeper.processIdentifier
            check("a running process isn't gone", !SwitchRefusal.gone(pid))
            check("stopping a helper waits until it has gone", SwitchRefusal.stop([pid], limit: 5))
            sleeper.waitUntilExit()
        } else {
            check("sleep starts", false)
        }
        let shownBefore = store.problem
        store.report("Couldn't switch.", detail: "")
        check("a failed action's message isn't the refresh's", store.actionProblem == "Couldn't switch." && store.problem == shownBefore)
        store.clearActionProblem()

        // Menu bar strip
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let screens = [(frame: screen, menuBarHeight: CGFloat(30))]
        check("menu bar height takes the tallest reading", MenuBarStrip.height(statusItemThickness: 22, statusItemWindowHeight: 30, safeAreaTop: 0) == 30)
        check("pointer at the top edge is in the menu bar", MenuBarStrip.contains(CGPoint(x: 500, y: 800), screens: screens))
        check("pointer below the strip is not", !MenuBarStrip.contains(CGPoint(x: 500, y: 769), screens: screens))
        let stack = [(number: 1, layer: 25), (number: 2, layer: 0), (number: 3, layer: 0)]
        // Account order
        func reordered(_ slots: [Int], _ order: [Int]) -> [Int] {
            var at = Dictionary(uniqueKeysWithValues: slots.map { ($0, $0) })  // slot -> account
            for step in SlotOrder.moves(slots: slots, order: order) {
                (at[step.from], at[step.to]) = (at[step.to], at[step.from])
            }
            return slots.sorted().map { at[$0]! }
        }
        check("reorder puts accounts in the dragged order", reordered([1, 2, 3, 4], [3, 1, 4, 2]) == [3, 1, 4, 2])
        check("reorder keeps sparse slot numbers", reordered([2, 5, 9], [9, 2, 5]) == [9, 2, 5])
        check("unchanged order moves nothing", SlotOrder.moves(slots: [1, 2, 3], order: [1, 2, 3]).isEmpty)
        check("window in front skips other layers", WindowStack.window(inFrontOf: 3, in: stack) == 2 && WindowStack.window(inFrontOf: 2, in: stack) == nil)

        // Secrets
        let masked = CLI.Result(ok: false, out: Data("bad token sk-ant-oat01-abc_DEF-123 rejected".utf8)).text
        check("tokens are masked in messages", !masked.contains("abc_DEF") && masked.contains("[token]"))

        // CLI plumbing
        check("cswap found", CLI.cswap != nil)
        check("claude found", CLI.claude != nil)
        check("stdin reaches the child", CLI.run("/bin/cat", [], stdin: "hello\n").text == "hello")
        let config = AutoConfig.shared
        config.load()
        spin(2.5)
        check("reads autoswitch config", config.number("autoswitch.threshold", default: -1) >= 50)
        check("reads config strings", !config.string("autoswitch.strategy", default: "").isEmpty)

        // Auto-switch process (dry run: can never switch)
        // Only its own process counts: the installed app may be running one too, and
        // its PID record, in the same settings, is put back afterwards.
        let auto = AutoSwitcher.shared
        let savedPID = UserDefaults.standard.object(forKey: "autoSwitchPID")
        auto.extraArgs = ["--dry-run"]
        auto.start()
        spin(3)
        let pid = auto.pid ?? 0
        check("auto-switch runs", auto.running && pid > 0)
        auto.stop()
        spin(1.5)
        check("auto-switch stops", !auto.running && pid > 0 && kill(pid, 0) != 0)
        UserDefaults.standard.set(savedPID, forKey: "autoSwitchPID")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
