import Darwin
import Foundation

/// Scans developer workspaces and global toolchains for reclaimable build artifacts:
/// - Rust / Cargo: `<project>/target` (verified by sibling `Cargo.toml`), `~/.cargo/registry/cache`, `~/.cargo/git/checkouts`
/// - Node / Bun / JS: `node_modules` (verified by `package.json`), `.next`, `.nuxt`, `.turbo`, `dist`, `.vite`, `.parcel-cache`, npm/bun/pnpm/yarn caches
/// - Swift / Xcode: `.build` (verified by `Package.swift`), `DerivedData`, `Archives`, `CoreSimulator/Caches`, SwiftPM cache
/// - Python / JVM / Go: `.venv`, `venv`, `pip`/`uv`, `gradle`, `m2`, `go/pkg/mod/cache`
/// - AI Tools & Local Models (informed by CleanMyMac 5.7 REA): Ollama, HuggingFace, LM Studio, Claude/Codex/Antigravity browser caches
///
/// Includes an Active-Build Guard so actively compiling Cargo/Node/Swift targets are flagged as "Active"
/// and never pre-selected for deletion.
public struct DevArtifactScanner: Sendable {
    public init() {}

    public func scan(
        roots: [String],
        includeGlobalCaches: Bool = true,
        activeBuildWindowSeconds: TimeInterval = 900
    ) async -> [DevArtifact] {
        await Task.detached(priority: .userInitiated) {
            let activeToolchains = Self.detectActiveBuildToolchains()
            var candidateSpecs: [(projectName: String, kind: String, eco: DevEcosystem, path: String, isGlobal: Bool)] = []

            let fm = FileManager.default
            var visitedPaths = Set<String>()

            // 1. Scan workspace roots for project build folders
            for root in roots {
                let rootURL = URL(fileURLWithPath: root).standardizedFileURL
                guard fm.fileExists(atPath: rootURL.path) else { continue }
                Self.walkProjectTree(
                    at: rootURL,
                    depth: 0,
                    maxDepth: 5,
                    visited: &visitedPaths,
                    output: &candidateSpecs
                )
            }

            // 2. Global toolchain caches & AI model/agent caches
            if includeGlobalCaches {
                let home = fm.homeDirectoryForCurrentUser.path
                let globals: [(String, String, DevEcosystem, String)] = [
                    ("Cargo Registry Cache", "~/.cargo/registry/cache", .rust, "\(home)/.cargo/registry/cache"),
                    ("Cargo Git Checkouts", "~/.cargo/git/checkouts", .rust, "\(home)/.cargo/git/checkouts"),
                    ("Bun Install Cache", "~/.bun/install/cache", .node, "\(home)/.bun/install/cache"),
                    ("npm Cache", "~/.npm/_cacache", .node, "\(home)/.npm/_cacache"),
                    ("pnpm Store", "~/Library/pnpm/store", .node, "\(home)/Library/pnpm/store"),
                    ("Yarn Cache", "~/Library/Caches/Yarn", .node, "\(home)/Library/Caches/Yarn"),
                    ("Xcode DerivedData", "DerivedData", .swift, "\(home)/Library/Developer/Xcode/DerivedData"),
                    ("Xcode Archives", "Archives", .swift, "\(home)/Library/Developer/Xcode/Archives"),
                    ("CoreSimulator Caches", "CoreSimulator/Caches", .swift, "\(home)/Library/Developer/CoreSimulator/Caches"),
                    ("SwiftPM Cache", "org.swift.swiftpm", .swift, "\(home)/Library/Caches/org.swift.swiftpm"),
                    ("pip Cache", "~/.cache/pip", .python, "\(home)/.cache/pip"),
                    ("uv Cache", "~/.cache/uv", .python, "\(home)/.cache/uv"),
                    ("Gradle Caches", "~/.gradle/caches", .jvmGo, "\(home)/.gradle/caches"),
                    ("Maven Repo", "~/.m2/repository", .jvmGo, "\(home)/.m2/repository"),
                    ("Go Module Cache", "~/go/pkg/mod/cache", .jvmGo, "\(home)/go/pkg/mod/cache"),
                    ("Homebrew Cache", "~/Library/Caches/Homebrew", .jvmGo, "\(home)/Library/Caches/Homebrew"),
                    ("HuggingFace Hub", "~/.cache/huggingface/hub", .aiModels, "\(home)/.cache/huggingface/hub"),
                    ("Ollama Models", "~/.ollama/models", .aiModels, "\(home)/.ollama/models"),
                    ("LM Studio Models", "~/.lmstudio/models", .aiModels, "\(home)/.lmstudio/models"),
                    ("Claude Shell Snapshots", "~/.claude/shell-snapshots", .aiModels, "\(home)/.claude/shell-snapshots"),
                    ("Claude Telemetry", "~/.claude/telemetry", .aiModels, "\(home)/.claude/telemetry"),
                    ("Chrome DevTools MCP Cache", "~/.cache/chrome-devtools-mcp", .aiModels, "\(home)/.cache/chrome-devtools-mcp"),
                    ("Antigravity Browser Cache", "~/.gemini/antigravity-browser-profile/Default/Cache", .aiModels, "\(home)/.gemini/antigravity-browser-profile/Default/Cache"),
                    ("Antigravity Code Cache", "~/.gemini/antigravity-browser-profile/Default/Code Cache", .aiModels, "\(home)/.gemini/antigravity-browser-profile/Default/Code Cache")
                ]

                for (name, kind, eco, path) in globals {
                    if fm.fileExists(atPath: path), visitedPaths.insert(path).inserted {
                        candidateSpecs.append((name, kind, eco, path, true))
                    }
                }
            }

            // 3. Measure sizes with bounded concurrency (max 4 workers) to keep CPU & RAM whisper-quiet
            let measured = await withTaskGroup(of: DevArtifact?.self) { group in
                let maxConcurrent = 4
                var nextIdx = 0
                var items: [DevArtifact] = []

                func enqueueNext() {
                    guard nextIdx < candidateSpecs.count else { return }
                    let spec = candidateSpecs[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        let url = URL(fileURLWithPath: spec.path)
                        let size = SafeCleaner.allocatedSize(of: url)
                        guard size >= 5_000_000 else { return nil } // Filter trivial < 5 MB folders

                        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        let recentlyTouched = Date.now.timeIntervalSince(mtime) < activeBuildWindowSeconds
                        let active = !spec.isGlobal && recentlyTouched && activeToolchains.contains(spec.eco)

                        // Never auto-select local LLM weights (Ollama/LM Studio/HF) or active builds by default
                        let autoSelect = !active && !(spec.eco == .aiModels && spec.kind.contains("Models"))

                        return DevArtifact(
                            projectName: spec.projectName,
                            artifactKind: spec.kind,
                            ecosystem: spec.eco,
                            path: spec.path,
                            sizeBytes: size,
                            lastModified: mtime,
                            isActiveBuild: active,
                            isGlobalCache: spec.isGlobal,
                            selected: autoSelect
                        )
                    }
                }

                for _ in 0..<min(maxConcurrent, candidateSpecs.count) {
                    enqueueNext()
                }

                for await item in group {
                    if let item { items.append(item) }
                    enqueueNext()
                }
                return items
            }

            return measured.sorted { $0.sizeBytes > $1.sizeBytes }
        }.value
    }

