import CoreServices
import Foundation

/// Live FSEvents watcher for developer project roots.
/// Detects whenever `target/`, `node_modules/`, `.next/`, `.turbo/`, `.build/`, or `DerivedData/`
/// experiences build activity and triggers a debounced callback so CleanTrash can automatically
/// re-scan and surface a non-intrusive Notch Notice once reclaimable space crosses the threshold.
public final class DevWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.cleantrash.devwatcher", qos: .utility)
    private var streamRef: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?
    private var onChange: (@Sendable ([String]) -> Void)?
    private var pendingPaths = Set<String>()

    private static let interestingSegments = [
        "/target/", "/target",
        "/node_modules/", "/node_modules",
        "/.next/", "/.turbo/", "/.build/", "/dist/",
        "/DerivedData/"
    ]

    public init() {}

    deinit {
        stop()
    }

    public func start(paths: [String], onChange: @escaping @Sendable ([String]) -> Void) {
        stop()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }

        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPathsPointer, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<DevWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            guard let cfPaths = unsafeBitCast(eventPathsPointer, to: CFArray?.self) as? [String] else { return }

            var matched: [String] = []
            for idx in 0..<min(numEvents, cfPaths.count) {
                let path = cfPaths[idx]
                if DevWatcher.interestingSegments.contains(where: { path.contains($0) }) {
                    matched.append(path)
                }
            }
            if !matched.isEmpty {
                watcher.scheduleDebounce(paths: matched)
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagIgnoreSelf
            | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            3.0,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.streamRef = stream
    }

    public func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
        onChange = nil
    }

    private func scheduleDebounce(paths: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            for p in paths { self.pendingPaths.insert(p) }
            self.debounceWorkItem?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let batch = Array(self.pendingPaths)
                self.pendingPaths.removeAll()
                self.onChange?(batch)
            }
            self.debounceWorkItem = work
            // Wait 12 seconds after build writes quiet down before notifying.
            self.queue.asyncAfter(deadline: .now() + 12.0, execute: work)
        }
    }
}
