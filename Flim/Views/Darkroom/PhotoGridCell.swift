import SwiftUI

struct PhotoGridCell: View {
    let photo: Photo
    let signedURL: URL?

    var body: some View {
        ZStack {
            if photo.isReady, let url = signedURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity.animation(.easeIn(duration: 0.6)))
                    case .failure:
                        errorPlaceholder
                    default:
                        developingPlaceholder
                    }
                }
                .clipped()
            } else {
                developingPlaceholder
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var developingPlaceholder: some View {
        ZStack {
            Color(red: 0.08, green: 0.06, blue: 0.05)
            GrainOverlay()
            VStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .font(.system(size: 14, weight: .ultraLight))
                    .foregroundStyle(FlimTheme.accent.opacity(0.8))

                // TimelineView fires once per second — no external timer needed
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(countdown(at: timeline.date))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.35))
                }

                Text("DEVELOPING")
                    .font(.system(size: 8, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.25))
            }
        }
    }

    private var errorPlaceholder: some View {
        Color(white: 0.1)
            .overlay(
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color(white: 0.3))
            )
    }

    private func countdown(at date: Date) -> String {
        let seconds = max(0, Int(photo.developsAt.timeIntervalSince(date)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - Film grain

struct GrainOverlay: View {
    var body: some View {
        Canvas { context, size in
            let count = Int(size.width * size.height / 80)
            for _ in 0..<count {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let dot = CGRect(x: x, y: y, width: 1.2, height: 1.2)
                let alpha = Double.random(in: 0.03...0.12)
                context.fill(Path(dot), with: .color(.white.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
        .blendMode(.screen)
    }
}