    private static func walkProjectTree(
        at url: URL,
        depth: Int,
        maxDepth: Int,
        visited: inout Set<String>,
        output: inout [(projectName: String, kind: String, eco: DevEcosystem, path: String, isGlobal: Bool)]
    ) {
        guard depth <= maxDepth else { return }
        let fm = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return }

        let names = Set(entries.map { $0.lastPathComponent })
        let projectName = url.lastPathComponent

        let hasCargo = names.contains("Cargo.toml")
        let hasNode = names.contains("package.json")
        let hasSwift = names.contains("Package.swift")
        let hasPython = names.contains("pyproject.toml") || names.contains("requirements.txt")

        for child in entries {
            let name = child.lastPathComponent
            let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard vals?.isDirectory == true, vals?.isSymbolicLink != true else { continue }

            let childPath = child.path

            // Match known build artifact folders and DO NOT recurse inside them
            if name == "target" && hasCargo {
                if visited.insert(childPath).inserted {
                    output.append((projectName, "Cargo target/", .rust, childPath, false))
                }
                continue
            }
            if name == "node_modules" && hasNode {
                if visited.insert(childPath).inserted {
                    output.append((projectName, "node_modules/", .node, childPath, false))
                }
                continue
            }
            if (name == ".next" || name == ".nuxt" || name == ".turbo" || name == ".parcel-cache" || name == ".vite") && hasNode {
                if visited.insert(childPath).inserted {
                    output.append((projectName, "\(name)/", .node, childPath, false))
                }
                continue
            }
            if name == "dist" && hasNode {
                if visited.insert(childPath).inserted {
                    output.append((projectName, "dist/", .node, childPath, false))
                }
                continue
            }
            if name == ".build" && hasSwift {
                if visited.insert(childPath).inserted {
                    output.append((projectName, "Swift .build/", .swift, childPath, false))
                }
                continue
            }
            if (name == ".venv" || name == "venv") && hasPython {
                if visited.insert(childPath).inserted {
                    output.append((projectName, "Python \(name)/", .python, childPath, false))
                }
                continue
            }

            // Skip hidden/heavy non-project directories
            if name == ".git" || name == "node_modules" || name == "target" || name == ".build" || name == "DerivedData" || name == "Pods" || name == "vendor" {
                continue
            }
            if name.hasPrefix(".") && name != ".t3" {
                continue
            }

            walkProjectTree(at: child, depth: depth + 1, maxDepth: maxDepth, visited: &visited, output: &output)
        }
    }

    /// Detects currently running build compilers so actively-building targets are protected.
    private static func detectActiveBuildToolchains() -> Set<DevEcosystem> {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 32)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return [] }

        var active = Set<DevEcosystem>()
        var buf = [CChar](repeating: 0, count: 128)
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let len = proc_name(pid, &buf, UInt32(buf.count))
            guard len > 0 else { continue }
            let name = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()

            if name == "cargo" || name == "rustc" || name == "rust-analyzer" {
                active.insert(.rust)
            } else if name == "bun" || name == "npm" || name == "pnpm" || name == "yarn" || name == "esbuild" || name == "turbo" || name == "next-server" || name == "vite" {
                active.insert(.node)
            } else if name == "swift-frontend" || name == "swiftc" || name == "xcodebuild" {
                active.insert(.swift)
            } else if name == "gradle" || name == "javac" || name == "go" {
                active.insert(.jvmGo)
            }
        }
        return active
    }
}
