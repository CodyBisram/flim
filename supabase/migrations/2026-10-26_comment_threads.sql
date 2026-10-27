-- Comment threads: a reply knows which comment it answers (2026-10-26). NOT YET APPLIED. The
-- owner applies it. Idempotent: safe to re-run. Adds one nullable column to each comment table
-- and changes no existing behaviour by itself: a build that never sends parent_id writes exactly
-- what it wrote before.
--
-- Why. A reply was a comment whose text began with "@name", and nothing tied it to the comment
-- it answered. The feed card and the post screen rank comments by likes, so a liked reply
-- climbed above the comment it was answering and read as an answer to nothing (owner, 2026-10-26:
-- a reply about a game release sat above the comment that announced it). The owner chose real
-- threads over guessing from the "@name" text.
--
-- What.
--   1. post_comments.parent_id and photo_comments.parent_id: the top-level comment a reply
--      belongs to, NULL for a top-level comment. Deliberately NO foreign key: when a comment
--      with replies is deleted, its replies keep the id, and the app shows "Comment unavailable"
--      where the comment was, so the replies still read as answers. A foreign key would either
--      delete other people's replies with it (CASCADE) or forget which thread they were in
--      (SET NULL). The trigger below checks the id instead, at insert.
--   2. A BEFORE INSERT OR UPDATE OF parent_id trigger on each table that
--        - refuses a parent on another post or photo (a crafted request, never the app),
--        - flattens a reply to a reply onto that reply's own parent, so a thread is one level,
--        - refuses a reply to someone blocked either way, the rule the read policies already
--          apply to seeing their comments at all,
--        - and turns a parent that no longer exists (deleted while the reply was being typed)
--          into a top-level comment rather than refusing it: the text still names who it was for.
--   3. A one-time link of replies written before this, from their leading "@name", to that
--      person's latest earlier comment on the same post or photo. Section 3, separable.
--
-- Read access needs no change: the policies are row filters, and the new column is covered by the
-- tables' existing grants to authenticated. No UPDATE policy exists on either table, so a client
-- cannot move a comment between threads after the fact.
--
-- Verify after applying:
--   SELECT count(*) FROM public.post_comments  WHERE parent_id IS NOT NULL;   -- the linked replies
--   SELECT count(*) FROM public.photo_comments WHERE parent_id IS NOT NULL;
--   SELECT count(*) FROM public.post_comments c JOIN public.post_comments p ON p.id = c.parent_id
--   WHERE p.parent_id IS NOT NULL;                                             -- 0: one level only

-- ---------------------------------------------------------------------------------------------
-- 1. The column
-- ---------------------------------------------------------------------------------------------
ALTER TABLE public.post_comments  ADD COLUMN IF NOT EXISTS parent_id UUID;
ALTER TABLE public.photo_comments ADD COLUMN IF NOT EXISTS parent_id UUID;
CREATE INDEX IF NOT EXISTS post_comments_parent_idx  ON public.post_comments  (parent_id) WHERE parent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS photo_comments_parent_idx ON public.photo_comments (parent_id) WHERE parent_id IS NOT NULL;

-- ---------------------------------------------------------------------------------------------
-- 2. The checks
-- ---------------------------------------------------------------------------------------------
-- SECURITY DEFINER so the parent is found whatever the inserting user's read policy says; the
-- block check below is what stands in for that policy.
CREATE OR REPLACE FUNCTION public.post_comment_thread_parent()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_post   UUID;
    v_author UUID;
    v_parent UUID;
BEGIN
    IF NEW.parent_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT post_id, user_id, parent_id INTO v_post, v_author, v_parent
    FROM public.post_comments WHERE id = NEW.parent_id;
    IF NOT FOUND THEN
        NEW.parent_id := NULL;
        RETURN NEW;
    END IF;
    IF v_post IS DISTINCT FROM NEW.post_id THEN
        RAISE EXCEPTION 'comment_parent_elsewhere' USING ERRCODE = '23514';
    END IF;
    IF public.is_blocked_either_way(NEW.user_id, v_author) THEN
        RAISE EXCEPTION 'comment_parent_blocked' USING ERRCODE = '42501';
    END IF;
    IF v_parent IS NOT NULL THEN
        NEW.parent_id := v_parent;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.post_comment_thread_parent() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS post_comment_thread_parent_trigger ON public.post_comments;
