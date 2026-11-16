import Foundation

/// Selects a saved config as the active proxy and (re)starts the connection on Home.
///
/// Uses only `TunnelController.toggle()` and its published flags, the same calls the Connect button
/// makes, so everything the button does (config generation, carrier profile, kill switch) happens here too.
@MainActor
enum ProxyConnector {
    /// Saves the purchase into Configs, selects it, and connects. Returns false when it could not be saved.
    @discardableResult
    static func addAndConnect(_ purchase: PurchasedProxy, nodes: NodeStore, tunnel: TunnelController) async -> Bool {
        guard let node = nodes.upsertPurchased(purchase) else { return false }
        await connect(node, nodes: nodes, tunnel: tunnel)
        return true
    }

    static func connect(_ node: ProxyNode, nodes: NodeStore, tunnel: TunnelController) async {
        await waitUntil { !tunnel.isBusy }
        let alreadyActive = nodes.activeNodeID == node.id
        nodes.select(node)

        if tunnel.isConnected {
            if alreadyActive { return }
            tunnel.toggle()                                   // stop
            await waitUntil { !tunnel.isConnected && !tunnel.isBusy }
            tunnel.toggle()                                   // start on the newly selected server
        } else {
            tunnel.toggle()
        }
    }

    private static func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
}
