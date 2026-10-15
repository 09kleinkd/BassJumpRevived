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
    private(set) static weak var shared: AppDelegate?
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let popover = NSPopover()
    private let controller = BassJumpController()
    private lazy var calibrator = Calibrator(controller: controller)
    private let updater = Updater()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
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

        // First run: guided setup. People upgrading from earlier versions skip it.
        let defaults = UserDefaults.standard
        if CommandLine.arguments.contains("--setup") {
            DispatchQueue.main.async { self.showOnboarding() }
        } else if !defaults.bool(forKey: "onboarded") {
            if controller.hasHistory {
                defaults.set(true, forKey: "onboarded")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showOnboarding() }
            }
        }
        // `--write-diagnostics <file>` writes the diagnostic report and quits (for support/testing).
        if let i = CommandLine.arguments.firstIndex(of: "--write-diagnostics"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))       // let the engine start
                let text = await Diagnostics.report(controller: self.controller)
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { self.showSettings() }
        }

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

    // MARK: Windows

    func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make(controller: controller, updater: updater)
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        popover.performClose(nil)
        if onboardingWindow == nil {
            let view = OnboardingView { [weak self] calibrate in self?.finishOnboarding(calibrate: calibrate) }
                .environmentObject(controller)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Set Up BassJump"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                UserDefaults.standard.set(true, forKey: "onboarded")
            }
            onboardingWindow = window
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    private func finishOnboarding(calibrate: Bool) {
        UserDefaults.standard.set(true, forKey: "onboarded")
        onboardingWindow?.close()
        onboardingWindow = nil
        // Point at the menu bar icon; with "Calibrate…" the calibration card opens there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if calibrate { self.calibrator.prepare() }
            self.togglePopover(nil)
        }
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
