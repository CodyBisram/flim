-- ============================================================
-- Roll covers, batched (audit item 9, 2026-09-21).
--
-- One row per developed photo, capped at PostgREST's 1000-row default, was how
-- roll covers got picked client-side: the oldest rolls (past the cap) lost
-- their cover and the client fell back to the master. SECURITY INVOKER (not
-- DEFINER): photos RLS still decides what each caller can see, this just does
-- the per-roll "latest visible photo" pick server-side, in one round trip for
-- however many roll ids the caller asks about.
-- ============================================================

CREATE OR REPLACE FUNCTION public.roll_covers(p_roll_ids uuid[])
RETURNS TABLE (roll_id uuid, storage_path text, thumb_path text)
LANGUAGE sql
SECURITY INVOKER
STABLE
SET search_path = public
AS $$
    SELECT DISTINCT ON (roll_id) roll_id, storage_path, thumb_path
    FROM public.photos
    WHERE roll_id = ANY(p_roll_ids)
      AND hidden = false
      AND develops_at <= now()
    ORDER BY roll_id, taken_at DESC;
$$;

REVOKE ALL ON FUNCTION public.roll_covers(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.roll_covers(uuid[]) TO authenticated;

-- photos_roll_idx is (roll_id, develops_at DESC), which does not serve this
-- query's ORDER BY roll_id, taken_at DESC. Partial on hidden = false since
-- every reader of this function excludes hidden rows.
CREATE INDEX IF NOT EXISTS photos_roll_taken_idx
    ON public.photos (roll_id, taken_at DESC)
    WHERE hidden = false;
