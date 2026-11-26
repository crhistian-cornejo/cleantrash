import Foundation
import Observation
import Sparkle

/// Sparkle auto-updates. Feed + public key live in Info.plist (`SUFeedURL`, `SUPublicEDKey`);
/// the appcast is published as an asset of the latest GitHub release by `scripts/release.sh`.
@MainActor
@Observable
final class AppUpdater {
    private let controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    private(set) var canCheckForUpdates = false

    /// Only a real bundle (not `swift run` / debug snapshots) carries a feed URL.
    var isAvailable: Bool { controller != nil }

    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var automaticallyChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
