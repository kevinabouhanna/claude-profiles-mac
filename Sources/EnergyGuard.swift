// The app watching its own CPU use, so a bug that slips past the tests can't drain a battery.
import Foundation
import os

/// Every 30 seconds, checks how much CPU this process used since the last check. Two checks
/// in a row over `limit` (sustained use for a minute) trip it, once per launch:
/// it logs a fault with what was busy, slows redraws to one per 10 seconds, and
/// posts a notification asking for a report. Child processes (cswap) aren't counted.
@MainActor
final class EnergyGuard {
    static let shared = EnergyGuard()

    /// Percent of one core. The app idles around 0.1%.
    let limit = 20.0
    private(set) var throttled = false
    private(set) var lastPercent = 0.0
    private(set) var peakPercent = 0.0
    private var overLimit = 0
    private var timer: Timer?
    private var lastCPU = EnergyGuard.cpuSeconds()
    private var lastWall = Date()
    private let log = Logger(subsystem: "com.kevinabouhanna.ClaudeProfiles", category: "energy")

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor in EnergyGuard.shared.check() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        let cpu = Self.cpuSeconds(), wall = Date()
        let elapsed = wall.timeIntervalSince(lastWall)
        guard elapsed > 1 else { return }
        lastPercent = (cpu - lastCPU) / elapsed * 100
        peakPercent = max(peakPercent, lastPercent)
        lastCPU = cpu
        lastWall = wall
        overLimit = lastPercent > limit ? overLimit + 1 : 0
        guard overLimit >= 2, !throttled else { return }
        throttled = true
        log.fault("""
            Sustained CPU use: \(self.lastPercent, format: .fixed(precision: 1))% of a core. \
            Slowing down. refreshes=\(Store.shared.refreshCount)
            """)
        Notifier.post(
            "Claude Profiles is using more energy than expected",
            "It has slowed itself down. Please report this at github.com/kevinabouhanna/claude-profiles-mac/issues."
        )
    }

    /// User and system CPU time this process has used, in seconds.
    nonisolated static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
