-- ============================================================
-- Let a tagged user remove THEIR OWN tag from someone else's photo.
--
-- post_tags previously allowed DELETE only to the post's owner, so being tagged in a photo was
-- one-way: the only person who could untag you was the person who tagged you. This adds a second
-- permissive DELETE policy; Postgres ORs permissive policies, so the owner keeps their existing
-- ability to manage every tag on their own post and this only widens who may remove one row.
--
-- Deliberately scoped to `tagged_user_id = auth.uid()`: it grants no ability to remove anyone
-- else's tag, on your own posts or on anybody else's. INSERT is untouched, so this cannot be used
-- to add a tag, only to withdraw from one.
-- ============================================================
DROP POLICY IF EXISTS "post_tags: tagged user removes self" ON public.post_tags;
CREATE POLICY "post_tags: tagged user removes self"
    ON public.post_tags FOR DELETE TO authenticated
    USING (tagged_user_id = auth.uid());
