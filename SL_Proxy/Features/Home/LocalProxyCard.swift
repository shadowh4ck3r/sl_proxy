import SwiftUI

/// Shows the loopback address other apps must point at in the user-space build.
struct LocalProxyCard: View {
    let endpoint: String
    let isRunning: Bool
    var passthroughActive: Bool = false
    let onCopy: () -> Void

    @State private var revealed = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.body)
                .foregroundStyle(iconStyle)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Local proxy")
                        .font(.subheadline.weight(.semibold))
                    if passthroughActive {
                        Text("DIRECT")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.orange)
                    }
                }
                HStack(spacing: 6) {
                    Text(revealed ? endpoint : endpoint.masked)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(endpointStyle)
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(revealed ? "Hide address" : "Show address")
                }
                Text(statusCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Copy proxy address")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Brand.gradient, lineWidth: 1)
                .opacity(0.5)
        )
    }

    private var iconStyle: AnyShapeStyle {
        if isRunning { return AnyShapeStyle(Brand.gradient) }
        if passthroughActive { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(Color.secondary)
    }

    private var endpointStyle: AnyShapeStyle {
        if isRunning { return AnyShapeStyle(Brand.gradient) }
        if passthroughActive { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(Color.secondary)
    }

    private var statusCaption: String {
        if isRunning { return "Listening" }
        if passthroughActive { return "Port held, traffic goes direct" }
        return "Starts when you connect"
    }
}
