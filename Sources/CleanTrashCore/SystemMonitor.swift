import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Low-overhead native macOS telemetry collector.
/// Reads CPU deltas (Mach `host_statistics`), RAM breakdown (`host_statistics64` + `vm.swapusage`
/// + `kern.memorystatus_vm_pressure_level`), Apple Silicon GPU stats (`IOAccelerator` `PerformanceStatistics`),
/// Disk capacity/purgeable space, Battery health (`IOPSCopyPowerSourcesInfo` + `AppleSmartBattery`),
/// Network throughput (`getifaddrs`), and top memory processes (`proc_listallpids` + `proc_pidinfo`).
public final class SystemMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var previousCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var previousNetBytes: (inBytes: UInt64, outBytes: UInt64, timestamp: Date)?
    private let processSampler = ProcessSampler()

    public init() {}

    public func sample(includeProcesses: Bool = true) -> SystemTelemetry {
        let cpu = readCPU()
        let memory = Self.readMemory()
        let gpu = Self.readGPU()
        let disk = Self.readDisk()
        let battery = Self.readBattery()
        let network = readNetwork()
        let externalVolumes = Self.readExternalVolumes()
        let report = includeProcesses ? processSampler.sample() : nil
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Normal"
        case .fair: thermal = "Templada"
        case .serious: thermal = "Caliente"
        case .critical: thermal = "Crítica"
        @unknown default: thermal = "Normal"
        }

        var telemetry = SystemTelemetry(
            timestamp: .now,
            cpuTotalPercent: cpu.total,
            cpuUserPercent: cpu.user,
            cpuSystemPercent: cpu.system,
            coreCount: ProcessInfo.processInfo.processorCount,
            thermalState: thermal,
            memory: memory,
            gpu: gpu,
            disk: disk,
            battery: battery,
            network: network,
            externalVolumes: externalVolumes,
            topMemoryProcesses: report?.topMemory ?? []
        )
        telemetry.topCPUProcesses = report?.topCPU ?? []
        telemetry.simulatorLoad = report?.simulator ?? SimulatorLoad()
        telemetry.processCount = report?.processCount ?? 0
        telemetry.loadAverage = load[0]
        return telemetry
    }

    // MARK: - CPU

    private func readCPU() -> (total: Double, user: Double, system: Double) {
        var loadInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &loadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0, 0) }

        let user = UInt64(loadInfo.cpu_ticks.0)
        let system = UInt64(loadInfo.cpu_ticks.1)
        let idle = UInt64(loadInfo.cpu_ticks.2)
        let nice = UInt64(loadInfo.cpu_ticks.3)

        lock.lock()
        let prev = previousCPUTicks
        previousCPUTicks = (user, system, idle, nice)
        lock.unlock()

        guard let prev else { return (0, 0, 0) }
        let dUser = user >= prev.user ? user - prev.user : 0
        let dSys = system >= prev.system ? system - prev.system : 0
        let dIdle = idle >= prev.idle ? idle - prev.idle : 0
        let dNice = nice >= prev.nice ? nice - prev.nice : 0
        let totalTicks = dUser + dSys + dIdle + dNice
        guard totalTicks > 0 else { return (0, 0, 0) }

        let userPct = Double(dUser + dNice) / Double(totalTicks) * 100.0
        let sysPct = Double(dSys) / Double(totalTicks) * 100.0
        let totalPct = min(100.0, userPct + sysPct)
        return (totalPct, userPct, sysPct)
    }

    // MARK: - RAM

    public static func readMemory() -> MemorySnapshot {
        var totalMem: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalMem, &totalSize, nil, 0)

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS, page > 0 else {
            return MemorySnapshot(totalBytes: totalMem)
        }

        let internalPages = UInt64(vmStats.internal_page_count)
        let purgeablePages = UInt64(vmStats.purgeable_count)
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let wiredPages = UInt64(vmStats.wire_count)
        let compressedPages = UInt64(vmStats.compressor_page_count)
        let externalPages = UInt64(vmStats.external_page_count)
        let freePages = UInt64(vmStats.free_count)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var pressureRaw: Int32 = 1
        var pressureSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureRaw, &pressureSize, nil, 0)
        let pressure = MemoryPressureLevel(rawValue: Int(pressureRaw)) ?? .normal

        return MemorySnapshot(
            totalBytes: totalMem,
            appBytes: appPages * page,
            wiredBytes: wiredPages * page,
            compressedBytes: compressedPages * page,
            cachedFilesBytes: (externalPages + purgeablePages) * page,
            purgeableBytes: purgeablePages * page,
            freeBytes: freePages * page,
            swapUsedBytes: swap.xsu_used,
            swapTotalBytes: swap.xsu_total,
            pressure: pressure
        )
    }

    // MARK: - GPU (IOKit IOAccelerator)

    public static func readGPU() -> GPUSnapshot {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator") else {
            return GPUSnapshot()
        }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return GPUSnapshot()
        }
        defer { IOObjectRelease(iterator) }

        var best = GPUSnapshot()
        var found = false

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            let modelName: String = {
                if let cfVal = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                    if let str = cfVal as? String { return str }
                    if let data = cfVal as? Data, let str = String(data: data, encoding: .utf8) {
                        return str.trimmingCharacters(in: .controlCharacters.union(.whitespaces))
                    }
                }
                return "Apple Silicon GPU"
            }()

            guard let statsCF = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            let deviceUtil = numberValue(statsCF["Device Utilization %"])
                ?? numberValue(statsCF["GPU Activity(%)"])
                ?? 0
            let rendererUtil = numberValue(statsCF["Renderer Utilization %"]) ?? deviceUtil
            let tilerUtil = numberValue(statsCF["Tiler Utilization %"]) ?? deviceUtil
            let inUse = uint64Value(statsCF["In use system memory"])
                ?? uint64Value(statsCF["vramUsedBytes"])
                ?? 0
            let alloc = uint64Value(statsCF["Alloc system memory"])
                ?? uint64Value(statsCF["vramFreeBytes"])
                ?? 0

            let candidate = GPUSnapshot(
                modelName: modelName,
                deviceUtilizationPercent: min(100, max(0, deviceUtil)),
                rendererUtilizationPercent: min(100, max(0, rendererUtil)),
                tilerUtilizationPercent: min(100, max(0, tilerUtil)),
                inUseMemoryBytes: inUse,
                allocatedMemoryBytes: alloc
            )

            if !found || candidate.deviceUtilizationPercent >= best.deviceUtilizationPercent {
                best = candidate
                found = true
            }
        }
        return best
    }

    private static func numberValue(_ raw: Any?) -> Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        return nil
    }

    private static func uint64Value(_ raw: Any?) -> UInt64? {
        if let n = raw as? NSNumber { return n.uint64Value }
        if let u = raw as? UInt64 { return u }
        if let i = raw as? Int, i >= 0 { return UInt64(i) }
        return nil
    }

    // MARK: - Disk

    public static func readDisk() -> DiskSnapshot {
        let rootURL = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? rootURL.resourceValues(forKeys: keys) else {
            return DiskSnapshot()
        }
        let name = values.volumeName ?? "Macintosh HD"
        let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
        let available = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)))
        let opportunistic = UInt64(max(0, values.volumeAvailableCapacityForOpportunisticUsage ?? Int64(available)))

        return DiskSnapshot(
            volumeName: name,
            totalBytes: total,
            availableBytes: available,
            opportunisticAvailableBytes: max(available, opportunistic)
        )
    }

    public static func readExternalVolumes() -> [ExternalVolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        var volumes: [ExternalVolumeInfo] = []
        for url in urls {
            if url.path == "/" || url.path.hasPrefix("/System") { continue }
            guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isInternal = vals.volumeIsInternal ?? true
            let isRemovable = vals.volumeIsRemovable ?? false
            let isEjectable = vals.volumeIsEjectable ?? false
            if isInternal && !isRemovable && !isEjectable { continue }

            let total = UInt64(max(0, vals.volumeTotalCapacity ?? 0))
            guard total > 0 else { continue }
            let avail = UInt64(max(0, vals.volumeAvailableCapacity ?? 0))
            volumes.append(ExternalVolumeInfo(
                name: vals.volumeName ?? url.lastPathComponent,
                path: url.path,
                totalBytes: total,
                availableBytes: avail,
                isEjectable: isEjectable || isRemovable
            ))
        }
        return volumes
    }

    // MARK: - Battery

    public static func readBattery() -> BatterySnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty else {
            return BatterySnapshot(present: false)
        }

        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else {
                continue
            }
            let current = Double(desc[kIOPSCurrentCapacityKey] as? Int ?? 0)
            let maxCap = Double(max(1, desc[kIOPSMaxCapacityKey] as? Int ?? 100))
            let pct = min(100, max(0, current / maxCap * 100.0))
            let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let powerSource = desc[kIOPSPowerSourceStateKey] as? String
            let isPluggedIn = powerSource == kIOPSACPowerValue
            let timeToEmpty = desc[kIOPSTimeToEmptyKey] as? Int
            let timeToFull = desc[kIOPSTimeToFullChargeKey] as? Int
            let minutes: Int?
            if isCharging, let t = timeToFull, t > 0 {
                minutes = t
            } else if !isPluggedIn, let t = timeToEmpty, t > 0 {
                minutes = t
            } else {
                minutes = nil
            }

            let smart = readSmartBatteryDetails()
            return BatterySnapshot(
                present: true,
                percent: pct,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                minutesRemaining: minutes,
                cycleCount: smart.cycleCount,
                healthPercent: smart.healthPercent
            )
        }
        return BatterySnapshot(present: false)
    }

    private static func readSmartBatteryDetails() -> (cycleCount: Int?, healthPercent: Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }

        let cycles = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        let maxCap = IORegistryEntryCreateCFProperty(service, "AppleRawMaxCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Double
            ?? IORegistryEntryCreateCFProperty(service, "MaxCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Double
        let designCap = IORegistryEntryCreateCFProperty(service, "DesignCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Double

        let health: Double?
        if let maxCap, let designCap, designCap > 0 {
            health = min(100, max(0, maxCap / designCap * 100.0))
        } else {
            health = nil
        }
        return (cycles, health)
    }

    // MARK: - Network

    private func readNetwork() -> NetworkSnapshot {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return NetworkSnapshot()
        }
        defer { freeifaddrs(ifaddr) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let addr = ptr.pointee
            cursor = addr.ifa_next
            guard let sa = addr.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: addr.ifa_name)
            // Skip loopback & virtual tunnels to reflect real Wi-Fi/Ethernet traffic.
            guard name.hasPrefix("en") else { continue }
            guard let data = addr.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
            totalIn &+= UInt64(data.ifi_ibytes)
            totalOut &+= UInt64(data.ifi_obytes)
        }

        let now = Date.now
        lock.lock()
        let prev = previousNetBytes
        previousNetBytes = (totalIn, totalOut, now)
        lock.unlock()

        guard let prev else { return NetworkSnapshot() }
        let dt = max(0.2, now.timeIntervalSince(prev.timestamp))
        let dIn = totalIn >= prev.inBytes ? Double(totalIn - prev.inBytes) : 0
        let dOut = totalOut >= prev.outBytes ? Double(totalOut - prev.outBytes) : 0
        return NetworkSnapshot(bytesInPerSec: dIn / dt, bytesOutPerSec: dOut / dt)
    }
}
