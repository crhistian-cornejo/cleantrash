import AppKit

/// Whether anyone can see the Mac right now. Background loops slow down or skip work while the
/// screen is locked or the displays sleep.
@MainActor
enum SystemActivity {
    private(set) static var isIdle = false
    private static var locked = false
    private static var asleep = false
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observers = [
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { asleep = true; update() }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { asleep = false; update() }
            },
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { locked = true; update() }
            },
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { locked = false; update() }
            }
        ]
    }

    private static func update() {
        isIdle = locked || asleep
    }
}
