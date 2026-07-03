import SwiftUI

/// A tight icon + value pair — e.g. "👥 1", "✓ Developed", "⏳ Reveals in 4h".
/// Keeps the icon and its label coupled (Gestalt proximity) and consistent everywhere
/// metadata rows appear (rolls, darkroom, feed).
struct MetaChip: View {
    let icon: String
    let text: String
    var color: Color = FlimTheme.textSecondary
    var iconSize: CGFloat = 10
    var textSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: iconSize))
            Text(text).font(.system(size: textSize, weight: .medium))
        }
        .foregroundStyle(color)
    }
}
