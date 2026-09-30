import Testing
import Foundation
@testable import Flim

/// The on-disk profile an offline or fast launch boots from. The one rule that matters most:
/// it can never put one account's profile on screen for another.
struct ProfileCacheTests {
    /// A private directory per test, so nothing here reads or writes the real cache.
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProfileCacheTests-\(UUID().uuidString)", isDirectory: true)

    private func profile(id: UUID = UUID(), username: String = "someone") -> AppUser {
        AppUser(id: id, email: "someone@example.com", username: username, inviteCode: "ABC123",
                createdAt: Date(timeIntervalSince1970: 1_758_000_000.25), bio: "hi",
                avatarPath: "a/avatar-1.jpg", displayName: "Some One", coverPath: nil,
                displayedBadges: ["founding_100"], accentColor: "amber")
    }

    @Test("a saved profile comes back unchanged for the same account")
    func roundTrip() {
        defer { ProfileCache.clearAll(root: root) }
        let saved = profile()
        ProfileCache.save(saved, root: root)
        #expect(ProfileCache.load(for: saved.id, root: root) == saved)
    }

    @Test("a later save replaces the earlier one")
    func overwrite() {
        defer { ProfileCache.clearAll(root: root) }
        let id = UUID()
        ProfileCache.save(profile(id: id, username: "before"), root: root)
        ProfileCache.save(profile(id: id, username: "after"), root: root)
        #expect(ProfileCache.load(for: id, root: root)?.username == "after")
    }

    @Test("another account never gets this one's profile")
    func refusesDifferentAccount() {
        defer { ProfileCache.clearAll(root: root) }
        ProfileCache.save(profile(), root: root)
        #expect(ProfileCache.load(for: UUID(), root: root) == nil)
    }

    @Test("a file holding a different account's row is refused even under the asked-for name")
    func refusesMismatchedContents() throws {
        defer { ProfileCache.clearAll(root: root) }
        let asked = UUID()
        let stranger = profile()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(stranger)
        try data.write(to: root.appendingPathComponent("\(asked.uuidString.lowercased()).json"))
        #expect(ProfileCache.load(for: asked, root: root) == nil)
    }

    @Test("saving one account removes any other account's file")
    func saveKeepsOnlyOneAccount() {
        defer { ProfileCache.clearAll(root: root) }
        let departed = profile()
        let current = profile()
        ProfileCache.save(departed, root: root)
        ProfileCache.save(current, root: root)
        #expect(ProfileCache.load(for: departed.id, root: root) == nil)
        #expect(ProfileCache.load(for: current.id, root: root) == current)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(files == ["\(current.id.uuidString.lowercased()).json"])
    }

    @Test("signing out leaves nothing behind for anyone")
    func clearedOnSignOut() {
        let first = profile()
        let second = profile()
        ProfileCache.save(first, root: root)
        ProfileCache.save(second, root: root)
        ProfileCache.clearAll(root: root)
        #expect(ProfileCache.load(for: first.id, root: root) == nil)
        #expect(ProfileCache.load(for: second.id, root: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("an unreadable file is no profile, not a crash")
    func corruptFile() throws {
        defer { ProfileCache.clearAll(root: root) }
        let id = UUID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("\(id.uuidString.lowercased()).json"))
        #expect(ProfileCache.load(for: id, root: root) == nil)
    }

    @Test("no directory at all reads as no profile")
    func missingRoot() {
        #expect(ProfileCache.load(for: UUID(), root: nil) == nil)
        #expect(ProfileCache.load(for: UUID(), root: root) == nil)
    }
}
