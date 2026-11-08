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
        Prefs.shared.onStyleChange = { [weak self] in self?.requestRedraw() }
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
            MenuBarImage.plainText(account, style), "\(style)", "\(dark)",
            "\(account?.session?.severity as Any)", "\(account?.weekly?.severity as Any)",
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
        AccountPickerState.shared.open = false  // opens on the active account next time
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
        case "--selftest" where args.count == 2: return selftest(json: args[1])
        default:
            print("usage: --snapshot-settings <list.json> <dir> | --snapshot-titles <list.json> <dir> | --selftest <list.json>")
            return 2
        }
    }

    private static func loadFixture(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path), Store.shared.load(data) else {
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

        // History parsing
        let log = "2026-06-27 02:06:11,123 - claude-swap - INFO - Switched from account 3 to 1\nnoise\n2026-06-28 09:00:00,000 - x - INFO - Switched from account 1 to 2"
        let events = SwitchLog.parse(log)
        check("history newest first", events.first?.to == 2 && events.first?.when == "2026-06-28 09:00")
        check("history skips noise", events.count == 2)

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
