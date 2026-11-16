import SwiftUI

private struct ConnectSizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// The Connect button (with its Ping chip) floating over the whole app, V2Box style: drag it
/// anywhere on the screen and it stays there, on every tab where it is shown. The spot is saved in
/// the settings as fractions of the screen, so it survives launches and different screen sizes.
///
/// The drag gesture sits on the button itself (not on the full-screen container), so touches
/// anywhere else reach the screen underneath. A tap still connects; only a drag of more than a few
/// points moves it.
struct DraggableConnectOverlay: View {
    let visible: Bool
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnel: TunnelController

    @State private var contentSize = CGSize(width: 90, height: 110)
    @State private var dragOrigin: CGPoint?
    @State private var liveCenter: CGPoint?

    private let edge: CGFloat = 8
    /// The tab bar sits inside the overlay's frame; keep the button above it.
    private let tabBarHeight: CGFloat = 52

    var body: some View {
        GeometryReader { proxy in
            if visible {
                content
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: ConnectSizeKey.self, value: inner.size)
                        }
                    )
                    .onPreferenceChange(ConnectSizeKey.self) { contentSize = $0 }
                    .scaleEffect(liveCenter == nil ? 1 : 1.05)
                    .animation(.easeOut(duration: 0.15), value: liveCenter == nil)
                    .simultaneousGesture(drag(in: proxy.size))
                    .position(liveCenter ?? savedCenter(in: proxy.size))
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: visible)
    }

    private var content: some View {
        VStack(spacing: 8) {
            ConnectRing(
                size: settings.value.connectionButtonSize,
                style: settings.value.navigationStyle,
                isConnected: tunnel.isConnected,
                isTransitioning: tunnel.isTransitioning
            ) {
                tunnel.toggle()
            }
            .disabled(tunnel.isBusy)
            PingChip()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connect button, \(tunnel.statusText). Drag to move.")
    }

    private func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let halfWidth = contentSize.width / 2 + edge
        let halfHeight = contentSize.height / 2 + edge
        let maxX = max(halfWidth, size.width - halfWidth)
        let maxY = max(halfHeight, size.height - tabBarHeight - halfHeight)
        return CGPoint(x: min(max(point.x, halfWidth), maxX), y: min(max(point.y, halfHeight), maxY))
    }

    private func savedCenter(in size: CGSize) -> CGPoint {
        let x = settings.value.connectButtonX ?? 0.22
        let y = settings.value.connectButtonY ?? 0.80
        return clamp(CGPoint(x: x * size.width, y: y * size.height), in: size)
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = savedCenter(in: size) }
                guard let origin = dragOrigin else { return }
                liveCenter = clamp(
                    CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height),
                    in: size
                )
            }
            .onEnded { _ in
                if let center = liveCenter, size.width > 0, size.height > 0 {
                    settings.value.connectButtonX = Double(center.x / size.width)
                    settings.value.connectButtonY = Double(center.y / size.height)
                }
                liveCenter = nil
                dragOrigin = nil
            }
    }
}
