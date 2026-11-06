// User preferences, and drawing the numbers in the menu bar.
import AppKit
import SwiftUI

enum TitleContent: String, Codable, CaseIterable, Identifiable {
    case both, session, weekly, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .both: return "Session and Weekly"
        case .session: return "Session Only"
        case .weekly: return "Weekly Only"
        case .none: return "Icon Only"
        }
    }
}

enum TitleLayout: String, Codable, CaseIterable, Identifiable {
    case inline, stacked
    var id: String { rawValue }
    var label: String { self == .inline ? "Side by Side" : "Stacked" }
}

enum TitleColorMode: String, Codable, CaseIterable, Identifiable {
    case system, usage, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Match Menu Bar"
        case .usage: return "By Usage"
        case .custom: return "Custom"
        }
    }
}

enum TitleSize: String, Codable, CaseIterable, Identifiable {
    case small, regular, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var inlinePoints: CGFloat { self == .small ? 11 : (self == .regular ? 13 : 14) }
    var stackedPoints: CGFloat { self == .small ? 9 : (self == .regular ? 10 : 10.5) }
}

enum TitleWeight: String, Codable, CaseIterable, Identifiable {
    case regular, medium, bold
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var font: NSFont.Weight { self == .regular ? .regular : (self == .medium ? .medium : .bold) }
}

struct TitleStyle: Codable, Equatable {
    var content: TitleContent = .both
    var layout: TitleLayout = .inline
    var separator = "·"
    var weeklyFirst = false
    var showLabels = false
    var showPercent = false
    var showRemaining = false
    var showName = false
    var showModelLimits = false
    var colorMode: TitleColorMode = .system
    /// Custom colors on a dark menu bar.
    var sessionHex = "#34C759"
    var weeklyHex = "#0A84FF"
    /// Custom colors on a light menu bar. Optional so settings saved before these
    /// existed still load; nil uses the dark color, as before.
    var sessionHexLight: String? = "#248A3D"
    var weeklyHexLight: String? = "#0062CC"

    func customHex(session: Bool, dark: Bool) -> String {
        let darkHex = session ? sessionHex : weeklyHex
        return dark ? darkHex : (session ? sessionHexLight : weeklyHexLight) ?? darkHex
    }
    var size: TitleSize = .regular
    var weight: TitleWeight = .regular
}

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private static let defaults = UserDefaults.standard

    /// Set by the status item, which redraws whenever the style changes.
    var onStyleChange: (() -> Void)?

    @Published var style: TitleStyle {
        didSet {
            Self.defaults.set(try? JSONEncoder().encode(style), forKey: "titleStyle")
            onStyleChange?()
        }
    }
    /// Whether the menu bar itself is drawn dark, which follows the wallpaper as well as
    /// the system setting. Kept current by the status item so the Settings preview matches.
    @Published var menuBarIsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    @Published var refreshInterval: Int {
        didSet {
            Self.defaults.set(refreshInterval, forKey: "refreshInterval")
            Store.shared.rescheduleTimer()
        }
    }
    @Published var notifyOnSwitch: Bool {
        didSet { Self.defaults.set(notifyOnSwitch, forKey: "notifyOnSwitch") }
    }
    @Published var autoSwitchEnabled: Bool {
        didSet {
            Self.defaults.set(autoSwitchEnabled, forKey: "autoSwitchEnabled")
            AutoSwitcher.shared.sync()
        }
    }

    private init() {
        let d = Self.defaults
        style = d.data(forKey: "titleStyle").flatMap { try? JSONDecoder().decode(TitleStyle.self, from: $0) } ?? TitleStyle()
        let interval = d.integer(forKey: "refreshInterval")
        refreshInterval = interval > 0 ? interval : 60
        notifyOnSwitch = d.object(forKey: "notifyOnSwitch") as? Bool ?? true
        autoSwitchEnabled = d.bool(forKey: "autoSwitchEnabled")
    }
}

func nsColor(hex: String) -> NSColor {
    let v = Int(hex.dropFirst(), radix: 16) ?? 0
    return NSColor(
        srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
        blue: CGFloat(v & 255) / 255, alpha: 1
    )
}

func hexString(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB) ?? .white
    return String(
        format: "#%02X%02X%02X",
        Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())
    )
}

enum MenuBarImage {
    private enum Role { case session, weekly }

    private struct Segment {
        let label: String
        let value: String
        let role: Role
        let severity: Window.Severity
    }

