import SwiftUI

/// Where the Connect button lives while "Fixed Button Position" is on.
///
/// - Docked (default): bottom-left above the tab bar, V2Box style, and Home shows the
///   Connected / Disconnected status card.
/// - Free: the user dragged it out of its dock and dropped it somewhere else. It stays exactly
///   there (also across launches), and Home hides the status card because the button now owns
///   that job. Dragging it back next to the dock re-docks it and the card returns.
///
/// The position is stored as fractions of the screen area, so it survives rotation, other
/// screen sizes and the Connection Button Size setting. It is plain UI state, nothing sensitive.
@MainActor
final class ConnectButtonPlacement: ObservableObject {
    static let shared = ConnectButtonPlacement()

    /// Centre of the button as (x, y) fractions of the area; nil means docked.
    @Published private(set) var free: CGPoint?

    var isFree: Bool { free != nil }

    private let key = "connectButton.freePosition"

    private init() {
        if let stored = UserDefaults.standard.string(forKey: key) {
            let parts = stored.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 { free = CGPoint(x: parts[0], y: parts[1]) }
        }
    }

    func place(_ point: CGPoint?) {
        free = point
        if let point {
            UserDefaults.standard.set("\(point.x),\(point.y)", forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func resetToDock() { place(nil) }
}

/// The Connect button with its Ping chip underneath.
struct ConnectDock: View {
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .accessibilityLabel("Connect button, \(tunnel.statusText)")
    }
}

private struct DockSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Draggable layer: the dock, free to move anywhere inside the screen area.
struct DraggableConnectLayer: View {
    @ObservedObject private var placement = ConnectButtonPlacement.shared
    @State private var drag: CGSize = .zero
    @State private var size = CGSize(width: 120, height: 90)

    private let dockMargin: CGFloat = 16
    private let snapDistance: CGFloat = 52

    var body: some View {
        GeometryReader { proxy in
            let area = proxy.size
            let dock = CGPoint(x: dockMargin + size.width / 2, y: area.height - 8 - size.height / 2)
            let base = placement.free.map { CGPoint(x: $0.x * area.width, y: $0.y * area.height) } ?? dock
            let live = clamp(CGPoint(x: base.x + drag.width, y: base.y + drag.height), in: area)

            ConnectDock()
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(key: DockSizeKey.self, value: inner.size)
                    }
                )
                .onPreferenceChange(DockSizeKey.self) { if $0 != .zero { size = $0 } }
                .position(live)
                // High priority so a drag moves the button, while a plain tap still reaches the switch.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            let end = clamp(CGPoint(x: base.x + value.translation.width,
                                                    y: base.y + value.translation.height), in: area)
                            drag = .zero
                            guard area.width > 0, area.height > 0 else { return }
                            let nearDock = hypot(end.x - dock.x, end.y - dock.y) < snapDistance
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                placement.place(nearDock ? nil : CGPoint(x: end.x / area.width, y: end.y / area.height))
                            }
                        }
                )
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: placement.free)
        }
    }

    /// Keeps the whole button (not just its centre) inside the area.
    private func clamp(_ point: CGPoint, in area: CGSize) -> CGPoint {
        let halfW = size.width / 2, halfH = size.height / 2
        guard area.width > size.width, area.height > size.height else { return point }
        return CGPoint(x: min(max(point.x, halfW + 4), area.width - halfW - 4),
                       y: min(max(point.y, halfH + 4), area.height - halfH - 4))
    }
}

/// Adds the draggable Connect button to a screen. While docked it reserves room at the bottom so
/// the content never hides behind it; once the button is free the room is given back.
struct DraggableConnectModifier: ViewModifier {
    let visible: Bool
    @ObservedObject private var placement = ConnectButtonPlacement.shared
    @EnvironmentObject private var settings: SettingsStore

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if visible && !placement.isFree {
                    Color.clear.frame(height: settings.value.connectionButtonSize.diameter + 52)
                }
            }
            .overlay {
                if visible { DraggableConnectLayer() }
            }
    }
}

extension View {
    func draggableConnectButton(visible: Bool) -> some View {
        modifier(DraggableConnectModifier(visible: visible))
    }
}
