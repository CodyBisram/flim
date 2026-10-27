import Testing
import Foundation
@testable import Flim

/// `CommentThreads` decides where every comment sits: under the comment it answers, never above
/// it. The bug it closes: the feed card and the post screen ranked comments by likes, so a liked
/// reply climbed over the comment it answered and read as an answer to nothing (2026-10-26).
@MainActor
struct CommentThreadsTests {

    private let post = UUID()

    private func info(_ id: UUID = UUID(), parent: UUID? = nil, at seconds: TimeInterval, likes: Int = 0) -> CommentInfo {
        CommentInfo(comment: PostComment(id: id, postId: post, userId: UUID(), body: "x",
                                         createdAt: Date(timeIntervalSince1970: seconds), parentId: parent),
                    author: nil, likeCount: likes, likedByMe: false)
    }

    @Test("a liked reply stays under the unliked comment it answers")
    func likedReplyStaysUnderItsComment() {
        let original = info(at: 100)
        let reply = info(parent: original.id, at: 200, likes: 2)
        let laterAnswer = info(parent: original.id, at: 300)
        let ranked = FeedService.rank([reply, laterAnswer, original])
        #expect(ranked.map(\.id) == [original.id, reply.id, laterAnswer.id])
    }

    @Test("conversations rank by their own comment's likes, replies travel with them")
    func threadsRankByRootLikes() {
        let quiet = info(at: 100)
        let quietReply = info(parent: quiet.id, at: 150, likes: 9)
        let liked = info(at: 200, likes: 3)
        let likedReply = info(parent: liked.id, at: 250)
        let ranked = FeedService.rank([quiet, quietReply, liked, likedReply])
        #expect(ranked.map(\.id) == [liked.id, likedReply.id, quiet.id, quietReply.id])
    }

    @Test("the sheet's order is when each conversation began, replies oldest first")
    func chronologicalThreads() {
        let first = info(at: 100)
        let second = info(at: 200)
        let lateReplyToFirst = info(parent: first.id, at: 300)
        let earlyReplyToFirst = info(parent: first.id, at: 250)
        let threads = CommentThreads.build([second, lateReplyToFirst, first, earlyReplyToFirst])
        #expect(threads.map(\.id) == [first.id, second.id])
        #expect(threads[0].replies.map(\.id) == [earlyReplyToFirst.id, lateReplyToFirst.id])
        #expect(threads[1].replies.isEmpty)
    }

    @Test("replies to a deleted comment keep a thread of their own, never shown as top-level")
    func orphanedRepliesKeepTheirThread() {
        let gone = UUID()
        let a = info(parent: gone, at: 200)
        let b = info(parent: gone, at: 300)
        let other = info(at: 100)
        let threads = CommentThreads.build([b, other, a])
        #expect(threads.map(\.id) == [other.id, gone])
        #expect(threads[1].root == nil)
        #expect(threads[1].replies.map(\.id) == [a.id, b.id])
        #expect(threads[1].startedAt == Date(timeIntervalSince1970: 200))
    }

    @Test("a reply to a reply, from before the server flattened them, joins the top thread")
    func nestedReplyFlattens() {
        let top = info(at: 100)
        let reply = info(parent: top.id, at: 200)
        let replyToReply = info(parent: reply.id, at: 300)
        let threads = CommentThreads.build([replyToReply, reply, top])
        #expect(threads.count == 1)
        #expect(threads[0].replies.map(\.id) == [reply.id, replyToReply.id])
    }

    @Test("a loop in the parent links cannot hang the screen")
    func parentLoopTerminates() {
        let a = UUID(), b = UUID()
        let threads = CommentThreads.build([info(a, parent: b, at: 100), info(b, parent: a, at: 200)])
        #expect(CommentThreads.flattened(threads).count == 2)
    }

    @Test("two replies show; past that, the rest fold behind View N more")
    func foldPastTwo() {
        let top = info(at: 0)
        let replies = (1...5).map { info(parent: top.id, at: TimeInterval($0)) }
        let thread = CommentThreads.build([top] + replies)[0]
        let folded = CommentThreads.visibleReplies(thread, expanded: false)
        #expect(folded.shown.map(\.id) == Array(replies.prefix(2)).map(\.id))
        #expect(folded.hidden == 3)
        let open = CommentThreads.visibleReplies(thread, expanded: true)
        #expect(open.shown.count == 5 && open.hidden == 0)
        let small = CommentThreads.build([top] + replies.prefix(2))[0]
        #expect(CommentThreads.visibleReplies(small, expanded: false).hidden == 0)
    }

    @Test("labels count in words")
    func labels() {
        #expect(CommentThreads.moreRepliesLabel(1) == "View 1 more reply")
        #expect(CommentThreads.moreRepliesLabel(3) == "View 3 more replies")
        #expect(CommentThreads.replyCountLabel(1) == "1 reply")
        #expect(CommentThreads.replyCountLabel(2) == "2 replies")
    }

    @Test("a comment row decodes without parent_id, from a database before threads")
    func decodesWithoutParent() throws {
        let json = #"{"id":"\#(UUID())","post_id":"\#(UUID())","user_id":"\#(UUID())","body":"hi","created_at":"2026-10-26T12:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let comment = try decoder.decode(PostComment.self, from: Data(json.utf8))
        #expect(comment.parentId == nil)
    }

    @Test("a reply's Activity row stands for every other row about the same comment")
    func replyRowWins() {
        let reply = UUID()
        let replied: Set<UUID> = [reply]
        #expect(FeedService.shouldGiveWayToReply(.mentioned("@me hi"), commentId: reply, repliedCommentIds: replied))
        #expect(FeedService.shouldGiveWayToReply(.comment("@me hi"), commentId: reply, repliedCommentIds: replied))
        #expect(FeedService.shouldGiveWayToReply(.threadComment("@me hi"), commentId: reply, repliedCommentIds: replied))
        #expect(!FeedService.shouldGiveWayToReply(.replied("@me hi"), commentId: reply, repliedCommentIds: replied))
        #expect(!FeedService.shouldGiveWayToReply(.mentioned("@me hi"), commentId: UUID(), repliedCommentIds: replied))
        #expect(!FeedService.shouldGiveWayToReply(.follow, commentId: nil, repliedCommentIds: replied))
    }
}
