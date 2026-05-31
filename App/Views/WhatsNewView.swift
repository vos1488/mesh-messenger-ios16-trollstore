import SwiftUI

// Shown once per version after an update is applied
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    let version: String

    private let features: [(icon: String, color: Color, title: String, desc: String)] = [
        ("checkmark.shield.fill", .blue,   "Stage 1 завершён",   "Закрыты ключевые задачи стабилизации ядра и усилена надёжность доставки."),
        ("arrow.clockwise.circle.fill", .green, "Надёжная доставка", "Единый retry/backoff для сообщений, файлов, ACK и read-receipt при потере маршрута."),
        ("bolt.horizontal.circle.fill", .orange, "Быстрый старт", "Оптимизирован cold start, снижена нагрузка discovery, добавлен startup smoke-check."),
        ("bubble.left.and.bubble.right.fill", .purple, "Чаты без дублей", "После перезапуска чаты и outbox восстанавливаются корректно без дублей."),
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
    WhatsNewView(version: "1.3")
}
