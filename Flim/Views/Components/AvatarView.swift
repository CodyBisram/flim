import SwiftUI

/// A user's avatar as a circle: their real profile photo when they have one, falling back to the
/// accent-tinted monogram initial (also shown while the image loads). One component for every
/// social surface (Activity rows, roll rosters, discover/follow lists) so "real friends, real
/// faces" is consistent instead of hand-rolled monograms per screen.
///
/// Resolves the signed URL itself via FeedService (app-root injected, so available anywhere),
/// keyed on the storage path so CachedImage dedups the same avatar across many rows and across
/// re-renders. Cheap to drop into a list row.
struct AvatarView: View {
    /// The avatar's storage path (`UserProfile.avatarPath` / `AppUser.avatarPath`); nil shows the initial.
    let path: String?
    /// Used for the fallback initial. Pass the username or handle; leading "@" is stripped.
    let name: String?
    var size: CGFloat = 36

    @Environment(FeedService.self) private var feed
    @State private var url: URL?

    private var initial: String {
        let cleaned = (name ?? "?").drop(while: { $0 == "@" })
        return String(cleaned.prefix(1)).uppercased()
    }

    /// A stable per-user hue derived from the name, so someone with no photo gets a consistent
    /// color that's theirs (like Gmail's colored initials) rather than everyone sharing the one
    /// amber. Deterministic and offline: same input always maps to the same color. Mirrors the
    /// roll-cover gradient's approach.
    private var fallbackColor: Color {
        let sum = (name ?? "?").unicodeScalars.reduce(0) { $0 + Int($1.value) }
        // Multiply by 137 (~the golden angle) before wrapping: this maps similar letter-sums to
        // widely-separated hues, so a room full of avatars reads as distinct colors instead of
        // clustering into muddy olives the way a raw `sum % 360` does.
        let hue = Double((sum * 137) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }

    var body: some View {
        Circle()
            .fill(fallbackColor)
            .frame(width: size, height: size)
            .overlay {
                if let url {
                    CachedImage(url: url, maxPixel: size * 3, cacheKey: path) {
                        $0.resizable().scaledToFill()
                    } placeholder: {
                        initialLabel
                    }
                } else {
                    initialLabel
                }
            }
            .clipShape(Circle())
            .task(id: path) {
                guard let path else { url = nil; return }
                url = await feed.signedURL(for: path)
            }
    }

    private var initialLabel: some View {
        Text(initial)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.white)
    }
}
