import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    private enum SearchTypeFilter: String, CaseIterable, Identifiable {
        case all
        case text
        case files

        var id: String { rawValue }
    }

    private enum SearchDateFilter: String, CaseIterable, Identifiable {
        case all
        case day
        case week
        case month

        var id: String { rawValue }
    }

    let peer: PeerEntry
    @EnvironmentObject var store: NodeStore
    @State private var inputText = ""
    @State private var isShowingFileImporter = false
    @State private var showClearConfirm = false
    @State private var searchText = ""
    @State private var searchType: SearchTypeFilter = .all
    @State private var searchDate: SearchDateFilter = .all
    @State private var visibleLimit = 80
    @State private var isLoadingOlderBatch = false
    @State private var replyingToMessage: ChatMessage?
    @State private var forwardingMessage: ChatMessage?
    @State private var typingStopTask: Task<Void, Never>?

    private let pageSize = 80

    private var currentPeer: PeerEntry {
        store.peers.first(where: { $0.peerID.value == peer.peerID.value }) ?? peer
    }

    private var messages: [ChatMessage] {
        store.messages[peer.peerID.value] ?? []
    }

    private var threadSettings: ChatThreadSettings {
        store.threadSettings(for: peer.peerID.value)
    }

    private var filteredMessages: [ChatMessage] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date()
        return messages.filter { msg in
            if !q.isEmpty, !msg.text.lowercased().contains(q) {
                return false
            }
            switch searchType {
            case .all:
                break
            case .text:
                if msg.fileID != nil { return false }
            case .files:
                if msg.fileID == nil { return false }
            }
            switch searchDate {
            case .all:
                break
            case .day:
                if now.timeIntervalSince(msg.timestamp) > 86_400 { return false }
            case .week:
                if now.timeIntervalSince(msg.timestamp) > 7 * 86_400 { return false }
            case .month:
                if now.timeIntervalSince(msg.timestamp) > 30 * 86_400 { return false }
            }
            return true
        }
    }

    private var displayedMessages: [ChatMessage] {
        Array(filteredMessages.suffix(max(pageSize, visibleLimit)))
    }

    private var hasOlderMessages: Bool {
        filteredMessages.count > displayedMessages.count
    }

    private var firstUnreadMessageID: UUID? {
        filteredMessages.first(where: { !$0.isMe && !$0.isRead })?.id
    }

    private var unreadInFilteredCount: Int {
        filteredMessages.filter { !$0.isMe && !$0.isRead }.count
    }

    private var forwardCandidates: [PeerEntry] {
        store.peers
            .filter { $0.peerID.value != peer.peerID.value }
            .sorted { a, b in
                let aLast = store.messages[a.peerID.value]?.last?.timestamp ?? a.lastSeen
                let bLast = store.messages[b.peerID.value]?.last?.timestamp ?? b.lastSeen
                return aLast > bLast
            }
    }

    private var headerPresenceText: String {
        if store.isPeerTyping(peer.peerID.value) {
            return "печатает…"
        }
        return store.peerPresenceText(peer.peerID.value)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let active = store.activeCall, active.peerID == peer.peerID.value {
                callBanner(active)
            }
            if !messages.isEmpty {
                searchBar
            }
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if let unreadID = firstUnreadMessageID, unreadInFilteredCount > 0 {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation {
                                    proxy.scrollTo(unreadID, anchor: .center)
                                }
                            } label: {
                                Label("К первому непрочитанному (\(unreadInFilteredCount))", systemImage: "arrow.down.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if hasOlderMessages {
                                historyPreloadRow
                            }
                            if displayedMessages.isEmpty {
                                if messages.isEmpty {
                                    emptyConversation
                                } else {
                                    emptySearchState
                                }
                            }
                            ForEach(displayedMessages) { msg in
                                MessageBubble(message: msg, fileProgress: msg.fileID.flatMap { store.fileProgress[$0] })
                                    .id(msg.id)
                                    .contextMenu {
                                        Button {
                                            replyingToMessage = msg
                                        } label: {
                                            Label("Ответить", systemImage: "arrowshape.turn.up.left")
                                        }
                                        Button {
                                            forwardingMessage = msg
                                        } label: {
                                            Label("Переслать", systemImage: "arrowshape.turn.up.right")
                                        }
                                        Button(role: .destructive) {
                                            store.deleteLocalMessage(peerID: peer.peerID.value, messageID: msg.id)
                                        } label: {
                                            Label("Удалить у себя", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: messages.count) { _ in
                        if let last = displayedMessages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        visibleLimit = pageSize
                        if let last = displayedMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                        store.markConversationRead(peerID: peer.peerID.value)
                    }
                    .onChange(of: searchText) { _ in
                        visibleLimit = pageSize
                    }
                    .onChange(of: searchType) { _ in
                        visibleLimit = pageSize
                    }
                    .onChange(of: searchDate) { _ in
                        visibleLimit = pageSize
                    }
                }
            }

            Divider()
            if let reply = replyingToMessage {
                replyPreview(reply)
            }
            inputBar
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    PeerAvatarView(peerID: currentPeer.peerID.value, size: 32, isConnected: currentPeer.isConnected)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(currentPeer.nickname)
                            .font(.headline)
                        Text(headerPresenceText)
                            .font(.caption2)
                            .foregroundStyle(store.isPeerTyping(peer.peerID.value) ? .green : .secondary)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    store.startVoiceCall(to: currentPeer)
                } label: {
                    Image(systemName: "phone.fill")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        store.setChatPinned(peerID: peer.peerID.value, pinned: !threadSettings.isPinned)
                    } label: {
                        Label(threadSettings.isPinned ? "Открепить чат" : "Закрепить чат", systemImage: threadSettings.isPinned ? "pin.slash" : "pin")
                    }
                    Button {
                        store.setChatMuted(peerID: peer.peerID.value, muted: !threadSettings.isMuted)
                    } label: {
                        Label(threadSettings.isMuted ? "Включить звук" : "Без звука", systemImage: threadSettings.isMuted ? "bell" : "bell.slash")
                    }
                    Button {
                        store.setChatArchived(peerID: peer.peerID.value, archived: !threadSettings.isArchived)
                    } label: {
                        Label(threadSettings.isArchived ? "Из архива" : "В архив", systemImage: threadSettings.isArchived ? "tray.and.arrow.up" : "archivebox")
                    }
                    Button {
                        if store.unreadCount(for: currentPeer) > 0 {
                            store.markConversationRead(peerID: peer.peerID.value)
                        } else {
                            store.markConversationUnread(peerID: peer.peerID.value)
                        }
                    } label: {
                        Label(store.unreadCount(for: currentPeer) > 0 ? "Отметить прочитанным" : "Отметить непрочитанным", systemImage: "envelope.badge")
                    }
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Очистить чат", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Очистить историю переписки?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) {
                store.clearChat(peerID: peer.peerID.value)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все сообщения с \(currentPeer.nickname) будут удалены. Это действие нельзя отменить.")
        }
        .onChange(of: messages.count) { _ in
            store.markConversationRead(peerID: peer.peerID.value)
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            store.sendFile(at: url, to: currentPeer)
        }
        .sheet(item: $forwardingMessage) { message in
            NavigationStack {
                List(forwardCandidates) { candidate in
                    Button {
                        forward(message: message, to: candidate)
                    } label: {
                        HStack(spacing: 10) {
                            PeerAvatarView(peerID: candidate.peerID.value, size: 34, isConnected: candidate.isConnected)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.nickname)
                                    .foregroundStyle(.primary)
                                Text(candidate.peerID.value)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                }
                .navigationTitle("Переслать сообщение")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Отмена") {
                            forwardingMessage = nil
                        }
                    }
                }
            }
        }
        .onChange(of: inputText) { text in
            handleTypingInputChange(text)
        }
        .onDisappear {
            typingStopTask?.cancel()
            typingStopTask = nil
            store.sendTyping(isTyping: false, to: currentPeer)
        }
    }

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск по сообщениям", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))

            HStack(spacing: 8) {
                Menu {
                    ForEach(SearchTypeFilter.allCases) { filter in
                        Button {
                            searchType = filter
                        } label: {
                            Label(typeTitle(filter), systemImage: searchType == filter ? "checkmark" : "line.3.horizontal.decrease.circle")
                        }
                    }
                } label: {
                    Label("Тип: \(typeTitle(searchType))", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Menu {
                    ForEach(SearchDateFilter.allCases) { filter in
                        Button {
                            searchDate = filter
                        } label: {
                            Label(dateTitle(filter), systemImage: searchDate == filter ? "checkmark" : "calendar")
                        }
                    }
                } label: {
                    Label("Период: \(dateTitle(searchDate))", systemImage: "calendar")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                if !searchText.isEmpty || searchType != .all || searchDate != .all {
                    Button("Сброс") {
                        searchText = ""
                        searchType = .all
                        searchDate = .all
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var historyPreloadRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Подгружаем ранние сообщения…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .onAppear {
            loadOlderHistoryBatch()
        }
    }

    private var emptySearchState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Ничего не найдено")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func callBanner(_ call: ActiveCallSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Звонок: \(phaseText(call.phase))")
                    .font(.subheadline)
                    .bold()
                if let startedAt = call.startedAt {
                    Text("Начат \(callTimeString(startedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Завершить", role: .destructive) {
                store.endCurrentCall()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var emptyConversation: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Начните разговор")
                .font(.title3)
                .bold()
            Text("Сообщения передаются напрямую\nбез серверов")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Button {
                isShowingFileImporter = true
            } label: {
                Image(systemName: "paperclip.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
            }

            TextField("Сообщение…", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit { sendMessage() }

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(inputText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : Color.accentColor)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func replyPreview(_ message: ChatMessage) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ответ на \(message.isMe ? "ваше сообщение" : message.senderNickname)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(excerpt(from: message.text))
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
            Spacer()
            Button {
                replyingToMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typingStopTask?.cancel()
        typingStopTask = nil
        store.sendTyping(isTyping: false, to: currentPeer)
        if let reply = replyingToMessage {
            let sender = reply.isMe ? "Вы" : reply.senderNickname
            let quoted = "↪ \(sender): \(excerpt(from: reply.text))\n\(text)"
            store.send(text: quoted, to: currentPeer)
            replyingToMessage = nil
        } else {
            store.send(text: text, to: currentPeer)
        }
        inputText = ""
    }

    private func forward(message: ChatMessage, to candidate: PeerEntry) {
        let forwardText = "↪ Переслано от \(message.senderNickname):\n\(message.text)"
        store.send(text: forwardText, to: candidate)
        forwardingMessage = nil
    }

    private func excerpt(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(90))
    }

    private func handleTypingInputChange(_ text: String) {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        typingStopTask?.cancel()
        typingStopTask = nil
        if hasText {
            store.sendTyping(isTyping: true, to: currentPeer)
            let peer = currentPeer
            typingStopTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                store.sendTyping(isTyping: false, to: peer)
            }
        } else {
            store.sendTyping(isTyping: false, to: currentPeer)
        }
    }

    private func loadOlderHistoryBatch() {
        guard hasOlderMessages, !isLoadingOlderBatch else { return }
        isLoadingOlderBatch = true
        DispatchQueue.main.async {
            visibleLimit += pageSize
            isLoadingOlderBatch = false
        }
    }

    private func typeTitle(_ filter: SearchTypeFilter) -> String {
        switch filter {
        case .all: return "Все"
        case .text: return "Текст"
        case .files: return "Файлы"
        }
    }

    private func dateTitle(_ filter: SearchDateFilter) -> String {
        switch filter {
        case .all: return "Любой"
        case .day: return "24 часа"
        case .week: return "7 дней"
        case .month: return "30 дней"
        }
    }

    private func callTimeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func phaseText(_ phase: ActiveCallSession.Phase) -> String {
        switch phase {
        case .ringing: return "ожидание ответа"
        case .connecting: return "подключение"
        case .active: return "активен"
        case .ended: return "завершён"
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var fileProgress: Double? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isMe { Spacer(minLength: 40) }

            VStack(alignment: message.isMe ? .trailing : .leading, spacing: 2) {
                if !message.isMe {
                    Text(message.senderNickname)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                Text(message.text)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(message.isMe ? Color.accentColor : Color(.secondarySystemBackground))
                    )
                    .foregroundStyle(message.isMe ? .white : .primary)
                    .textSelection(.enabled)
                if message.fileID != nil {
                    if let progress = fileProgress, progress < 1 {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 150)
                            .padding(.horizontal, 4)
                    } else {
                        Text("Файл готов")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }

                Text(timeString(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                if message.isMe {
                    HStack(spacing: 3) {
                        Image(systemName: statusIcon(message.status))
                            .font(.caption2)
                        Text(statusText(message.status))
                            .font(.caption2)
                    }
                    .foregroundStyle(statusColor(message.status))
                    .padding(.horizontal, 4)
                }
            }

            if !message.isMe { Spacer(minLength: 40) }
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func statusText(_ status: OutboxStatus) -> String {
        switch status {
        case .queued, .pending: return "в очереди"
        case .sent: return "отправлено"
        case .delivered: return "доставлено"
        case .read: return "прочитано"
        case .failed: return "ошибка"
        case .poisoned: return "остановлено"
        }
    }

    private func statusColor(_ status: OutboxStatus) -> Color {
        switch status {
        case .poisoned: return .orange
        case .failed: return .red
        case .read: return .blue
        case .delivered: return .green
        case .sent, .queued, .pending: return .secondary
        }
    }

    private func statusIcon(_ status: OutboxStatus) -> String {
        switch status {
        case .queued, .pending: return "clock"
        case .sent: return "paperplane"
        case .delivered: return "checkmark.circle"
        case .read: return "eye"
        case .failed: return "exclamationmark.circle"
        case .poisoned: return "xmark.octagon"
        }
    }
}
