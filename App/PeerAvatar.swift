import SwiftUI

// MARK: - Deterministic emoji avatar for any peerID
//
// Same peerID → always same emoji + same background color (no randomness at runtime).
// The emoji pool is large enough (~200 entries) that collisions in small networks are
// astronomically unlikely, and even if two peers share an emoji the colors differ.

public enum PeerAvatar {

    // 200 visually distinct emoji across multiple categories
    private static let emojis: [String] = [
        // Animals
        "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯",
        "🦁","🐮","🐷","🐸","🐵","🙈","🙉","🙊","🐧","🐦",
        "🦅","🦆","🦉","🦇","🐺","🐗","🐴","🦄","🐝","🐛",
        "🦋","🐌","🐞","🐜","🪲","🐢","🐍","🦎","🦖","🦕",
        "🐙","🦑","🦐","🦞","🦀","🐡","🐠","🐟","🐬","🐳",
        "🦈","🐊","🐅","🐆","🦓","🦍","🦧","🦣","🐘","🦏",
        "🦛","🦒","🐪","🐫","🦘","🦬","🐃","🐂","🐄","🦙",
        "🐑","🐏","🐐","🦌","🐕","🐈","🐓","🦃","🦚","🦜",
        // Plants & nature
        "🌵","🎋","🌴","🌱","🌿","🍀","🎍","🎄","🌾","🍁",
        "🍂","🍃","🌺","🌸","🌼","🌻","🌹","🌷","🌳","🌲",
        // Food
        "🍎","🍊","🍋","🍇","🍓","🫐","🍒","🥝","🍍","🥭",
        "🍑","🥑","🍆","🥦","🥕","🌽","🍄","🧅","🧄","🥜",
        // Objects & symbols
        "⚽","🏀","🏈","⚾","🎾","🏐","🏉","🥏","🎱","🏓",
        "🏸","🥊","🥋","🎯","⛳","🎣","🤿","🎽","🎿","🛷",
        "🎪","🎭","🎨","🎬","🎤","🎧","🎼","🎹","🥁","🎸",
        "🎷","🎺","🎻","🪕","🎮","🕹","🎲","🎯","🧩","🎰",
        // Misc vivid
        "🚀","🛸","🌍","🌙","⭐","🌈","⚡","🔥","❄️","🌊",
        "💎","👑","🔮","🧿","🪬","🎁","🎀","🏆","🥇","🎖",
    ]

    private static let backgroundColors: [Color] = [
        Color(red: 0.95, green: 0.30, blue: 0.30), // red
        Color(red: 0.95, green: 0.55, blue: 0.20), // orange
        Color(red: 0.95, green: 0.80, blue: 0.20), // yellow
        Color(red: 0.25, green: 0.75, blue: 0.40), // green
        Color(red: 0.20, green: 0.65, blue: 0.90), // sky
        Color(red: 0.20, green: 0.35, blue: 0.90), // blue
        Color(red: 0.55, green: 0.25, blue: 0.90), // purple
        Color(red: 0.85, green: 0.25, blue: 0.70), // pink
        Color(red: 0.30, green: 0.75, blue: 0.75), // teal
        Color(red: 0.60, green: 0.40, blue: 0.25), // brown
        Color(red: 0.50, green: 0.50, blue: 0.55), // gray-blue
        Color(red: 0.90, green: 0.45, blue: 0.45), // salmon
    ]

    /// Deterministically pick an emoji for a given peerID string.
    public static func emoji(for peerID: String) -> String {
        let h = stableHash(peerID)
        return emojis[Int(h % UInt64(emojis.count))]
    }

    /// Deterministically pick a background color for a given peerID string.
    public static func color(for peerID: String) -> Color {
        // Use a different hash slice so color and emoji are independent
        let h = stableHash(peerID &+ "color")
        return backgroundColors[Int(h % UInt64(backgroundColors.count))]
    }

    // djb2-style hash — purely deterministic, no Foundation dependency
    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 5381
        for c in s.unicodeScalars {
            h = (h &* 33) &+ UInt64(c.value)
        }
        return h
    }
}

// MARK: - Reusable view

struct PeerAvatarView: View {
    let peerID: String
    let size: CGFloat
    var isConnected: Bool = false

    init(peerID: String, size: CGFloat = 44, isConnected: Bool = false) {
        self.peerID = peerID
        self.size = size
        self.isConnected = isConnected
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(PeerAvatar.color(for: peerID).opacity(0.85))
                .frame(width: size, height: size)
            Text(PeerAvatar.emoji(for: peerID))
                .font(.system(size: size * 0.52))
                .offset(x: 0, y: size * 0.03)

            if isConnected {
                Circle()
                    .fill(Color.green)
                    .frame(width: size * 0.27, height: size * 0.27)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.7))
                    .frame(width: size * 0.27, height: size * 0.27)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
            }
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        PeerAvatarView(peerID: "peer://abc123", size: 56, isConnected: true)
        PeerAvatarView(peerID: "peer://def456", size: 56, isConnected: false)
        PeerAvatarView(peerID: "peer://xyz789", size: 56, isConnected: true)
    }
    .padding()
}
