import SwiftUI

/// Share sheet for one server: QR code of the share link, Copy URI and Copy v2ray JSON.
struct ShareConfigSheet: View {
    let node: ProxyNode
    @EnvironmentObject private var nodes: NodeStore
    @Environment(\.dismiss) private var dismiss

    private var uri: String? { node.shareURL ?? ProxyURLEncoder.encode(node) }
    private var json: String? { V2RayJSON.config(for: node) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    qrCode
                    VStack(spacing: 4) {
                        Text(node.name)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            KindBadge(kind: node.kind)
                            Text(node.displayServer.masked)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        copy(uri, done: "URI code copied")
                    } label: {
                        Label("Copy URI Code", systemImage: "link")
                    }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(uri == nil)

                    Button {
                        copy(json, done: "v2ray JSON copied")
                    } label: {
                        Label("Copy v2ray.json", systemImage: "curlybraces")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Brand.gradient, lineWidth: 1).opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .disabled(json == nil)
                    .opacity(json == nil ? 0.5 : 1)

                    if json == nil {
                        Text("v2ray JSON is not available for \(node.kind.title); use the URI code or the QR code.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Text("The QR code and the copied text contain this server's credentials. Share them only with people you trust.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .background(Brand.background)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var qrCode: some View {
        if let uri, let image = QRCodeGenerator.image(for: uri) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260)
                .padding(14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
                .accessibilityLabel("QR code for \(node.name)")
        } else {
            Text("This server has no share link.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 40)
        }
    }

    private func copy(_ text: String?, done: String) {
        guard let text else { return }
        UIPasteboard.general.string = text
        nodes.toast = done
    }
}
