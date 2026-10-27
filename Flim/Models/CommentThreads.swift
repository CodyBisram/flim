import CoreGraphics
import Foundation

/// A comment that can sit in a thread: a post comment, a roll photo comment, or a post comment
/// with its likes (`CommentInfo`).
protocol ThreadableComment {
    var id: UUID { get }
    /// The top-level comment this one answers, nil for a top-level comment.
    var parentId: UUID? { get }
    var createdAt: Date { get }
}

extension PostComment: ThreadableComment {}
extension PhotoComment: ThreadableComment {}
extension CommentInfo: ThreadableComment {
    var parentId: UUID? { comment.parentId }
    var createdAt: Date { comment.createdAt }
}

/// One top-level comment and the replies under it.
///
/// Threads are one level deep (2026-10-26, owner's choice): a reply to a reply joins the same
/// thread, and its text still opens with the "@name" it answers. The insert trigger flattens on
/// the server; `CommentThreads.build` copes with anything written before it.
struct CommentThread<C: ThreadableComment>: Identifiable {
    /// The top-level comment's id, kept when the comment itself is gone.
    let id: UUID
    /// Nil when the comment was deleted, or is hidden from this viewer by a block. Its replies
    /// still show, under "Comment unavailable", so they read as answers to something.
    let root: C?
    /// Oldest first.
    let replies: [C]

    /// When the conversation began: the comment, or its first surviving reply.
    var startedAt: Date { root?.createdAt ?? replies.first?.createdAt ?? .distantPast }
}

enum CommentThreads {
    /// How many replies a thread shows before "View N more replies".
    static let repliesShownFolded = 2
    /// How far a reply sits in from the comment it answers, in every list that shows threads.
    static let replyIndent: CGFloat = 24

    /// The fold's label: "View 1 more reply", "View 3 more replies".
    static func moreRepliesLabel(_ hidden: Int) -> String {
        "View \(hidden) more \(hidden == 1 ? "reply" : "replies")"
    }

    /// The feed card's line under a comment with replies: "1 reply", "2 replies".
    static func replyCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "reply" : "replies")"
    }

    /// Groups a flat list into threads, top-level comments ordered by `rootsBefore`, replies
    /// always oldest first under theirs. A reply whose comment is not in the list gets a thread
    /// of its own with no root, so it is never shown as a top-level comment of its own.
    static func build<C: ThreadableComment>(
        _ comments: [C],
        rootsBefore: (CommentThread<C>, CommentThread<C>) -> Bool = chronological
    ) -> [CommentThread<C>] {
        var parentOf: [UUID: UUID] = [:]
        for c in comments {
            if let p = c.parentId, p != c.id { parentOf[c.id] = p }
        }
        // Up the parent links to the top. The server keeps threads one level, so this is one hop;
        // the bound only stops a loop in bad data from hanging the screen.
        func rootId(of id: UUID) -> UUID {
            var current = id
            var hops = 0
            while let p = parentOf[current], hops < 8 {
                current = p
                hops += 1
            }
            return current
        }
        var roots: [UUID: C] = [:]
        var replies: [UUID: [C]] = [:]
        for c in comments {
            let top = rootId(of: c.id)
            if top == c.id {
                roots[c.id] = c
            } else {
                replies[top, default: []].append(c)
            }
        }
        return Set(roots.keys).union(replies.keys)
            .map { id in
                CommentThread(id: id, root: roots[id],
                              replies: (replies[id] ?? []).sorted(by: oldestFirst))
            }
            .sorted(by: rootsBefore)
    }

    /// The threads flattened back to a list: each comment, then its replies.
    static func flattened<C: ThreadableComment>(_ threads: [CommentThread<C>]) -> [C] {
        threads.flatMap { thread in (thread.root.map { [$0] } ?? []) + thread.replies }
    }

    /// The replies a thread shows, and how many "View N more replies" stands for. All of them
    /// once expanded, or when there are no more than `repliesShownFolded`.
    static func visibleReplies<C: ThreadableComment>(
        _ thread: CommentThread<C>, expanded: Bool
    ) -> (shown: [C], hidden: Int) {
        guard !expanded, thread.replies.count > repliesShownFolded else { return (thread.replies, 0) }
        return (Array(thread.replies.prefix(repliesShownFolded)), thread.replies.count - repliesShownFolded)
    }

    /// Conversations in the order they began.
    static func chronological<C: ThreadableComment>(_ a: CommentThread<C>, _ b: CommentThread<C>) -> Bool {
        a.startedAt != b.startedAt ? a.startedAt < b.startedAt : a.id.uuidString < b.id.uuidString
    }

    /// Most-liked comment first, ties oldest first: the "most relevant" order of the feed card and
    /// the post screen. Only the top-level comment's own likes count, so a well-liked reply lifts
    /// nothing and never leaves its thread. A thread whose comment is gone counts as unliked.
    static func byLikes(_ a: CommentThread<CommentInfo>, _ b: CommentThread<CommentInfo>) -> Bool {
        let likesA = a.root?.likeCount ?? 0
        let likesB = b.root?.likeCount ?? 0
        return likesA != likesB ? likesA > likesB : chronological(a, b)
    }

    private static func oldestFirst<C: ThreadableComment>(_ a: C, _ b: C) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id.uuidString < b.id.uuidString
    }
}
