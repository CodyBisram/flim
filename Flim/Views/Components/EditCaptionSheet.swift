import SwiftUI

/// Edits a post's caption. Shared by every screen that shows one of the viewer's own posts
/// (the feed card and the post detail screen), so "what a caption is allowed to be" can't
/// drift between them by editing one copy and not the other.
struct EditCaptionSheet: View {
    @Environment(\.flimAccent) private var accent
    @Binding var caption: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    TextField("Add a caption…", text: $caption, axis: .vertical)
                        .lineLimit(1...5)
                        .flimFont(16, relativeTo: .body).foregroundStyle(.white).tint(accent)
                        .focused($focused)
                        .padding(14)
                        .background(FlimTheme.bgElevated, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 20).padding(.top, 20)
                    Spacer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Edit Caption")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(); dismiss() }
                        .foregroundStyle(accent).fontWeight(.semibold)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(220)])
        .flimSheetSurface()
    }
}
