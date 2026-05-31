import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @EnvironmentObject var store: NodeStore
    @Environment(\.dismiss) var dismiss
    @State private var editedNickname = ""
    @State private var wanBootstrap = ""
    @State private var showQRScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Профиль") {
                    HStack {
                        Text("Никнейм")
                        Spacer()
                        TextField("Имя", text: $editedNickname)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Section("Мой PeerID") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.myPeerURI)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                        Button("Скопировать") {
                            UIPasteboard.general.string = store.myPeerURI
                        }
                        .font(.caption)
                    }
                }

                Section("Сеть") {
                    HStack {
                        Text("Статус")
                        Spacer()
                        HStack(spacing: 4) {
                            Circle().fill(store.isRunning ? .green : .red).frame(width: 8, height: 8)
                            Text(store.isRunning ? "Активен" : "Остановлен").foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Узлов найдено")
                        Spacer()
                        Text("\(store.peers.count)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Подключено")
                        Spacer()
                        Text("\(store.connectedCount())").foregroundStyle(.secondary)
                    }
                    if store.isRunning {
                        Button("Остановить узел", role: .destructive) {
                            store.stop()
                        }
                    } else {
                        Button("Запустить узел") {
                            Task { await store.start() }
                        }
                    }
                }

                Section("WAN / Relay") {
                    TextField("host:port, host:port", text: $wanBootstrap, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.caption, design: .monospaced))
                    Text("Для связи между разными Wi‑Fi/4G укажите bootstrap relay узлы.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("Диагностика") {
                    NavigationLink("Открыть Network/Call debug") {
                        DebugDiagnosticsView()
                            .environmentObject(store)
                    }
                }

                Section("Web версия") {
                    HStack {
                        Text("Статус")
                        Spacer()
                        Text(store.webSessionStatusText)
                            .font(.caption)
                            .foregroundStyle(store.webSessionAuthorized ? .green : .secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    if let sessionID = store.webSessionID {
                        HStack {
                            Text("Session")
                            Spacer()
                            Text(sessionID)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Button("Сканировать QR для web login") {
                        showQRScanner = true
                    }
                    if store.webSessionID != nil {
                        Button("Отключить web сессию", role: .destructive) {
                            store.disconnectWebSession()
                        }
                    }
                }

                Section("О приложении") {
                    LabeledContent("Версия", value: "1.0 MVP")
                    LabeledContent("Протокол", value: "MeshMessenger P2P")
                    LabeledContent("Транспорт", value: "Hybrid (MCP + UDP)")
                    LabeledContent("Шифрование", value: "AES-256-GCM + Ed25519")
                    LabeledContent("DHT", value: "Kademlia")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        if !editedNickname.trimmingCharacters(in: .whitespaces).isEmpty {
                            store.saveNickname(editedNickname.trimmingCharacters(in: .whitespaces))
                        }
                        store.saveWANBootstrapEndpoints(wanBootstrap)
                        dismiss()
                    }
                }
            }
            .onAppear {
                editedNickname = store.nickname
                wanBootstrap = store.wanBootstrapRaw
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerSheet { value in
                    store.connectWebSession(from: value)
                    showQRScanner = false
                }
            }
        }
    }
}
