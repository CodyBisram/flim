-- Where people are: the phone's time zone on the version census (2026-09-29). NOT YET APPLIED.
-- The owner applies it.
--
-- Nothing in the database says where anyone is. Apple's territory reports say which storefront an
-- Apple ID belongs to (everyone reads "US", including people shooting from Bali), and the site's
-- analytics know a visitor's country but not their account. The app already computes the phone's
-- IANA time zone (TimeZone.current.identifier, sent to every Chapters RPC as p_timezone), so the
-- once-per-launch version stamp now carries it too: one nullable column on client_versions,
-- overwritten on every launch alongside version and build. Coarse on purpose. It needs no
-- permission, it does not move with a VPN, and it is the same value the app already uses to
-- decide when a month starts. Nothing finer (location permission, IP lookups) is wanted.
--
-- The function gains a third parameter with a default. The old two-parameter signature is
-- dropped first so a call with two named arguments (every build before this one) resolves to the
-- new function with p_timezone NULL, instead of Postgres refusing an ambiguous overload. Junk is
-- stored as NULL, never an error: the client call is try?-swallowed and must stay free.

ALTER TABLE public.client_versions ADD COLUMN IF NOT EXISTS timezone text;

DROP FUNCTION IF EXISTS public.report_client_version(text, text);

CREATE OR REPLACE FUNCTION public.report_client_version(p_version text, p_build text DEFAULT NULL,
                                                        p_timezone text DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    tz text;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN;
    END IF;
    IF p_version IS NULL OR length(p_version) = 0 OR length(p_version) > 32
       OR length(COALESCE(p_build, '')) > 32 THEN
        RETURN;
    END IF;
    -- An IANA name: letters, digits, slash, underscore, plus, minus, dot (Etc/GMT+8, America/Argentina/Buenos_Aires).
    tz := CASE WHEN p_timezone ~ '^[A-Za-z0-9_+./-]{1,64}$' THEN p_timezone END;

    INSERT INTO public.client_versions (user_id, version, build, timezone, updated_at)
    VALUES (auth.uid(), p_version, p_build, tz, now())
    ON CONFLICT (user_id)
    DO UPDATE SET version = EXCLUDED.version,
                  build   = EXCLUDED.build,
                  timezone = EXCLUDED.timezone,
                  updated_at = now();
END;
$function$;
REVOKE ALL ON FUNCTION public.report_client_version(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.report_client_version(text, text, text) TO authenticated;

-- Where are people, once builds with the stamp are out (owner, read-only):
--   select coalesce(timezone, 'unknown') as zone, count(*) as people,
--          count(*) filter (where updated_at > now() - interval '7 days') as seen_this_week
--     from public.client_versions group by 1 order by 2 desc;
