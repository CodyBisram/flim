import SwiftUI

/// The three places, side by side: swipe between them or tap their names. The app opens on
/// Personal, the camera.
enum V2Place: Int, CaseIterable, Identifiable {
    case darkroom, personal, friends

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .darkroom: "Darkroom"
        case .personal: "Personal"
        case .friends: "Friends"
        }
    }

    /// The App Store app's tab for this place. v2 drives the same selection the tab bar does, so
    /// every push destination, widget link and "open the camera" signal that sets a tab lands in
    /// the right place without a second routing table.
    var tab: Int {
        switch self {
        case .personal: 0
        case .darkroom: 1
        case .friends: 3
        }
    }

    /// The place a tab lands in. Rolls (tab 2) open over Personal, where the shelf lives under
    /// the shutter (board 10a).
    static func forTab(_ tab: Int) -> V2Place {
        switch tab {
        case 1: .darkroom
        case 3: .friends
        default: .personal
        }
    }

    /// The tab whose screen v2 shows over the places rather than as one of them.
    static let rollsTab = 2
}

/// Which arrangement a screen gets. Every v2 screen is built for all three at once (owner,
/// 2026-10-27: iPhone Duo and regular iPhones together, always).
enum V2LayoutMode: Equatable {
    /// A regular iPhone: the top row, the place names under it, one place at a time.
    case phone
    /// iPhone Duo closed: short and wide, so the top row moves into a column on the trailing edge
    /// and the main action sits at its foot, near the thumb (board 15a to 15c).
    case outer
    /// iPhone Duo open: regular width. Personal and Darkroom share the display; Friends takes all
    /// of it (board 15d, 15e).
    case inner

    /// Decided by size class and the screen's shape, never by device name or a fixed size: the
    /// handoff draws the Duo at roughly 466 by 678 closed and 626 by 890 open, but says outright
    /// that those are worked out from pixel specs and must not be hardcoded. A phone in portrait
    /// is over twice as tall as it is wide; the Duo's outer display is under one and a half.
    static func resolve(horizontalSizeClass: UserInterfaceSizeClass?, size: CGSize) -> V2LayoutMode {
        if horizontalSizeClass == .regular { return .inner }
        guard size.width > 0 else { return .phone }
        return size.height / size.width < shortAspectThreshold ? .outer : .phone
    }

    /// Between the Duo's outer display (about 1.45) and the shortest current iPhone (about 2.1).
    static let shortAspectThreshold: CGFloat = 1.75

    /// The names in the place row, one group per page. Open, Personal and Darkroom are one place.
    var placeGroups: [[V2Place]] {
        switch self {
        case .phone, .outer: V2Place.allCases.map { [$0] }
        case .inner: [[.personal, .darkroom], [.friends]]
        }
    }

    /// The page a place is on.
    func page(of place: V2Place) -> Int {
        placeGroups.firstIndex { $0.contains(place) } ?? 0
    }

    /// The place a page selects: the first in its group, so opening the inner display's first
    /// page lands on the camera.
    func place(onPage page: Int) -> V2Place {
        let groups = placeGroups
        return groups[min(max(page, 0), groups.count - 1)][0]
    }
}