CREATE TRIGGER post_comment_thread_parent_trigger
    BEFORE INSERT OR UPDATE OF parent_id ON public.post_comments
    FOR EACH ROW EXECUTE FUNCTION public.post_comment_thread_parent();

CREATE OR REPLACE FUNCTION public.photo_comment_thread_parent()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_photo  UUID;
    v_author UUID;
    v_parent UUID;
BEGIN
    IF NEW.parent_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT photo_id, user_id, parent_id INTO v_photo, v_author, v_parent
    FROM public.photo_comments WHERE id = NEW.parent_id;
    IF NOT FOUND THEN
        NEW.parent_id := NULL;
        RETURN NEW;
    END IF;
    IF v_photo IS DISTINCT FROM NEW.photo_id THEN
        RAISE EXCEPTION 'comment_parent_elsewhere' USING ERRCODE = '23514';
    END IF;
    IF public.is_blocked_either_way(NEW.user_id, v_author) THEN
        RAISE EXCEPTION 'comment_parent_blocked' USING ERRCODE = '42501';
    END IF;
    IF v_parent IS NOT NULL THEN
        NEW.parent_id := v_parent;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.photo_comment_thread_parent() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS photo_comment_thread_parent_trigger ON public.photo_comments;
CREATE TRIGGER photo_comment_thread_parent_trigger
    BEFORE INSERT OR UPDATE OF parent_id ON public.photo_comments
    FOR EACH ROW EXECUTE FUNCTION public.photo_comment_thread_parent();

-- ---------------------------------------------------------------------------------------------
-- 3. Replies written before threads
-- ---------------------------------------------------------------------------------------------
-- A comment still without a parent whose text opens with "@name", where that person (not the
-- comment's own author) commented earlier on the same post or photo, joins the thread of their
-- latest earlier comment. Oldest first, one row at a time, so a reply to an earlier reply finds
-- that reply already linked and the trigger flattens it onto the same thread. The name is read
-- the way the app reads a mention: letters, digits and underscores after the "@". Rerunnable: a
-- linked comment is never looked at again. A link the trigger refuses (a pair blocked since) is
-- skipped, and the rest carry on.
DO $$
DECLARE
    c RECORD;
    v_target UUID;
BEGIN
    FOR c IN
        SELECT id, post_id, user_id, created_at,
               lower(substring(body FROM '^@([[:alnum:]_]+)')) AS name
        FROM public.post_comments
        WHERE parent_id IS NULL AND body ~ '^@[[:alnum:]_]+'
        ORDER BY created_at, id
    LOOP
        SELECT p.id INTO v_target
        FROM public.post_comments p
        JOIN public.users u ON u.id = p.user_id
        WHERE p.post_id = c.post_id
          AND p.created_at < c.created_at
          AND p.user_id <> c.user_id
          AND lower(u.username) = c.name
        ORDER BY p.created_at DESC
        LIMIT 1;
        IF v_target IS NOT NULL THEN
            BEGIN
                UPDATE public.post_comments SET parent_id = v_target WHERE id = c.id;
            EXCEPTION WHEN OTHERS THEN
                NULL;   -- a pair blocked since: that reply stays where it was
            END;
        END IF;
    END LOOP;

    FOR c IN
        SELECT id, photo_id, user_id, created_at,
               lower(substring(body FROM '^@([[:alnum:]_]+)')) AS name
        FROM public.photo_comments
        WHERE parent_id IS NULL AND body ~ '^@[[:alnum:]_]+'
        ORDER BY created_at, id
    LOOP
        SELECT p.id INTO v_target
        FROM public.photo_comments p
        JOIN public.users u ON u.id = p.user_id
        WHERE p.photo_id = c.photo_id
          AND p.created_at < c.created_at
          AND p.user_id <> c.user_id
          AND lower(u.username) = c.name
        ORDER BY p.created_at DESC
        LIMIT 1;
        IF v_target IS NOT NULL THEN
            BEGIN
                UPDATE public.photo_comments SET parent_id = v_target WHERE id = c.id;
            EXCEPTION WHEN OTHERS THEN
                NULL;   -- a pair blocked since: that reply stays where it was
            END;
        END IF;
    END LOOP;
END;
$$;
