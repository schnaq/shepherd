import ShepherdCore
import SwiftUI

/// A round avatar with an initials fallback.
///
/// Avatars are the only remote images Shepherd loads, and they degrade to initials whenever
/// the URL is missing or the fetch fails — the app must be fully usable offline (ADR 0006).
struct AvatarView: View {
    /// The account login, used for the initials fallback.
    let login: String
    /// The account's display name, preferred for initials when present.
    var displayName: String?
    /// The avatar URL, when GitHub reported one.
    var url: URL?
    /// The rendered diameter.
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            Circle().fill(fallbackGradient)
            Text(initials)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(Text(displayName ?? login))
    }

    private var fallbackGradient: LinearGradient {
        LinearGradient(
            colors: [Theme.accent, Theme.priority],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var initials: String {
        let source = (displayName?.isEmpty == false ? displayName : nil) ?? login
        let cleaned = source.replacingOccurrences(of: "[bot]", with: "")
        let words = cleaned
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
            .prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        if letters.isEmpty {
            return String(cleaned.prefix(1)).uppercased()
        }
        return letters.joined().uppercased()
    }
}

extension AvatarView {
    /// Builds an avatar for a domain actor.
    /// - Parameters:
    ///   - actor: The author.
    ///   - size: The diameter.
    init(actor: ShepherdCore.Actor, size: CGFloat = 26) {
        self.init(
            login: actor.login,
            displayName: actor.displayName,
            url: actor.avatarURL,
            size: size
        )
    }
}
