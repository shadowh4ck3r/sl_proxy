import SwiftUI

/// Shows the loopback address other apps must point at in the user-space build.
struct LocalProxyCard: View {
    let endpoint: String
    let isRunning: Bool
    var passthroughActive: Bool = false
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(iconStyle)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Local proxy (HTTP + SOCKS5)")
                        .font(.headline)
                    if passthroughActive {
                        Text("DIRECT")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.orange)
                    }
                }
                Text(endpoint)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(endpointStyle)
                Text(statusCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
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
        if isRunning {
            return "Listening. Point Wi-Fi > Configure Proxy > Manual, or an app's SOCKS5 setting, at this address."
        }
        if passthroughActive {
            return "Port held — traffic goes direct to the internet. Reconnect to route through the proxy node."
        }
        return "Starts when you connect. Only works while SL_Proxy stays open."
    }
}
