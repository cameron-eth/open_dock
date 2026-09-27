import AppKit
import CoreAudio
import Darwin

/// Watches for signs an app wants your attention or is doing something:
///  • badge  — the unread count macOS's own Dock shows (Mail, Slack, Messages…)
///  • audio  — the app is playing sound
///  • busy   — the app is using a lot of CPU (building, exporting, rendering)
/// Everything is sampled on a background queue.
final class Activity {
    static let shared = Activity()
    private let queue = DispatchQueue(label: "fractal.activity", qos: .utility)
    private var lastCPU: [pid_t: (ticks: UInt64, at: UInt64)] = [:]   // only touched on `queue`

    func start() {
        sample()
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.sample() }
    }

    private func sample() {
        let apps = Tracker.shared.orderedApps.map { ($0.pid, $0.app.bundleIdentifier, $0.app.bundleURL) }
        queue.async { [weak self] in
            guard let self else { return }
            let audio = self.audioSources()
            let badges = self.dockBadges()
            var result: [pid_t: (String?, Bool, Bool)] = [:]
            for (pid, bundleID, url) in apps {
                let playing = audio.pids.contains(pid)
                    || (bundleID.map { b in audio.bundles.contains { $0 == b || $0.hasPrefix(b + ".") } } ?? false)
                let badge = url.flatMap { badges[Self.normalize($0)] }
                result[pid] = (badge, playing, self.cpuFraction(pid) > 0.35)
            }
            DispatchQueue.main.async {
                for (pid, (badge, playing, busy)) in result {
                    guard let a = Tracker.shared.apps[pid] else { continue }
                    a.badge = badge
                    a.playingAudio = playing
                    a.busy = busy
                }
                Tracker.shared.bump()
            }
        }
    }

    private static func normalize(_ url: URL) -> String {
        var p = url.standardizedFileURL.path
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: Badges, read from the macOS Dock's accessibility tree

    private func dockBadges() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let el = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.2)
        var out: [String: String] = [:]
        guard let kids: [AXUIElement] = AX.attr(el, kAXChildrenAttribute) else { return out }
        for list in kids {
            guard let items: [AXUIElement] = AX.attr(list, kAXChildrenAttribute) else { continue }
            for item in items {
                guard let badge = AX.string(item, "AXStatusLabel"), !badge.isEmpty,
                      let url: URL = AX.attr(item, kAXURLAttribute) else { continue }
                out[Self.normalize(url)] = badge
            }
        }
        return out
    }

    // MARK: Audio, from Core Audio's list of processes currently producing output

    private func audioSources() -> (pids: Set<pid_t>, bundles: [String]) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return ([], []) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return ([], []) }

        var pids = Set<pid_t>()
        var bundles: [String] = []
        for id in ids {
            var running: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &running) == noErr, running != 0 else { continue }

            var pid: pid_t = 0
            sz = UInt32(MemoryLayout<pid_t>.size)
            a.mSelector = kAudioProcessPropertyPID
            if AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &pid) == noErr { pids.insert(pid) }

            var ref: Unmanaged<CFString>?
            sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            a.mSelector = kAudioProcessPropertyBundleID
            if AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &ref) == noErr, let s = ref?.takeRetainedValue() as String? {
                bundles.append(s)   // e.g. "com.google.Chrome.helper" → belongs to Chrome
            }
        }
        return (pids, bundles)
    }

    // MARK: CPU

    /// Fraction of one core the app's main process used since the last sample.
    private func cpuFraction(_ pid: pid_t) -> Double {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        } == 0
        guard ok else { return 0 }
        let ticks = info.ri_user_time + info.ri_system_time
        let now = mach_absolute_time()
        defer { lastCPU[pid] = (ticks, now) }
        guard let last = lastCPU[pid], now > last.at, ticks >= last.ticks else { return 0 }
        // Both counters are in mach time units on Apple silicon, so the ratio is unit-free.
        return Double(ticks - last.ticks) / Double(now - last.at)
    }
}