    private static func segments(_ account: Account?, _ style: TitleStyle) -> [Segment] {
        func make(_ label: String, _ window: Window?, _ role: Role) -> Segment {
            var value = "–"
            if let window {
                let n = style.showRemaining ? max(0, 100 - window.display) : window.display
                value = String(n) + (style.showPercent ? "%" : "")
            }
            return Segment(label: label, value: value, role: role, severity: window?.severity ?? .fine)
        }
        var out: [Segment] = []
        let session = make("5h", account?.session, .session)
        let weekly = make("7d", account?.weekly, .weekly)
        switch style.content {
        case .both: out = style.weeklyFirst ? [weekly, session] : [session, weekly]
        case .session: out = [session]
        case .weekly: out = [weekly]
        case .none: return []
        }
        if style.showModelLimits, let account {
            for raw in account.usage?.scoped ?? [] {
                let window = Window(raw: raw, period: weekPeriod, fetchedAt: account.fetchedDate)
                out.append(make(String((raw.name ?? "M").prefix(1)), window, .weekly))
            }
        }
        return out
    }

    private static func shortName(_ account: Account?) -> String? {
        guard let name = account?.displayName else { return nil }
        let local = name.components(separatedBy: "@").first ?? name
        return local.count > 12 ? String(local.prefix(11)) + "…" : local
    }

    /// What the menu bar reads as, for accessibility, tooltips and tests.
    static func plainText(_ account: Account?, _ style: TitleStyle) -> String {
        let parts = segments(account, style).map { (style.showLabels ? "\($0.label) " : "") + $0.value }
        let sep = style.separator.isEmpty ? " " : " \(style.separator) "
        let name = style.showName ? shortName(account).map { "\($0) " } ?? "" : ""
        return name + parts.joined(separator: sep)
    }

    /// `template` lets macOS tint the image to suit the menu bar. Colored numbers
    /// can't be a template, so they draw for the known bar appearance instead.
    static func render(_ account: Account?, _ style: TitleStyle, dark: Bool, template: Bool) -> NSImage {
        guard style.content != .none else {
            let icon = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Claude usage")
                ?? NSImage()
            icon.isTemplate = template
            return icon
        }
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        var image = NSImage()
        appearance.performAsCurrentDrawingAppearance {
            image = draw(account, style, dark: dark, template: template)
        }
        image.isTemplate = template
        return image
    }

    private static func draw(_ account: Account?, _ style: TitleStyle, dark: Bool, template: Bool) -> NSImage {
        let stacked = style.layout == .stacked && segments(account, style).count > 1
        let points = stacked ? style.size.stackedPoints : style.size.inlinePoints
        let font = NSFont.monospacedDigitSystemFont(ofSize: points, weight: style.weight.font)
        let primary: NSColor = template ? .black : (dark ? .white : .black)
        let secondary = primary.withAlphaComponent(0.55)

        func color(_ s: Segment) -> NSColor {
            guard !template else { return primary }
            switch style.colorMode {
            case .system: return primary
            case .custom: return nsColor(hex: style.customHex(session: s.role == .session, dark: dark))
            case .usage:
                switch s.severity {
                case .fine: return .systemGreen
                case .overPace: return .systemOrange
                case .critical: return .systemRed
                }
            }
        }
        func text(_ string: String, _ c: NSColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: c])
        }
        func line(_ segs: [Segment]) -> NSAttributedString {
            let out = NSMutableAttributedString()
            for (i, s) in segs.enumerated() {
                if i > 0 {
                    out.append(text(style.separator.isEmpty ? " " : " \(style.separator) ", secondary))
                }
                if style.showLabels { out.append(text("\(s.label) ", secondary)) }
                out.append(text(s.value, color(s)))
            }
            return out
        }

        let segs = segments(account, style)
        // Stacked: session on top, everything else below (a third row wouldn't fit the bar).
        let lines = stacked ? [line([segs[0]]), line(Array(segs.dropFirst()))] : [line(segs)]
        let name = style.showName ? shortName(account).map { text($0, secondary) } : nil

        let nameWidth = name.map { ceil($0.size().width) + 5 } ?? 0
        let linesWidth = ceil(lines.map { $0.size().width }.max() ?? 0)
        let height: CGFloat = 22
        let size = NSSize(width: max(1, nameWidth + linesWidth), height: height)

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage() }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)  // a bitmap context draws 1 point per pixel otherwise
        let lineHeight = ceil(font.ascender - font.descender)
        name?.draw(at: NSPoint(x: 0, y: (height - lineHeight) / 2))
        if lines.count == 1 {
            lines[0].draw(at: NSPoint(x: nameWidth, y: (height - lineHeight) / 2))
        } else {
            let step = points + 0.5
            for (i, l) in lines.enumerated() {
                let x = nameWidth + (linesWidth - l.size().width) / 2
                let y = (height - lineHeight) / 2 + (i == 0 ? step / 2 : -step / 2)
                l.draw(at: NSPoint(x: x, y: y))
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
