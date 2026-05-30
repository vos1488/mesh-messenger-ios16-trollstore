import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: NodeStore
    @Environment(\.dismiss) var dismiss
    @State private var editedNickname = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Профиль") {
                    HStack {
                        Text("Никнейм")
                        Spacer()
                        TextField("Имя", text: $editedNickname)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.accentColor)
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

                Section("О приложении") {
                    LabeledContent("Версия", value: "1.0 MVP")
                    LabeledContent("Протокол", value: "MeshMessenger P2P")
                    LabeledContent("Транспорт", value: "MultipeerConnectivity")
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
                        dismiss()
                    }
                }
            }
            .onAppear { editedNickname = store.nickname }
        }
    }
}
