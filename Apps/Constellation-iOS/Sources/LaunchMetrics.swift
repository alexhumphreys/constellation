import ConstellationCore
import Darwin
import Foundation
import UIKit

// Build/device/runtime context for the `app.launch` wide event. Every
// value here is something that plausibly moves launch (or general)
// performance, so a launch line can be sliced by it later: which build,
// which device, debug-vs-release, throttled-vs-not. Gathering is cheap —
// no I/O beyond a stat of the SQLite file and a single sysctl.
enum LaunchMetrics {
    // Short git SHA baked into the bundle at `xcodegen generate` time via
    // the `GitSHA` Info.plist key (see project.yml + `just ios-gen`).
    // Empty/absent ⇒ the project was generated without GIT_SHA set; fall
    // back to "unknown" so the field is always present and queryable.
    static let gitSHA: String = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "GitSHA") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }()

    static let appVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "unknown"

    static let buildNumber: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "unknown"

    // UIDevice is main-actor isolated, so this is a computed property
    // read on the (main-actor) launch path rather than a stored default.
    @MainActor static var osVersion: String { UIDevice.current.systemVersion }

    static let isDebug: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }()

    // Hardware model identifier, e.g. "iPhone16,2". On the simulator
    // `hw.machine` is the host arch ("arm64"), so prefer the simulated
    // device the host exposes via the environment.
    static let deviceModel: String = {
        if let simModel = ProcessInfo.processInfo
            .environment["SIMULATOR_MODEL_IDENTIFIER"], !simModel.isEmpty {
            return simModel
        }
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }()

    // Maps the thermal state to a stable string. Thermal throttling and
    // low-power mode both slow the CPU/GPU, so a launch that's slow
    // because the device is hot reads differently from a code regression.
    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // Kernel-recorded process start time, used to measure the slice of
    // cold launch that happens before our code runs (dyld, pre-main,
    // SwiftUI scene setup). nil if the sysctl fails — the field is then
    // omitted rather than guessed.
    static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        let seconds = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    // On-disk footprint of the SQLite store. Bigger DB ⇒ longer open +
    // first queries, so this is the scale knob that explains a slow warm
    // launch. The store runs in WAL mode (DatabasePool), so recent writes
    // live in the `-wal` sidecar until checkpoint — sum the main file and
    // its `-wal`/`-shm` companions or the number undercounts badly.
    static func storeFileBytes() -> Int64? {
        let base = AppContext.storeURL().path
        let fm = FileManager.default
        var total: Int64 = 0
        var found = false
        for path in [base, base + "-wal", base + "-shm"] {
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                total += size.int64Value
                found = true
            }
        }
        return found ? total : nil
    }

    // Static (no-timing) context fields shared by the launch event.
    // Bootstrap merges the timing + data-scale fields on top. @MainActor
    // because `osVersion` reads UIDevice.
    @MainActor static func environmentFields() -> [String: WideValue] {
        [
            "git_sha": .string(gitSHA),
            "app_version": .string(appVersion),
            "build": .string(buildNumber),
            "device_model": .string(deviceModel),
            "os_version": .string(osVersion),
            "debug": .bool(isDebug),
            "simulator": .bool(isSimulator),
            "low_power": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled),
            "thermal_state": .string(thermalState()),
        ]
    }
}
