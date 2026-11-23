import CleanTrashCore
import Darwin
import Foundation
import Testing

@Suite("CleanTrashCore")
struct CleanTrashCoreTests {
    @Test("PathSafety blocks critical OS and user root directories")
    func pathSafetyBlocksProtected() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(PathSafety.isProtectedPath("/"))
        #expect(PathSafety.isProtectedPath("/System"))
        #expect(PathSafety.isProtectedPath("/System/Library/CoreServices"))
        #expect(PathSafety.isProtectedPath("/usr/bin"))
        #expect(PathSafety.isProtectedPath(home))
        #expect(PathSafety.isProtectedPath("\(home)/Library"))
        #expect(PathSafety.isProtectedPath("\(home)/Library/Keychains/login.keychain-db"))
        #expect(PathSafety.isProtectedPath("\(home)/.ssh/id_ed25519"))

        // Specific build artifacts & caches inside user paths are allowed
        #expect(!PathSafety.isProtectedPath("\(home)/Developer/demo/target"))
        #expect(!PathSafety.isProtectedPath("\(home)/Library/Caches/com.example.demo"))
    }

    @Test("SafeCleaner removes regular and user-immutable files but refuses protected paths")
    func safeCleanerWorksAndProtects() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleantrash-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileA = tmp.appendingPathComponent("artifact.bin")
        let lockedFile = tmp.appendingPathComponent("locked.bin")
        let payload = Data(repeating: 0xAB, count: 16_384)
        try payload.write(to: fileA)
        try payload.write(to: lockedFile)

        // Mark lockedFile user-immutable (UF_IMMUTABLE) to verify unlocking works
        _ = chflags(lockedFile.path, UInt32(UF_IMMUTABLE))

        let cleaner = SafeCleaner()
        let summary = await cleaner.clean(
            paths: [fileA.path, lockedFile.path, "/System"],
            moveToTrash: false
        )

        #expect(summary.removedCount == 2)
        #expect(summary.failedCount == 1) // "/System" blocked
        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        #expect(!FileManager.default.fileExists(atPath: lockedFile.path))
    }

    @Test("SafeCleaner deletes trees with read-only folders (dotslash/Go module caches)")
    func safeCleanerRemovesReadOnlyTrees() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("cleantrash-ro-\(UUID().uuidString)")
        let deep = tmp.appendingPathComponent("dotslash/cache/ab/cd")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        defer {
            _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+rwx", tmp.path]).waitUntilExit()
            try? fm.removeItem(at: tmp)
        }

        let payload = Data(repeating: 0xCD, count: 64_000)
        try payload.write(to: deep.appendingPathComponent("tool"))
        try payload.write(to: tmp.appendingPathComponent("dotslash/cache/ab/manifest"))
        _ = chflags(deep.appendingPathComponent("tool").path, UInt32(UF_IMMUTABLE))
        // Read-only directories (r-x) like dotslash / Go module caches: unlink() inside fails with EACCES.
        chmod(deep.path, 0o555)
        chmod(tmp.appendingPathComponent("dotslash/cache/ab").path, 0o555)
        chmod(tmp.appendingPathComponent("dotslash/cache").path, 0o500)

        let target = tmp.appendingPathComponent("dotslash").path
        let summary = await SafeCleaner().clean(paths: [target], moveToTrash: false)

        #expect(summary.failedCount == 0, "errors: \(summary.errors)")
        #expect(summary.removedCount == 1)
        #expect(summary.reclaimedBytes > 0)
        #expect(!fm.fileExists(atPath: target))
    }

    @Test("TrashEmptier empties a trash folder and reports real freed bytes")
    func trashEmptierEmptiesFolder() async throws {
        let fm = FileManager.default
        let fakeTrash = fm.temporaryDirectory.appendingPathComponent("cleantrash-trash-\(UUID().uuidString)")
        try fm.createDirectory(at: fakeTrash.appendingPathComponent("folder/sub"), withIntermediateDirectories: true)
        defer {
            _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+rwx", fakeTrash.path]).waitUntilExit()
            try? fm.removeItem(at: fakeTrash)
        }
        try Data(repeating: 1, count: 100_000).write(to: fakeTrash.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 100_000).write(to: fakeTrash.appendingPathComponent("folder/sub/b.bin"))
        try Data().write(to: fakeTrash.appendingPathComponent(".DS_Store"))
        chmod(fakeTrash.appendingPathComponent("folder/sub").path, 0o555)

        let result = await TrashEmptier(trashFolders: [fakeTrash.path], allowFinderFallback: false).empty()

        #expect(result.remainingCount == 0, "errors: \(result.errors)")
        #expect(result.removedCount == 2)
        #expect(result.freedBytes >= 200_000)
        let leftovers = try fm.contentsOfDirectory(atPath: fakeTrash.path).filter { $0 != ".DS_Store" }
        #expect(leftovers.isEmpty)
    }

    @Test("ProcessSampler measures real per-process CPU % between samples")
    func processSamplerMeasuresCPU() async throws {
        let sampler = ProcessSampler()
        let cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let wallStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        _ = sampler.sample(topLimit: 400)

        // Burn CPU on this thread so the test process shows up as a CPU consumer.
        let deadline = Date().addingTimeInterval(0.6)
        var x = 0.0
        while Date() < deadline { x += sin(x) + 1 }
        #expect(x > 0)

        let report = sampler.sample(topLimit: 400)
        let cpuEnd = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let wallEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        // Ground truth from the kernel's own accounting; independent of how loaded the machine is.
        let expected = Double(cpuEnd - cpuStart) / Double(wallEnd - wallStart) * 100

        #expect(report.processCount > 20)
        let me = report.topCPU.first { $0.pid == getpid() }
        #expect(me != nil, "test process missing from top CPU list")
        if let me {
            // A Mach-ticks/ns unit bug would be off by ~41×; allow scheduler/sampling-window noise.
            let ratio = me.cpuPercent / max(expected, 0.1)
            #expect(ratio > 0.5 && ratio < 2.0, "sampled \(me.cpuPercent)% vs kernel \(expected)%")
        }
    }

    @Test("DevArtifactScanner detects Cargo target/, Node node_modules/, and Swift .build/")
    func devScannerDetectsEcosystems() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleantrash-dev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let blob = Data(repeating: 0x42, count: 6_000_000) // 6 MB > 5 MB threshold

        // Rust project
        let rustProj = tmp.appendingPathComponent("my-rust-app")
        try FileManager.default.createDirectory(at: rustProj.appendingPathComponent("target"), withIntermediateDirectories: true)
        try Data("[package]\nname = \"demo\"\n".utf8).write(to: rustProj.appendingPathComponent("Cargo.toml"))
        try blob.write(to: rustProj.appendingPathComponent("target/debug.bin"))

        // Node project
        let nodeProj = tmp.appendingPathComponent("my-web-app")
        try FileManager.default.createDirectory(at: nodeProj.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try Data("{\"name\":\"web\"}".utf8).write(to: nodeProj.appendingPathComponent("package.json"))
        try blob.write(to: nodeProj.appendingPathComponent("node_modules/bundle.js"))

        // Swift project
        let swiftProj = tmp.appendingPathComponent("my-swift-app")
        try FileManager.default.createDirectory(at: swiftProj.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try Data("// swift-tools-version: 6.2".utf8).write(to: swiftProj.appendingPathComponent("Package.swift"))
        try blob.write(to: swiftProj.appendingPathComponent(".build/build.o"))

        let scanner = DevArtifactScanner()
        let artifacts = await scanner.scan(roots: [tmp.path], includeGlobalCaches: false)

        let kinds = Set(artifacts.map(\.artifactKind))
        #expect(kinds.contains("Cargo target/"))
        #expect(kinds.contains("node_modules/"))
        #expect(kinds.contains("Swift .build/"))
        #expect(artifacts.count == 3)
    }

    @Test("SystemJunkScanner detects corrupted plists and dangling LaunchAgents")
    func junkScannerDetectsBrokenConfigs() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleantrash-junk-\(UUID().uuidString)")
        let prefs = tmp.appendingPathComponent("Preferences")
        let agents = tmp.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Valid plist vs malformed plist
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>".utf8)
            .write(to: prefs.appendingPathComponent("com.valid.app.plist"))
        try Data("not-a-valid-plist{{{".utf8)
            .write(to: prefs.appendingPathComponent("com.broken.app.plist"))

        let brokenPrefs = SystemJunkScanner.scanBrokenPreferences(at: prefs.path)
        #expect(brokenPrefs.count == 1)
        #expect(brokenPrefs.first?.name == "com.broken.app.plist")

        // Dangling LaunchAgent pointing to a nonexistent executable
        let danglingAgent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.ghost.agent</string>
            <key>ProgramArguments</key><array><string>/Applications/NonExistentGhostApp.app/Contents/MacOS/Ghost</string></array>
        </dict>
        </plist>
        """
        try Data(danglingAgent.utf8).write(to: agents.appendingPathComponent("com.ghost.agent.plist"))

        let brokenAgents = SystemJunkScanner.scanBrokenLaunchAgents(at: agents.path)
        #expect(brokenAgents.count == 1)
        #expect(brokenAgents.first?.name == "com.ghost.agent.plist")
    }

    @Test("DiskMapper computes real allocated sizes and tags cleanable directories")
    func diskMapperMapsTree() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleantrash-map-\(UUID().uuidString)")
        let targetDir = tmp.appendingPathComponent("demo/target")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bigFile = targetDir.appendingPathComponent("lib.rlib")
        try Data(repeating: 0x01, count: 11_000_000).write(to: bigFile)

        let mapper = DiskMapper()
        let root = await mapper.mapDirectory(at: tmp.path, maxTreeDepth: 4)
        #expect(root.sizeBytes >= 10_000_000)
        #expect(root.children.count == 1)
        let targetNode = root.children.first?.children.first
        #expect(targetNode?.name == "target")
        #expect(targetNode?.isCleanableCandidate == true)
        #expect(targetNode?.category == .devBuilds)
    }

    @Test("SystemMonitor reads real macOS RAM, Disk, and GPU metrics")
    func systemMonitorReadsLiveTelemetry() {
        let monitor = SystemMonitor()
        let snap = monitor.sample(includeProcesses: false)
        #expect(snap.memory.totalBytes > 0)
        #expect(snap.disk.totalBytes > 0)
        #expect(snap.coreCount > 0)
        #expect(snap.gpu.deviceUtilizationPercent >= 0 && snap.gpu.deviceUtilizationPercent <= 100)
    }
}
