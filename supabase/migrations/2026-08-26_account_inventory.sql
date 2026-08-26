-- ============================================================
-- Migration: account_inventory() — the real numbers behind the account-deletion
-- page (confirmations redesign, phase 3). Paste into Supabase Dashboard -> SQL
-- Editor and run, or deploy via the Management API. Safe to re-run.
--
-- THE GAP THIS CLOSES
-- --------------------
-- Deleting an account is the one action in FLIM with no undo, no grace period and
-- no copy on our side, and the old confirmation asked a yes/no question about
-- hundreds of photos in small grey type. The replacement page shows an inventory
-- (photos, rolls you made, posts) before the held confirm, and those numbers must
-- be SERVER-side counts: the client's photo list is paginated (the documented
-- 30-photo trap has produced wrong totals before), so any client-derived count
-- would understate exactly when it matters most.
--
-- Zero arguments, hard-pinned to auth.uid() like own_effective_displayed_badges:
-- there is no way to ask about anyone else's account. SECURITY DEFINER matches the
-- other own-data RPCs; the pinned search_path and the anon REVOKE are the same
-- hygiene every function in this schema carries.
-- ============================================================

CREATE OR REPLACE FUNCTION public.account_inventory()
RETURNS TABLE (photos BIGINT, rolls_created BIGINT, posts BIGINT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        (SELECT count(*) FROM public.photos WHERE user_id = auth.uid()),
        (SELECT count(*) FROM public.rolls  WHERE created_by = auth.uid()),
        (SELECT count(*) FROM public.posts  WHERE user_id = auth.uid());
$$;

REVOKE ALL ON FUNCTION public.account_inventory() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.account_inventory() FROM anon;
GRANT EXECUTE ON FUNCTION public.account_inventory() TO authenticated;
