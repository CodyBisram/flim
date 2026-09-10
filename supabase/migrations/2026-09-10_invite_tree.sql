-- FLIM is invite only, so the invite tree IS the social graph, and until now the app could not
-- read it: who invited whom lives in allowed_emails.note ('invited_by:<uuid>'), keyed by email,
-- and email is never readable from the client. This returns only user ids, for the caller only.
--
-- relation:
--   inviter          the one account whose code admitted the caller
--   sibling          other accounts admitted by that same inviter
--   invited          accounts the caller's own code admitted
--   inviter_follows  accounts the inviter follows (the best proxy for "your circle" on day one)
-- The Find friends screen ranks these right after roll mates. Hidden accounts are filtered on the
-- client like every other suggestion (hidden_from_discovery), and blocked ones too.
CREATE OR REPLACE FUNCTION public.invite_tree()
RETURNS TABLE (user_id UUID, relation TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
WITH me AS (
    SELECT id, LOWER(email) AS email FROM public.users WHERE id = auth.uid()
),
my_inviter AS (
    SELECT u.id
    FROM me
    JOIN public.allowed_emails a ON a.email = me.email
    JOIN public.users u ON a.note = 'invited_by:' || u.id::text
    WHERE u.id <> me.id
)
SELECT id, 'inviter' FROM my_inviter
UNION ALL
SELECT u.id, 'sibling'
FROM my_inviter i
JOIN public.allowed_emails a ON a.note = 'invited_by:' || i.id::text
JOIN public.users u ON LOWER(u.email) = a.email
WHERE u.id <> auth.uid()
UNION ALL
SELECT u.id, 'invited'
FROM public.allowed_emails a
JOIN public.users u ON LOWER(u.email) = a.email
WHERE a.note = 'invited_by:' || auth.uid()::text
  AND u.id <> auth.uid()
UNION ALL
SELECT f.following_id, 'inviter_follows'
FROM my_inviter i
JOIN public.follows f ON f.follower_id = i.id
WHERE f.following_id <> auth.uid();
$$;
REVOKE ALL ON FUNCTION public.invite_tree() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invite_tree() TO authenticated;
