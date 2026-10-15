import SwiftUI

/// First-run setup: connect the BassJump, allow system audio, pick a sound.
/// Every step reacts live to the real state, and every step can be skipped.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, connect, permission, sound }

    @EnvironmentObject var c: BassJumpController
    // `--setup-step N` opens a specific step (for screenshots/testing).
    @State private var step: Step = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--setup-step"), i + 1 < args.count, let n = Int(args[i + 1]) {
            return Step(rawValue: n) ?? .welcome
        }
        return .welcome
    }()
    var finish: (_ calibrate: Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .connect: connect
                case .permission: permission
                case .sound: sound
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36).padding(.top, 28)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { s in
                        Circle().fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step != .welcome {
                    Button("Back") { go(-1) }
                }
                if step == .sound {
                    Button("Done") { finish(false) }.keyboardShortcut(.defaultAction)
                } else {
                    Button(continueTitle) { go(1) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 440)
    }

    private var continueTitle: String {
        switch step {
        case .connect where !bassJumpFound: return "Skip for Now"
        case .permission where !c.tapVerified: return "Skip for Now"
        default: return "Continue"
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.snappy) { step = next }
    }

    private var bassJumpFound: Bool { c.outputDevices.contains(where: \.looksLikeBassJump) }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Welcome to BassJump Revived").font(.title.bold())
            Text("BassJump Revived brings the Twelve South BassJump 2 back to life on today's Macs. It sends the bass from everything you play to your BassJump, with no driver or kernel extension to install.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("Setup takes about a minute.").font(.callout).foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Connect your BassJump", symbol: "cable.connector")
            Text("Plug the BassJump into a USB port on your Mac (an adapter is fine). There's nothing to install — macOS sees it as “BassJump Core”.")
                .foregroundStyle(.secondary)
            statusRow(ok: bassJumpFound,
                      okText: "Found \(c.outputDevices.first(where: \.looksLikeBassJump)?.name ?? "your BassJump")",
                      waitingText: "Waiting for a BassJump…")
            if !bassJumpFound {
                Text("If it doesn't show up, try another cable or port. Its power light should be on.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Let BassJump hear your Mac", symbol: "waveform")
            Text("To pull the bass out of your music, BassJump needs macOS's “system audio recording” permission. Audio is only filtered and sent to the sub as it plays; nothing is recorded or leaves your Mac.")
                .foregroundStyle(.secondary)
            Text("If macOS asked, click Allow. Then play some music.")
            statusRow(ok: c.tapVerified, okText: "BassJump is hearing your Mac",
                      waitingText: c.status.isPlaying ? "Play some music to check…" : "Waiting for BassJump to start…")
            if c.permissionProblem || !c.tapVerified {
                HStack {
                    Text("No sound getting through?").font(.callout).foregroundStyle(.tertiary)
                    Button("Open Privacy Settings") { c.openPrivacySettings() }.controlSize(.small)
                }
                Text("Turn on BassJump under Screen & System Audio Recording → System Audio Recording Only, then quit and reopen BassJump.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var sound: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Pick a sound", symbol: "slider.horizontal.3")
            Text("Start with a preset — you can fine-tune the crossover and level from the menu bar any time.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(BassPreset.builtIn) { p in
                    Button { c.apply(p) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: p.symbol).font(.title2).frame(height: 28)
                            Text(p.name).font(.caption)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(c.presetName == p.name ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(c.presetName == p.name ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            GroupBox {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calibrate for your room").font(.headline)
                        Text("Uses your Mac's microphone and three short bursts of noise to set the crossover, level, phase and room EQ.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Calibrate…") { finish(true) }.disabled(!c.status.isPlaying)
                }
                .padding(4)
            }
            Text("BassJump lives in the menu bar — click the speaker icon to change sound, or press \(c.shortcut.display) to turn it on and off.")
                .font(.callout).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: Pieces

    private func header(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.title2.bold())
    }

    private func statusRow(ok: Bool, okText: String, waitingText: String) -> some View {
        HStack(spacing: 10) {
            if ok {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
            } else {
                ProgressView().controlSize(.small).frame(width: 22)
            }
            Text(ok ? okText : waitingText).font(.headline)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .animation(.snappy, value: ok)
    }
}
