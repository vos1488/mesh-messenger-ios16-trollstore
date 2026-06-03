import SwiftUI

// Shown once per version after an update is applied
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    let version: String

    private let features: [(icon: String, color: Color, title: String, desc: String)] = [
        ("drop.fill", .cyan, "Liquid Glass UI в iOS", "Основные iOS-экраны (чаты, список узлов, настройки, баннеры) переведены на стеклянный стиль с material-слоями и мягкими контурами."),
        ("bolt.horizontal.circle.fill", .green, "Always-on peer + 2G/EDGE профиль", "Добавлены runtime-профили сети: Balanced, Always-on Low Power и Always-on 2G/EDGE с адаптивными heartbeat/retry для минимального расхода батареи."),
        ("sparkles.rectangle.stack.fill", .cyan, "Liquid Glass Web UX", "Web companion переработан под desktop messenger layout: сайдбар, secure stream, event timeline и glass-эффект."),
        ("lock.shield.fill", .green, "Крипто-handshake web-сессии", "Добавлена обязательная проверка auth_challenge + Ed25519 подписи, чтобы web login подтверждался ключами узла."),
        ("person.badge.key.fill", .mint, "Identity fingerprint в web UI", "В веб-клиенте отображаются PeerID и fingerprint ключей для ручной проверки доверия."),
        ("app.connected.to.app.below.fill", .blue, "Ребрендинг в MeshWave", "Приложение переименовано из MeshMessenger в MeshWave как полноценная mesh-платформа."),
        ("list.bullet.rectangle.portrait", .green, "Лог событий Web Bridge", "Web-страница теперь показывает поток событий с временем (status/authorized/heartbeat и другие сообщения), чтобы сессия не выглядела \"зависшей\"."),
        ("desktopcomputer", .blue, "PC Peer Service (Go)", "Добавлен desktop peer service с режимом системного сервиса (install/start/stop/uninstall) для Windows/macOS/Linux."),
        ("network", .orange, "Сетевой cross-check геопозиции", "Добавлена сверка GPS-точки с сетевым регионом (Wi-Fi/сотовая сеть через IP), чтобы лучше отлавливать спуфинг."),
        ("hand.draw.fill", .indigo, "Свободное управление картой", "Отключена принудительная автоцентровка: карту можно свободно двигать и отдалять как в обычных map-приложениях."),
        ("scope", .blue, "Геопозиция стала стабильнее", "Улучшены эвристики anti-spoof: фильтрация GPS-шума, сглаживание jitter и fallback на последнюю надежную точку."),
        ("map.circle.fill", .teal, "Карта как основной экран", "Вкладка карты переведена в fullscreen-режим с плавающими контролами, ближе к UX Яндекс Карт / 2GIS."),
        ("square.grid.2x2.fill", .indigo, "Вкладки интерфейса", "Чаты перенесены в отдельную вкладку для более удобной навигации."),
        ("map.fill", .teal, "Карта и геопозиция", "Добавлена вкладка карты с отображением доверенной геопозиции и статуса anti-spoof."),
        ("location.circle.fill", .blue, "Trusted Navigation (beta)", "Добавлен движок доверия геопозиции с anti-spoof эвристиками для iOS 16+ (TrollStore и dev-сертификат)."),
        ("ellipsis.bubble.fill", .green, "Typing + presence", "В чате добавлены индикаторы «печатает…» и актуальный онлайн-статус собеседника по heartbeat."),
        ("paperclip.circle.fill", .orange, "Прогресс отправки файлов", "Файлы показываются в ленте как bubble с индикатором прогресса передачи."),
        ("arrowshape.turn.up.left.fill", .mint, "Reply-to сообщения", "Теперь можно ответить на конкретное сообщение прямо из контекстного меню bubble."),
        ("arrowshape.turn.up.right.fill", .indigo, "Пересылка между чатами", "Добавлена пересылка сообщения в другой диалог через встроенный picker контактов."),
        ("slider.horizontal.3", .blue, "Управление чатами", "Добавлены mute, pin, archive и mark unread прямо из списка и экрана диалога."),
        ("clock.arrow.trianglehead.counterclockwise.rotate.90", .orange, "Умная история", "История подгружается батчами при прокрутке вверх, без резких скачков UI."),
        ("magnifyingglass.circle.fill", .green, "Поиск и фильтры", "Поиск по фразам с фильтрами по типу сообщений и периоду времени."),
        ("arrow.down.circle.fill", .purple, "Навигация по непрочитанным", "Кнопка быстрого перехода к первому непрочитанному сообщению в длинных чатах."),
        ("checkmark.message.fill", .teal, "Статусы доставки", "Единый UI статусов сообщений: в очереди, отправлено, доставлено, прочитано, ошибка."),
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 56))
                            .foregroundStyle(.linearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing))
                            .padding(.top, 24)

                        Text("Что нового")
                            .font(.largeTitle.bold())

                        Text("Версия \(version)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // Feature list
                    VStack(spacing: 20) {
                        ForEach(features, id: \.title) { f in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: f.icon)
                                    .font(.title2)
                                    .foregroundColor(f.color)
                                    .frame(width: 36)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(f.title)
                                        .font(.headline)
                                    Text(f.desc)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 24)
                        }
                    }

                    Spacer(minLength: 16)

                    Button(action: { dismiss() }) {
                        Text("Отлично!")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Presentation helper

struct WhatsNewModifier: ViewModifier {
    private static let seenKey = "mesh.whatsNew.seenVersion"

    @State private var showSheet = false
    @State private var versionToShow = ""

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showSheet) {
                WhatsNewView(version: versionToShow)
            }
            .onAppear {
                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                let seen    = UserDefaults.standard.string(forKey: Self.seenKey) ?? ""
                if current != seen {
                    versionToShow = current
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        showSheet = true
                        UserDefaults.standard.set(current, forKey: Self.seenKey)
                    }
                }
            }
    }
}

extension View {
    func whatsNewOnUpdate() -> some View {
        modifier(WhatsNewModifier())
    }
}

#Preview {
    WhatsNewView(version: "1.5.2")
}
