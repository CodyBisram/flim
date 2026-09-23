-- ============================================================
-- users.display_name gets a ceiling.
--
-- Signup accepted a display name of any length and the profile's Name sheet
-- cut it to 40 on save without saying so (found 2026-09-22 from a tester's
-- report); the column itself is plain text with no rule, so whichever client
-- wrote last decided. The app now keeps 40 characters in both fields as they
-- are typed (AuthService.displayNameMaxLength); this is the column's own copy
-- of that rule, so no client can write past it.
--
-- 100, not 40: Postgres counts code points and the phone counts characters as
-- a person sees them. A flag is one character on screen and two code points
-- here; a family emoji is one and seven. 100 lets any 40-character name
-- through and still stops a runaway write. NULL stays allowed: the name is
-- optional. Every existing value is 11 characters or under (checked in
-- production 2026-09-22), so the constraint validates on add.
-- ============================================================

ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS users_display_name_length_check,
    ADD CONSTRAINT users_display_name_length_check
        CHECK (display_name IS NULL OR char_length(display_name) <= 100);
