import Testing
import Foundation
@testable import Flim

/// `DarkroomView`'s manual `Photo: Equatable` conformance is written out by hand because Swift can
/// only synthesize `Equatable` in the same file a type is declared in, and this pass does not own
/// `Photo.swift`. A model file can grow a new stored property (`burstGroup`, `sharpness`,
/// `quality`, `phash`, `isMiss` all landed after the comparison did) with nothing at the compiler
/// level to notice that the hand-written `==` was not updated to match: a real change in a field
/// Equatable ignores makes `.onChange(of: vm.photos)` see "the same array" and the Darkroom grid
/// silently keeps a stale dead-frame verdict on screen.
///
/// This pins the comparison against `Photo`'s actual stored properties via `Mirror`, rather than
/// against a hand-copied field list here that would rot exactly the same way the `==` itself did:
///
///  1. `everyStoredPropertyHasAMutator` fails by NAME the moment a new stored property appears on
///     `Photo` and this file has not been taught how to vary it, before that property's coverage
///     can even be checked.
///  2. `equatableNoticesAChangeInEveryStoredProperty` then flips one field at a time and asserts
///     `Photo`'s `==` reports a difference, which fails if a field exists but was left out of the
///     hand-written comparison.
///
/// Together, a stored property added to `Photo` without being wired into BOTH this file's mutator
/// table AND `DarkroomView`'s `==` fails loudly here instead of silently shipping a stale grid.
struct PhotoEquatableCoverageTests {

    private func basePhoto() -> Photo {
        Photo(id: UUID(), userId: UUID(), rollId: UUID(),
              storagePath: "photos/base.jpg",
              thumbPath: "photos/base-thumb.jpg",
              feedPath: "photos/base-feed.jpg",
              takenAt: Date(timeIntervalSince1970: 1_700_000_000),
              developsAt: Date(timeIntervalSince1970: 1_700_010_000),
              isDeveloped: true,
              caption: "the base caption",
              isSorted: true,
              burstGroup: UUID(),
              sharpness: 0.4,
              quality: 0.6,
              phash: 42,
              isMiss: false)
    }

    /// One closure per stored field on `Photo`, each returning a copy that differs from its input
    /// in EXACTLY that field. Keyed by the field's own name so it can be checked against `Mirror`'s
    /// own names below, rather than trusting this list to have kept up on its own.
    private func mutators(base: Photo) -> [String: (Photo) -> Photo] {
        [
            "id": { p in Photo(id: UUID(), userId: p.userId, rollId: p.rollId,
                               storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                               takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                               caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                               sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "userId": { p in Photo(id: p.id, userId: UUID(), rollId: p.rollId,
                                   storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                                   takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                   caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                                   sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "rollId": { p in Photo(id: p.id, userId: p.userId, rollId: UUID(),
                                   storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                                   takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                   caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                                   sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "storagePath": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                        storagePath: "photos/changed.jpg", thumbPath: p.thumbPath, feedPath: p.feedPath,
                                        takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                        caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                                        sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "thumbPath": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                      storagePath: p.storagePath, thumbPath: "photos/changed-thumb.jpg", feedPath: p.feedPath,
                                      takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                      caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                                      sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "feedPath": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                     storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: "photos/changed-feed.jpg",
                                     takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                     caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                                     sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "takenAt": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                    storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                                    takenAt: p.takenAt.addingTimeInterval(1), developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                    caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                                    sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "developsAt": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                       storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                                       takenAt: p.takenAt, developsAt: p.developsAt.addingTimeInterval(1), isDeveloped: p.isDeveloped,
                                       caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                                       sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "isDeveloped": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                        storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                                        takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: !p.isDeveloped,
                                        caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                                        sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "caption": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                    storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                                    takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                    caption: "a different caption", isSorted: p.isSorted, burstGroup: p.burstGroup,
                                    sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "isSorted": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                     storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                                     takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                     caption: p.caption, isSorted: !p.isSorted, burstGroup: p.burstGroup,
                                     sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "burstGroup": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                       storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                                       takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                       caption: p.caption, isSorted: p.isSorted, burstGroup: UUID(),
                                       sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "sharpness": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                      storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                                      takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                      caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                                      sharpness: (p.sharpness ?? 0) + 0.1, quality: p.quality, phash: p.phash, isMiss: p.isMiss) },
            "quality": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                    storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                                    takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                    caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                                    sharpness: p.sharpness, quality: (p.quality ?? 0) + 0.1, phash: p.phash, isMiss: p.isMiss) },
            "phash": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                  storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                                  takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                  caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                                  sharpness: p.sharpness, quality: p.quality, phash: (p.phash ?? 0) + 1, isMiss: p.isMiss) },
            "isMiss": { p in Photo(id: p.id, userId: p.userId, rollId: p.rollId,
                                   storagePath: p.storagePath, thumbPath: p.thumbPath, feedPath: p.feedPath,
                                   takenAt: p.takenAt, developsAt: p.developsAt, isDeveloped: p.isDeveloped,
                                   caption: p.caption, isSorted: p.isSorted, burstGroup: p.burstGroup,
                                   sharpness: p.sharpness, quality: p.quality, phash: p.phash, isMiss: !(p.isMiss ?? false)) }
        ]
    }

    @Test("every stored property on Photo has a mutator in this file's coverage table")
    func everyStoredPropertyHasAMutator() {
        let base = basePhoto()
        let mirrorNames = Set(Mirror(reflecting: base).children.compactMap(\.label))
        let mutatorNames = Set(mutators(base: base).keys)
        let uncovered = mirrorNames.subtracting(mutatorNames)
        #expect(uncovered.isEmpty,
                """
                Photo grew a stored property with no mutator here to exercise it: \(uncovered.sorted()). \
                Add a case to PhotoEquatableCoverageTests.mutators AND to DarkroomView's Photo == before \
                this can pass.
                """)
    }

    @Test("Photo's Equatable conformance notices a change in every stored property")
    func equatableNoticesAChangeInEveryStoredProperty() {
        let base = basePhoto()
        for (name, mutate) in mutators(base: base) {
            let changed = mutate(base)
            #expect(base != changed,
                    """
                    DarkroomView's Photo == did not notice a change in '\(name)': a real change to \
                    this field will not redraw the Darkroom grid.
                    """)
        }
    }
}
