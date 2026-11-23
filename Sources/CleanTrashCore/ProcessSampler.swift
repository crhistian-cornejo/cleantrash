import AppKit
import Darwin
import Foundation

public struct ProcessReport: Sendable, Equatable {
    public var topCPU: [ProcessSample] = []
    public var topMemory: [ProcessSample] = []
    public var simulator = SimulatorLoad()
    public var processCount = 0
}

/// One `proc_listallpids` pass that yields per-process CPU % (delta of `pti_total_user + pti_total_system`
/// between two samples, converted from Mach ticks), resident memory, ownership, and whether the process
/// belongs to a CoreSimulator runtime so a whole fleet of booted simulators can be shown as one line.
public final class ProcessSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previousTicks: [pid_t: UInt64] = [:]
    private var previousTimestamp: UInt64 = 0
    private var simulatorPIDs: [pid_t: Bool] = [:]
    private let timebase: (numer: UInt64, denom: UInt64)

    /// Core macOS processes we never offer to force-quit, even when user-owned.
    static let protectedNames: Set<String> = [
        "Finder", "Dock", "SystemUIServer", "ControlCenter", "WindowManager", "loginwindow",
        "WindowServer", "NotificationCenter", "launchd", "kernel_task", "CleanTrash", "Spotlight",
        "universalaccessd", "TextInputMenuAgent", "coreaudiod", "cfprefsd", "distnoted", "trustd"
    ]

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (UInt64(max(1, info.numer)), UInt64(max(1, info.denom)))
    }

    public func sample(topLimit: Int = 12) -> ProcessReport {
        var running: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            running[app.processIdentifier] = app
        }

        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return ProcessReport() }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 128)
        let written = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard written > 0 else { return ProcessReport() }

        let now = mach_absolute_time()
        let uid = getuid()
        let selfPID = getpid()

        lock.lock()
        let prevTicks = previousTicks
        let prevTime = previousTimestamp
        var simCache = simulatorPIDs
        lock.unlock()

        let elapsedNs = prevTime > 0 ? Double((now - prevTime) * timebase.numer / timebase.denom) : 0
        var ticks: [pid_t: UInt64] = [:]
        ticks.reserveCapacity(written)
        var all: [ProcessSample] = []
        all.reserveCapacity(written)
        var simulator = SimulatorLoad()
        var liveSimCache: [pid_t: Bool] = [:]

        for i in 0..<written {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { continue }

            let total = task.pti_total_user &+ task.pti_total_system
            ticks[pid] = total
            var cpu = 0.0
            if elapsedNs > 0, let prev = prevTicks[pid], total >= prev {
                let usedNs = Double((total - prev) * timebase.numer / timebase.denom)
                cpu = usedNs / elapsedNs * 100
            }

            // Path lookup is cached per pid: it never changes for the life of a process.
            let isSim: Bool
            if let cached = simCache[pid] {
                isSim = cached
            } else {
                isSim = Self.isSimulatorProcess(pid)
                simCache[pid] = isSim
            }
            liveSimCache[pid] = isSim

            if isSim {
                simulator.processCount += 1
                simulator.cpuPercent += cpu
                simulator.memoryBytes += task.pti_resident_size
            }

            // Only materialize samples that can make a top list.
            guard cpu >= 0.5 || task.pti_resident_size > 25_000_000 else { continue }

            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let owner: uid_t = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize ? bsd.pbi_uid : 0

            let app = running[pid]
            let name = app?.localizedName ?? Self.processName(pid)
            let killable = owner == uid && pid != selfPID && !Self.protectedNames.contains(name)
            all.append(ProcessSample(
                pid: pid,
                name: name,
                bundleIdentifier: app?.bundleIdentifier,
                memoryBytes: task.pti_resident_size,
                cpuPercent: cpu,
                isUserApp: app?.activationPolicy == .regular,
                isKillable: killable,
                isSimulator: isSim,
                appPath: app?.bundleURL?.path
            ))
        }

        lock.lock()
        previousTicks = ticks
        previousTimestamp = now
        simulatorPIDs = liveSimCache
        lock.unlock()

        let topCPU = all.filter { $0.cpuPercent >= 0.5 }.sorted { $0.cpuPercent > $1.cpuPercent }
        let topMemory = all.filter { $0.memoryBytes > 25_000_000 }.sorted { $0.memoryBytes > $1.memoryBytes }
        return ProcessReport(
            topCPU: Array(topCPU.prefix(topLimit)),
            topMemory: Array(topMemory.prefix(topLimit)),
            simulator: simulator,
            processCount: ticks.count
        )
    }

    static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_name(pid, &buf, UInt32(buf.count))
        guard len > 0 else { return "PID \(pid)" }
        let name = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // Version-named binaries (e.g. ~/.local/share/claude/versions/2.1.330) → "claude 2.1.330".
        if name.allSatisfy({ $0.isNumber || $0 == "." }), let path = processPath(pid) {
            let parts = path.split(separator: "/").map(String.init)
            if let idx = parts.lastIndex(of: "versions"), idx > 0 {
                return "\(parts[idx - 1]) \(name)"
            }
            if parts.count >= 2 {
                return "\(parts[parts.count - 2]) \(name)"
            }
        }
        return name
    }

    static func processPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func isSimulatorProcess(_ pid: pid_t) -> Bool {
        guard let path = processPath(pid) else { return false }
        return path.contains(".simruntime/")
            || path.contains("/CoreSimulator/Volumes/")
            || path.hasSuffix("/launchd_sim")
            || path.hasSuffix("/SimMetalHost")
            || path.hasSuffix("/xpcproxy_sim")
    }
}

/// Lists and shuts down booted Xcode simulators (`xcrun simctl`).
public struct SimulatorController: Sendable {
    public init() {}

    public func bootedDevices() async -> [SimulatorDevice] {
        await Task.detached(priority: .utility) {
            guard let output = Self.simctl(["list", "devices", "booted", "-j"]).output,
                  let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devices = json["devices"] as? [String: [[String: Any]]] else { return [] }
            var result: [SimulatorDevice] = []
            for (runtimeID, list) in devices {
                let runtime = runtimeID
                    .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                    .replacingOccurrences(of: "-", with: " ")
                for device in list where (device["state"] as? String) == "Booted" {
                    guard let udid = device["udid"] as? String else { continue }
                    result.append(SimulatorDevice(udid: udid, name: device["name"] as? String ?? udid, runtime: runtime))
                }
            }
            return result.sorted { $0.name < $1.name }
        }.value
    }

    /// Shuts down the given simulators (or all of them when `udids` is empty). Returns an error message or nil.
    public func shutdown(_ udids: [String] = []) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let result = Self.simctl(["shutdown"] + (udids.isEmpty ? ["all"] : udids))
            return result.success ? nil : (result.error ?? "simctl no pudo apagar los simuladores")
        }.value
    }

    private static func simctl(_ args: [String]) -> (success: Bool, output: String?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (false, nil, "Xcode no está instalado")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus == 0, String(data: outData, encoding: .utf8), errText?.isEmpty == false ? errText : nil)
    }
}
