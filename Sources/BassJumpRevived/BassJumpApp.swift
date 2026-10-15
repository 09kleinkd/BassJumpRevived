import AppKit
import Combine
import SwiftUI

@main
struct BassJumpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Menu bar item + popover. A real NSPopover sizes itself exactly to the SwiftUI content
/// (MenuBarExtra's window can leave empty glass above and below it on recent macOS).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let controller = BassJumpController()
    private lazy var calibrator = Calibrator(controller: controller)
    private let updater = Updater()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))

        let host = NSHostingController(rootView: MenuView(meter: controller.meterModel)
            .environmentObject(controller).environmentObject(calibrator).environmentObject(updater))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        controller.$status.combineLatest(controller.$iconLevel)
            .receive(on: RunLoop.main)
            .sink { [weak self] status, level in self?.updateIcon(playing: status.isPlaying, level: level) }
            .store(in: &cancellables)

        // `open BassJump.app --args --show-panel` opens the panel at launch (handy for testing).
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.togglePopover(nil) }
        }
    }

    /// Idle: speaker outline. Playing: filled speaker; with the live icon, its waves follow the bass.
    private func updateIcon(playing: Bool, level: Int) {
        let image: NSImage?
        if playing && level > 0 {
            image = NSImage(systemSymbolName: "speaker.wave.3.fill", variableValue: Double(level) / 3,
                            accessibilityDescription: "BassJump")
        } else {
            image = NSImage(systemSymbolName: playing ? "hifispeaker.fill" : "hifispeaker",
                            accessibilityDescription: "BassJump")
        }
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
