import SwiftUI

extension View {
    /// `.refreshable`, with the action run to completion. SwiftUI cancels a refresh's task as
    /// the pull gesture settles (see `DarkroomView.reload`), and every request still in flight
    /// inside it fails with it, so a pull could end having fetched nothing new: a Spotlight
    /// week the team had just published never reached the feed until the app was relaunched.
    /// The action runs in an unstructured task, which does not inherit that cancellation;
    /// awaiting it keeps the spinner up until the reload has landed.
    func refreshableToCompletion(_ action: @escaping @MainActor () async -> Void) -> some View {
        refreshable { await Task { @MainActor in await action() }.value }
    }
}
