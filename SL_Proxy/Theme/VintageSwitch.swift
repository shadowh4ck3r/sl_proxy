import SwiftUI

/// Classic wooden Connect switch used by the Erosion navigation style: a wood-grain plank with a
/// rotary knob on the left and chalk ON / OFF lettering on the right, in the spirit of the vintage
/// toggle in the TunnelBear reference. The knob's lever swings between the OFF and ON positions
/// and sits upright while the connection is changing.
///
/// `height` is the Connection Button Size diameter, so Small / Medium / Large scale the whole plank.
struct VintageConnectSwitch: View {
    let height: CGFloat
    let isOn: Bool
    var isBusy = false
    let action: () -> Void

    private var width: CGFloat { height * 2.2 }
    private var corner: CGFloat { height * 0.3 }
    private var knobSize: CGFloat { height * 0.72 }
    private var leverAngle: Double { isBusy ? 0 : (isOn ? 42 : -42) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: height * 0.16) {
                knob
                VStack(alignment: .leading, spacing: height * 0.04) {
                    chalk("ON", opacity: isBusy ? 0.7 : (isOn ? 1 : 0.38))
                    chalk("OFF", opacity: isBusy ? 0.7 : (isOn ? 0.38 : 1))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, height * 0.14)
            .frame(width: width, height: height)
            .background(plank)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.28), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.25), radius: height * 0.1, y: height * 0.05)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: leverAngle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connect")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var plank: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.82, green: 0.55, blue: 0.25), Color(red: 0.68, green: 0.40, blue: 0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
            // Wood grain: thin, slightly uneven dark lines.
            VStack(spacing: height * 0.085) {
                ForEach(0..<9, id: \.self) { index in
                    Capsule()
                        .fill(Color.black.opacity(index % 2 == 0 ? 0.08 : 0.04))
                        .frame(height: 1)
                        .padding(.leading, CGFloat((index * 7) % 5) * 6)
                }
            }
            .padding(.top, height * 0.1)
        }
    }

    private var knob: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 0.58, green: 0.35, blue: 0.19), Color(red: 0.24, green: 0.12, blue: 0.06)],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: knobSize * 0.9
                    )
                )
            Circle()
                .strokeBorder(Color.black.opacity(0.4), lineWidth: 1)
            // Lever: drawn upright from the knob centre inside a knob-sized frame, so rotating the
            // frame pivots it around the centre.
            Capsule()
                .fill(Color(red: 0.33, green: 0.19, blue: 0.09))
                .frame(width: knobSize * 0.13, height: knobSize * 0.55)
                .offset(y: -knobSize * 0.18)
                .frame(width: knobSize, height: knobSize)
                .rotationEffect(.degrees(leverAngle))
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: knobSize * 0.22, height: knobSize * 0.22)
                .offset(x: -knobSize * 0.2, y: -knobSize * 0.22)
        }
        .frame(width: knobSize, height: knobSize)
    }

    private func chalk(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: height * 0.2, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(opacity))
            .shadow(color: Color.black.opacity(0.25), radius: 1, y: 1)
    }
}
