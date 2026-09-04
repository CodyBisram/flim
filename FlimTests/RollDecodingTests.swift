import Testing
import Foundation
@testable import Flim

/// `Roll`'s custom `init(from:)`. `rolls.reveal_at` is now the single source of truth for when a
/// roll unlocks, but a server that hasn't sent it yet (rollout ordering, or an older cached
/// response) must fail soft into the pre-existing `created_at + developDelay` formula rather than
/// fail the whole rolls fetch over one missing column.
///
/// `createdAt`/`revealAt` decode through the ambient decoder's own date strategy, exactly like the
/// synthesized initializer this replaces, so these tests configure `.secondsSince1970` rather
/// than asserting anything about the wire format Supabase itself uses (that's the decoder's
/// concern, not this type's).
struct RollDecodingTests {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private func json(id: UUID = UUID(), createdBy: UUID = UUID(),
                      createdAt: TimeInterval, revealAt: TimeInterval? = nil,
                      coverPath: String? = nil) -> Data {
        var fields = [
            "\"id\":\"\(id.uuidString)\"",
            "\"name\":\"Weekend\"",
            "\"invite_code\":\"ABC123\"",
            "\"created_by\":\"\(createdBy.uuidString)\"",
            "\"created_at\":\(createdAt)",
        ]
        if let revealAt { fields.append("\"reveal_at\":\(revealAt)") }
        if let coverPath { fields.append("\"cover_path\":\"\(coverPath)\"") }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    @Test("reveal_at present decodes as the stored revealAt, not re-derived from created_at")
    func revealAtPresentIsUsedDirectly() throws {
        let createdAt: TimeInterval = 1_000_000
        let reveal: TimeInterval = 1_050_000   // deliberately NOT createdAt + developDelay
        let roll = try decoder().decode(Roll.self, from: json(createdAt: createdAt, revealAt: reveal))
        #expect(roll.revealAt == Date(timeIntervalSince1970: reveal))
        #expect(roll.createdAt == Date(timeIntervalSince1970: createdAt))
    }

    @Test("reveal_at missing falls back to created_at + developDelay, not a decode failure")
    func revealAtMissingFallsBackToTheFormula() throws {
        let createdAt: TimeInterval = 1_000_000
        let roll = try decoder().decode(Roll.self, from: json(createdAt: createdAt))
        #expect(roll.revealAt == Date(timeIntervalSince1970: createdAt).addingTimeInterval(Roll.developDelay))
    }

    @Test("cover_path missing still decodes to nil, unaffected by the reveal_at change")
    func coverPathMissingStillDecodesToNil() throws {
        let roll = try decoder().decode(Roll.self, from: json(createdAt: 1_000_000, revealAt: 1_050_000))
        #expect(roll.coverPath == nil)
    }

    @Test("cover_path present decodes through unchanged")
    func coverPathPresentDecodes() throws {
        let roll = try decoder().decode(
            Roll.self, from: json(createdAt: 1_000_000, revealAt: 1_050_000, coverPath: "covers/a.jpg"))
        #expect(roll.coverPath == "covers/a.jpg")
    }
}
