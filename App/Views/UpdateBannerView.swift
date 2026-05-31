import SwiftUI

/// Compact top banner shown when a new app version is available.
struct UpdateBannerView: View {
    @ObservedObject var checker = UpdateChecker.shared
    @State private var expanded = false

    var body: some View {
        if checker.isUpdateAvailable, let latest = checker.latestVersion {
            VStack(alignment: .leading, spacing: 0) {
                // ── Main row ──
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Доступно обновление \(latest)")
                            .font(.callout.bold())
                            .foregroundStyle(.white)
                        Text("Установлена: \(checker.currentVersionString)  •  \(checker.installerType.displayName)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    Spacer()

                    Button(checker.isInstallingUpdate ? "Загрузка…" : (checker.installerType == .trollstore ? "Установить" : "Скачать")) {
                        checker.triggerInstall()
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.2), in: Capsule())
                    .foregroundStyle(.white)
                    .disabled(checker.isInstallingUpdate)

                    if checker.releaseNotes?.isEmpty == false {
                        Button {
                            withAnimation(.spring(response: 0.3)) { expanded.toggle() }
                        } label: {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)

                // ── Expandable release notes ──
                if expanded, let notes = checker.releaseNotes, !notes.isEmpty {
                    Divider().overlay(.white.opacity(0.25))
                    ScrollView {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .frame(maxHeight: 130)
                }
            }
            .background(
                LinearGradient(colors: [Color(red: 0.10, green: 0.45, blue: 0.95),
                                        Color(red: 0.05, green: 0.30, blue: 0.80)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .blue.opacity(0.35), radius: 10, x: 0, y: 5)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .overlay(alignment: .bottomLeading) {
                if let status = checker.installStatusText, checker.isInstallingUpdate {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
        }
    }
}

// MARK: - Settings update section helper

struct UpdateSettingsSection: View {
    @ObservedObject var checker = UpdateChecker.shared
    @State private var showTokenAlert = false
    @State private var tokenInput = ""

    var body: some View {
        Section {
            // Status row
            HStack {
                Label("Версия", systemImage: "info.circle")
                Spacer()
                Text(checker.currentVersionString).foregroundStyle(.secondary)
            }

            HStack {
                Label("Установлено через", systemImage: "wrench.and.screwdriver")
                Spacer()
                Text(checker.installerType.displayName).foregroundStyle(.secondary)
            }

            if let latest = checker.latestVersion {
                HStack {
                    Label("Последний релиз", systemImage: "tag")
                    Spacer()
                    Text(latest)
                        .foregroundStyle(checker.isUpdateAvailable ? .orange : .green)
                }

                HStack {
                    Label("Статус", systemImage: checker.isUpdateAvailable ? "arrow.down.circle" : "checkmark.circle")
                    Spacer()
                    Text(checker.isUpdateAvailable ? "Доступно обновление" : "Установлена актуальная версия")
                        .font(.caption)
                        .foregroundStyle(checker.isUpdateAvailable ? .orange : .green)
                }
            }

            if let checkedAt = checker.lastCheckedAt {
                HStack {
                    Label("Последняя проверка", systemImage: "clock")
                    Spacer()
                    Text(checkedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Error
            if let err = checker.lastCheckError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Actions
            Button {
                Task { await checker.checkForUpdates(force: true) }
            } label: {
                HStack {
                    if checker.isChecking {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(checker.isChecking ? "Проверяем…" : "Проверить обновления")
                }
            }
            .disabled(checker.isChecking)

            if checker.isUpdateAvailable {
                Button(checker.isInstallingUpdate ? "Загрузка IPA…" : (checker.installerType == .trollstore ? "Установить обновление" : "Скачать обновление")) {
                    checker.triggerInstall()
                }
                .foregroundStyle(.blue)
                .disabled(checker.isInstallingUpdate)
            }

            if let status = checker.installStatusText, checker.isInstallingUpdate {
                Label(status, systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // GitHub token input
            Button {
                tokenInput = checker.githubToken
                showTokenAlert = true
            } label: {
                Label(checker.githubToken.isEmpty ? "Добавить GitHub Token" : "GitHub Token: ****",
                      systemImage: "key")
            }
        } header: {
            Text("Обновления")
        } footer: {
            Text(checker.installerType.installInstructions)
                .font(.caption)
        }
        .alert("GitHub Personal Access Token", isPresented: $showTokenAlert) {
            TextField("ghp_xxxx…", text: $tokenInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Сохранить") { checker.githubToken = tokenInput }
            Button("Очистить", role: .destructive) {
                tokenInput = ""
                checker.githubToken = ""
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Для публичного репозитория токен не нужен.\nДобавляйте токен только если используете приватный форк (fine-grained PAT с правом Contents: Read).")
        }
    }
}
