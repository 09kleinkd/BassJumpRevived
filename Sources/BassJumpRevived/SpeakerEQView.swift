import SwiftUI

/// 10-band graphic EQ for the speakers (like BassJump 3.0.1's). It shapes the speaker signal,
/// which only flows through BassJump in time-aligned mode. Saved per output.
struct SpeakerEQView: View {
    @EnvironmentObject var c: BassJumpController

    private static let labels = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Toggle("Speaker EQ", isOn: $c.speakerEQEnabled).toggleStyle(.switch).font(.headline)
                if let name = c.profileOutputName {
                    Text("for \(name)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu(presetTitle) {
                    ForEach(SpeakerEQPreset.all) { p in
                        Button(p.name) { c.speakerEQ = p.gains }
                    }
                }
                .fixedSize()
            }

            if !c.alignedMode {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The speaker EQ works in time-aligned mode, where your speakers play through BassJump. In sub-only mode it has no effect.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Button("Turn On Time-Aligned Mode") { c.alignedMode = true }.controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
            }

            HStack(alignment: .top, spacing: 0) {
                VStack {
                    Text("+12").frame(maxHeight: .infinity, alignment: .top)
                    Text("0")
                    Text("−12").frame(maxHeight: .infinity, alignment: .bottom)
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 26, height: 170)
                .padding(.top, 22)          // line up with the faders, below the value labels
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 6) {
                        Text(dbText(c.speakerEQ[i])).font(.caption2.monospacedDigit())
                            .foregroundStyle(c.speakerEQ[i] == 0 ? .tertiary : .primary)
                        VerticalSlider(value: binding(i), range: -12...12, step: 0.5)
                            .frame(width: 22, height: 170)
                        Text(Self.labels[i]).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .disabled(!c.speakerEQEnabled)
            .opacity(c.speakerEQEnabled ? 1 : 0.45)

            HStack {
                Text("Hz · Double-click a slider to reset it. Boosts lower the overall level to leave headroom.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Reset") { c.speakerEQ = [Double](repeating: 0, count: 10) }
                    .disabled(c.speakerEQ.allSatisfy { $0 == 0 })
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var presetTitle: String { SpeakerEQPreset.matching(c.speakerEQ)?.name ?? "Custom" }

    private func binding(_ i: Int) -> Binding<Double> {
        Binding(get: { c.speakerEQ[i] }, set: { v in
            var g = c.speakerEQ; g[i] = v; c.speakerEQ = g
        })
    }

    private func dbText(_ v: Double) -> String {
        v == 0 ? "0" : String(format: "%+.1f", v).replacingOccurrences(of: ".0", with: "")
    }
}

/// A simple vertical fader: drag to set, double-click to centre.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.5
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, thumb: CGFloat = 16
            let span = range.upperBound - range.lowerBound
            let frac = (value - range.lowerBound) / span
            let y = (1 - frac) * (h - thumb) + thumb / 2
            let zeroY = (1 - (0 - range.lowerBound) / span) * (h - thumb) + thumb / 2
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.1)).frame(width: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Color.accentColor.opacity(isEnabled ? 0.9 : 0.4))
                    .frame(width: 4, height: abs(y - zeroY))
                    .offset(y: min(y, zeroY))
                Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 12, height: 1).offset(y: zeroY)
                Circle()
                    .fill(.background)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .frame(width: thumb, height: thumb)
                    .offset(y: y - thumb / 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = 1 - (g.location.y - thumb / 2) / (h - thumb)
                let raw = range.lowerBound + min(max(f, 0), 1) * span
                value = (raw / step).rounded() * step
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
        }
    }
}
