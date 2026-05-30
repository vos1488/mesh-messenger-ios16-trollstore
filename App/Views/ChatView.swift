import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let peer: PeerEntry
    @EnvironmentObject var store: NodeStore
    @State private var inputText = ""
    @State private var isShowingFileImporter = false

    private var messages: [ChatMessage] {
        store.messages[peer.peerID.value] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if let active = store.activeCall, active.peerID == peer.peerID.value {
                callBanner(active)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if messages.isEmpty {
                            emptyConversation
                        }
                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                    store.markConversationRead(peerID: peer.peerID.value)
                }
            }

            Divider()
            inputBar
        }
        .navigationTitle(peer.nickname)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    store.startVoiceCall(to: peer)
                } label: {
                    Image(systemName: "phone.fill")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(peer.isConnected ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(peer.isConnected ? "Онлайн" : "Офлайн")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            store.sendFile(at: url, to: peer)
        }
    }

    @ViewBuilder
    private func callBanner(_ call: ActiveCallSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Звонок: \(phaseText(call.phase))")
                    .font(.subheadline)
                    .bold()
                if let startedAt = call.startedAt {
                    Text("Начат \(timeString(startedAt))")
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

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.send(text: text, to: peer)
        inputText = ""
    }
}

struct MessageBubble: View {
    let message: ChatMessage

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

                Text(timeString(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                if message.isMe {
                    Text(statusText(message.status))
                        .font(.caption2)
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

    private func phaseText(_ phase: ActiveCallSession.Phase) -> String {
        switch phase {
        case .ringing: return "ожидание ответа"
        case .connecting: return "подключение"
        case .active: return "активен"
        case .ended: return "завершён"
        }
    }

    private func statusText(_ status: OutboxStatus) -> String {
        switch status {
        case .queued, .pending: return "queued"
        case .sent: return "sent"
        case .delivered: return "delivered"
        case .read: return "read"
        case .failed: return "failed"
        }
    }

    private func statusColor(_ status: OutboxStatus) -> Color {
        switch status {
        case .failed: return .red
        case .read: return .blue
        case .delivered: return .green
        case .sent, .queued, .pending: return .secondary
        }
    }
}
