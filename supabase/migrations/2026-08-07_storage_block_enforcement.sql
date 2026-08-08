-- ============================================================
-- Migration: extend block enforcement to storage.objects (App Store Guideline 1.2)
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: safe to re-run (DROP POLICY IF EXISTS + CREATE POLICY).
--
-- THE GAP: "photos: roll members can see" (public.photos) and "posts: readable
-- by authenticated" (public.posts) already carry a
-- NOT public.is_blocked_either_way(auth.uid(), user_id) predicate, so the ROW
-- layer hides a blocked party's content correctly. The matching storage.objects
-- policies ("photos: roll members can read shared" and "photos: readable when
-- shared to a post") never got that predicate. Blocking never touches
-- roll_members, so a blocked user stays is_roll_member(roll_id) = true, and the
-- app caches raw storage paths on disk for up to 7 days (SignedURLStore.ttl). A
-- blocked user holding a cached path could mint a fresh signed URL and pull a
-- roll-mate's photo bytes straight from Storage, even though the row layer had
-- already made the photo/post invisible everywhere else. This closes that gap
-- by mirroring the exact predicate the row policies use, at the byte layer.
--
-- schema.sql was ALSO updated (both files carry this fix now, so a fresh
-- top-to-bottom run of schema.sql does not reintroduce the gap). schema.sql
-- defines these two policy names THREE times: the storage bootstrap section
-- (around line 422 / 676, no block check, can't reference
-- is_blocked_either_way there, it doesn't exist yet at that point in the
-- file), the "Auto-moderation" section (around line 947 / 961, adds NOT
-- hidden only, same ordering problem), and now a third redefinition inside
-- the block-enforcement section (around line 1148 / 1166, right after
-- "photos: roll members can see" is redefined there), which is the one that
-- actually survives a full run and is the one that now carries the block
-- predicate. The two policies below are byte-for-byte identical to that
-- surviving schema.sql definition.
--
-- Strictly tightening: every existing condition (bucket, all three rendition
-- path columns, roll_id IS NOT NULL, NOT hidden, is_roll_member) is preserved
-- verbatim; only a new AND-ed block check is added. No legitimate (non-blocked)
-- viewer loses access.
-- ============================================================

-- Shared-roll photo bytes: a blocked party's roll photos are already hidden at
-- the row layer (public.photos), now also unreadable at the storage layer, so a
-- stale cached path can no longer mint a working signed URL post-block.
DROP POLICY IF EXISTS "photos: roll members can read shared" ON storage.objects;
CREATE POLICY "photos: roll members can read shared"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (
            SELECT 1 FROM public.photos p
            WHERE storage.objects.name IN (p.storage_path, p.thumb_path, p.feed_path)
              AND p.roll_id IS NOT NULL
              AND NOT p.hidden
              AND public.is_roll_member(p.roll_id)
              AND NOT public.is_blocked_either_way(auth.uid(), p.user_id)
        )
    );

-- Posted photo bytes: mirrors "posts: readable by authenticated" (public.posts),
-- which already keys off po.user_id for both NOT hidden and the block check.
DROP POLICY IF EXISTS "photos: readable when shared to a post" ON storage.objects;
CREATE POLICY "photos: readable when shared to a post"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (SELECT 1 FROM public.posts po
                    WHERE storage.objects.name IN (po.storage_path, po.thumb_path, po.feed_path)
                      AND NOT po.hidden
                      AND NOT public.is_blocked_either_way(auth.uid(), po.user_id))
    );
