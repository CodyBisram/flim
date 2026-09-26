import Foundation

/// Two limits PostgREST imposes that nothing in the app enforced (engineering audit, 2026-09-19).
///
/// An `.in()` list travels in the URL, so a list that scales with a person's history (every
/// post they have made, everyone they follow) eventually outgrows what the gateway accepts and
/// the whole request fails, not just the tail. And a read with no `.range()` is silently capped
/// at 1000 rows, which is how a "whole roll" list once lost photos and how an edge function
/// lost its cohort. Neither bites at today's numbers; both bite without warning later.
enum QueryBatch {
    /// 200 UUIDs is about 7.5KB of URL, comfortably under every gateway's default.
    static let inListLimit = 200
    static let pageSize = 1000

    /// Runs `fetch` once per chunk of `values` and concatenates. A per-query `.limit()` or
    /// `.order()` inside `fetch` then applies per chunk; callers that need a global one sort
    /// and prefix the result themselves.
    static func inChunks<T>(_ values: [String], size: Int = inListLimit,
                            _ fetch: ([String]) async throws -> [T]) async rethrows -> [T] {
        guard !values.isEmpty else { return [] }
        var out: [T] = []
        for chunk in values.chunked(into: size) {
            out.append(contentsOf: try await fetch(chunk))
        }
        return out
    }

    /// `inChunks` for writes: a delete or update keyed on a list.
    static func forEachChunk(_ values: [String], size: Int = inListLimit,
                             _ run: ([String]) async throws -> Void) async rethrows {
        for chunk in values.chunked(into: size) {
            try await run(chunk)
        }
    }

    /// Reads every row of a query that would otherwise stop at PostgREST's 1000-row cap.
    /// `page` receives the inclusive row range to apply with `.range(from:to:)`, and must also
    /// `.order` on a key unique within its filter: an unordered or tie-prone read may return
    /// rows in a different order per request, so pages past the first skip some and repeat
    /// others.
    static func allPages<T>(size: Int = pageSize,
                            _ page: (_ from: Int, _ to: Int) async throws -> [T]) async rethrows -> [T] {
        var out: [T] = []
        var from = 0
        while true {
            let rows = try await page(from, from + size - 1)
            out.append(contentsOf: rows)
            if rows.count < size { return out }
            from += size
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
