import SwiftUI

struct ActiveCallView: View {
    @EnvironmentObject var store: NodeStore
    @State private var elapsed: Int = 0
    @State private var timer: Timer?

    private var call: ActiveCallSession? { store.activeCall }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.18, blue: 0.32), Color(red: 0.04, green: 0.10, blue: 0.20)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Avatar + Name
                VStack(spacing: 16) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 100))
                        .foregroundStyle(.white.opacity(0.85))

                    Text(call?.peerNickname ?? "")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)

                    phaseLabel
                }

                Spacer()

                // Controls
                HStack(spacing: 50) {
                    callButton(
                        systemImage: store.callMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                        label: store.callMicrophoneMuted ? "Откл. микр." : "Микрофон",
                        color: store.callMicrophoneMuted ? .red.opacity(0.8) : .white.opacity(0.2)
                    ) {
                        store.toggleCallMicrophoneMuted()
                    }

                    // End call
                    callButton(
                        systemImage: "phone.down.fill",
                        label: "Завершить",
                        color: .red,
                        size: 72
                    ) {
                        store.endCurrentCall()
                    }

                    callButton(
                        systemImage: store.callSpeakerEnabled ? "speaker.wave.3.fill" : "speaker.slash.fill",
                        label: "Громкость",
                        color: store.callSpeakerEnabled ? .blue.opacity(0.8) : .white.opacity(0.2)
                    ) {
                        store.toggleCallSpeakerEnabled()
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
        .onChange(of: call?.phase) { phase in
            if phase == .active && timer == nil { startTimer() }
            if phase == .ended || phase == nil { stopTimer() }
        }
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch call?.phase {
        case .ringing:
            Text("Вызов…")
                .foregroundStyle(.white.opacity(0.7))
                .font(.title3)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().tint(.white).scaleEffect(0.8)
                Text("Соединение…")
            }
            .foregroundStyle(.white.opacity(0.7))
            .font(.title3)
        case .active:
            Text(formattedElapsed)
                .foregroundStyle(.white)
                .font(.title2.monospacedDigit())
        case .ended:
            Text("Звонок завершён")
                .foregroundStyle(.white.opacity(0.6))
                .font(.title3)
        case .none:
            EmptyView()
        }
    }

    private var formattedElapsed: String {
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func callButton(
        systemImage: String,
        label: String,
        color: Color,
        size: CGFloat = 56,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white)
                }
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func startTimer() {
        guard call?.phase == .active || call?.phase == .connecting else { return }
        elapsed = call?.startedAt.map { -Int($0.timeIntervalSinceNow) } ?? 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed += 1
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
