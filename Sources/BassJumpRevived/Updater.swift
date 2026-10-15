import AppKit
import Combine
import Sparkle

/// Sparkle auto-updates from the GitHub-hosted appcast (SUFeedURL in Info.plist).
/// BassJump is a menu bar app, so scheduled update alerts are shown "gently": instead of
/// popping a window over whatever you're doing, the menu shows an "Update available" row.
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var availableVersion: String?
    @Published var automaticChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticChecks }
    }

    private var controller: SPUStandardUpdaterController!

    override init() {
        automaticChecks = true
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: self)
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheck)
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in
            if handleShowingUpdate {
                NSApp.activate()
            } else {
                self.availableVersion = version
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.availableVersion = nil }
    }
}
