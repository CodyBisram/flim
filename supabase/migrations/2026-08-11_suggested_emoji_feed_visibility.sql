-- ============================================================
-- Fix: public.get_suggested_emoji had no branch for a photo visible because it
-- was shared as a post. The two branches it shipped with, own photo and
-- roll-mate photo, don't cover the feed at all: a feed photo is visible to a
-- viewer because they FOLLOW the poster, not because they share a roll, so
-- every feed suggestion query fell through both branches and returned no rows
-- for anyone except the photo's own owner. This is why reaction-bar
-- suggestions never appeared on the feed.
--
-- Adds a third branch that mirrors "photos: readable when shared to a post"
-- (storage.objects, supabase/schema.sql), the policy that already governs
-- whether this same viewer can read the photo's BYTES once it's posted: EXISTS
-- a public.posts row for this photo, NOT posts.hidden, NOT
-- is_blocked_either_way keyed off the POST's user_id (the sharer, who can be a
-- roll-mate re-sharing someone else's shot onto their own page, so the
-- relevant identity for blocking is posts.user_id, not photos.user_id).
--
-- No develops_at check in the new branch, deliberately. The storage policy it
-- mirrors has none either ("posts: create own" never checks develops_at
-- either, posting is treated as an act of publishing, not gated on the source
-- photo's reveal timer). A suggestion is strictly less sensitive than the
-- pixels it describes, so this branch can never be looser than the image rule
-- it mirrors: anyone who could get a post to exist for an undeveloped photo
-- already exposed that photo's bytes through the same storage policy, so
-- withholding the emoji here would protect nothing.
--
-- Every existing guarantee is preserved unchanged: a roll member still gets
-- nothing before develops_at (that branch and its predicates are untouched), a
-- blocked party still gets nothing, a hidden photo still returns nothing (the
-- outer `NOT p.hidden` still applies to every branch, including the new one),
-- the owner still always gets their own, and a stranger with no post, no roll,
-- and no ownership still gets nothing. All re-verified live, see the agent
-- report for this change.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_suggested_emoji(p_photo_ids UUID[])
RETURNS TABLE (photo_id UUID, suggested_emoji TEXT[])
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT s.photo_id, s.suggested_emoji
    FROM public.photo_suggested_emoji s
    JOIN public.photos p ON p.id = s.photo_id
    WHERE s.photo_id = ANY(p_photo_ids)
      AND NOT p.hidden
      AND (
            p.user_id = auth.uid()
            OR (
                p.roll_id IS NOT NULL
                AND public.is_roll_member(p.roll_id)
                AND NOT public.is_blocked_either_way(auth.uid(), p.user_id)
                AND p.develops_at <= now()
              )
            OR EXISTS (
                SELECT 1 FROM public.posts po
                WHERE po.photo_id = p.id
                  AND NOT po.hidden
                  AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
              )
          );
$$;

-- Grants unchanged, restated for a from-scratch or drift-checked run.
REVOKE ALL ON FUNCTION public.get_suggested_emoji(UUID[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_suggested_emoji(UUID[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_suggested_emoji(UUID[]) TO authenticated;
