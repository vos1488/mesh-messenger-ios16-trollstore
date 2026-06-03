import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @EnvironmentObject var store: NodeStore
    @Environment(\.dismiss) var dismiss
    @State private var editedNickname = ""
    @State private var wanBootstrap = ""
    @State private var wanRegistryURL = ""
    @State private var showQRScanner = false
    @State private var showClearAllChatsConfirm = false

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
                    TextField("http://host:port/api/mesh/peers/register", text: $wanRegistryURL, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.caption, design: .monospaced))
                    Text("Для связи между разными сетями (включая мобильные) используется WAN bootstrap relay.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Активные bootstrap: \(store.effectiveWANBootstrapEndpoints().joined(separator: ", "))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Peer-exchange registry: \(store.effectiveWANPeerRegistryRegisterURLString())")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("Always-on peer режим") {
                    Picker(
                        "Профиль",
                        selection: Binding(
                            get: { store.runtimeProfile },
                            set: { store.setRuntimeProfile($0) }
                        )
                    ) {
                        ForEach(MeshRuntimeProfile.allCases, id: \.rawValue) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)

                    Group {
                        switch store.runtimeProfile {
                        case .balanced:
                            Text("Стандартный баланс задержки и энергии. Подходит для Wi-Fi/LTE.")
                        case .lowPowerAlwaysOn:
                            Text("Узел держится постоянно, но реже шлет heartbeat и мягче ретраи — меньше расход батареи.")
                        case .edgeAlwaysOn:
                            Text("Профиль для 2G/EDGE: длинные heartbeat/ретраи, минимум фоновой нагрузки, стабильнее на слабых каналах.")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Section("Навигация и anti-spoof") {
                    Toggle(
                        "Включить доверенную геопозицию",
                        isOn: Binding(
                            get: { store.locationTrackingEnabled },
                            set: { store.setLocationTrackingEnabled($0) }
                        )
                    )
                    LabeledContent("Авторизация", value: authorizationText(store.trustedLocation.authorization))
                    LabeledContent("Доверие", value: "\(store.trustedLocation.trustScore)% • \(store.locationTrustSummary)")
                    if let lat = store.trustedLocation.latitude, let lon = store.trustedLocation.longitude {
                        LabeledContent("Координаты", value: "\(formatCoordinate(lat)), \(formatCoordinate(lon))")
                    }
                    Text(store.trustedLocation.reason)
                        .font(.caption2)
                        .foregroundStyle(store.trustedLocation.suspectedSpoofing ? .orange : .secondary)
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
                    LabeledContent("Версия", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                    LabeledContent("Протокол", value: "MeshWave Mesh Protocol")
                    LabeledContent("Транспорт", value: "Hybrid (MCP + UDP)")
                    LabeledContent("Шифрование", value: "Double Ratchet + AES-256-GCM + Ed25519")
                    LabeledContent("DHT", value: "Kademlia")
                }

                Section("Чаты") {
                    Button("Очистить все чаты", role: .destructive) {
                        showClearAllChatsConfirm = true
                    }
                }

                UpdateSettingsSection()
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.06), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        if !editedNickname.trimmingCharacters(in: .whitespaces).isEmpty {
                            store.saveNickname(editedNickname.trimmingCharacters(in: .whitespaces))
                        }
                        store.saveWANBootstrapEndpoints(wanBootstrap)
                        store.saveWANPeerRegistryRegisterURL(wanRegistryURL)
                        dismiss()
                    }
                }
            }
            .onAppear {
                editedNickname = store.nickname
                wanBootstrap = store.wanBootstrapRaw
                wanRegistryURL = store.wanRegistryURLRaw
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerSheet { value in
                    store.connectWebSession(from: value)
                    showQRScanner = false
                }
            }
            .confirmationDialog("Очистить все чаты?", isPresented: $showClearAllChatsConfirm, titleVisibility: .visible) {
                Button("Очистить все", role: .destructive) {
                    store.clearAllChats()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Будут удалены все сообщения со всеми собеседниками. Это действие нельзя отменить.")
            }
        }
    }

    private func authorizationText(_ auth: LocationAuthorizationState) -> String {
        switch auth {
        case .notDetermined: return "не запрошено"
        case .restricted: return "ограничено"
        case .denied: return "запрещено"
        case .authorizedWhenInUse: return "при использовании"
        case .authorizedAlways: return "всегда"
        }
    }

    private func formatCoordinate(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
