import SwiftUI

struct DebugDiagnosticsView: View {
    @EnvironmentObject var store: NodeStore

    var body: some View {
        List {
            Section("Снимок сети") {
                LabeledContent("PeerID", value: String(store.myPeerURI.dropFirst("peer://".count).prefix(12)))
                LabeledContent("Пиров", value: "\(store.peers.count)")
                LabeledContent("Подключено", value: "\(store.connectedCount())")
                LabeledContent("WAN relay", value: store.isWANRelayConnected() ? "online" : "offline")
                LabeledContent("Вызов", value: callState)
            }

            Section("WAN bootstrap") {
                Text(store.effectiveWANBootstrapEndpoints().joined(separator: ", "))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("WAN registry") {
                Text(store.effectiveWANPeerRegistryRegisterURLString())
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section("События") {
                if store.debugEvents.isEmpty {
                    Text("Нет событий")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.debugEvents) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("[\(event.category)] \(event.message)")
                                .font(.caption)
                            Text(timeString(event.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Network/Call Debug")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var callState: String {
        guard let call = store.activeCall else { return "нет" }
        return "\(call.phase.rawValue) • \(call.peerNickname)"
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
