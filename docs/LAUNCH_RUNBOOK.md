# FLIM 1.0 — App Store launch runbook

Do these in order. Copy for the listing itself lives in `APP_STORE.md`; this is the click-by-click.

---

## 1. Reviewer demo account (~10 min)

1. Supabase Dashboard → Authentication → Users → **Add user**
   - Email: `review@flim-app.com` (or any inbox you control)
   - Password: something strong you'll paste into Review Notes
   - ✅ Auto-confirm
2. SQL editor:
   ```sql
   INSERT INTO public.allowed_emails (email, note)
   VALUES ('review@flim-app.com', 'App Review demo')
   ON CONFLICT (email) DO NOTHING;
   ```
3. Sign into the app as the reviewer once: pick a username, shoot 1–2 photos,
   follow your main account — so the reviewer lands in a live-feeling app.

## 2. Supabase production settings (~5 min)
- Auth → Rate Limits: confirm email/OTP limits are on (defaults are fine).
- Edge Functions → `send-social-push` → confirm **Verify JWT** is enabled.
- (At submission) **Upgrade to Pro ($25/mo)** — kills the 5GB egress wall and
  free-tier project pausing, which could otherwise bite during review.

## 3. Screenshots (~20 min, real device)
Shoot on your iPhone with your real account (6.9" class required):
1. Camera viewfinder
2. Darkroom grid with developed shots
3. A feed post with reactions + comments
4. A roll (cover + members)
5. A great photo full-screen
Clean the status bar look: shoot at a nice battery level, or crop per Apple's template.

## 4. App Store Connect record (~45 min)
Create app → bundle id `com.flim.app`, SKU `flim-001`.
Paste everything from `APP_STORE.md`: name, subtitle, description, keywords,
promo text, URLs, App Privacy answers, category (Photo & Video / Social),
price Free, availability.

**Age rating questionnaire:** answer YES to "Unrestricted Web Access" = NO;
user-generated content = YES; moderation in place = YES (report, block,
auto-removal). Everything else (violence, gambling, etc.) = NO. Expect 12+/17+.

**App Review Information:**
- Sign-in required: YES → email: `review@flim-app.com`, password: `<the one you set>`
- Notes: paste the reviewer blurb from `APP_STORE.md` (mentions the
  "Have a password? Sign in" path and that photos develop in ~60s).
- Contact: your name + phone + email.

**Version info:** What's New for 1.0:
> Welcome to FLIM — a disposable camera for your closest friends.
> Shoot, let it develop, and share the moment.

## 5. Final smoke test (~30 min, the one that matters)
On the latest TestFlight build, with a FRESH account:
- [ ] Sign up via email code → onboarding → camera
- [ ] First shot → sort deck → publish to feed
- [ ] Create a roll → Copy code → Share → tap the link in Messages → join page opens
- [ ] Join the roll from your second account with the code
- [ ] Comment, react, tag someone in a shared photo
- [ ] **A push notification actually arrives on the other phone**
- [ ] Report a photo → block → Settings → Blocked users → unblock
- [ ] Share a photo out → frame toggle works
- [ ] Settings → Delete Account works
- [ ] Accent change re-tints instantly; comments sheet opens at 75%

## 6. Submit
- ASC → your version → Build → select the latest TestFlight build
- Submit for Review (typical first review: 1–3 days)
- If rejected: read the reason calmly, it's almost always metadata or reviewer
  access — fixable within a day.

## Day-1 post-launch
- Watch ASC crash reports + Supabase logs
- Check `photo_reports` daily at first: `SELECT * FROM photos WHERE hidden;`
- Egress: Supabase dashboard → usage (Pro gives headroom)
- When ready for tappable-into-app invite links: `UNIVERSAL_LINKS.md`

### Lessons from production
- **SECURITY DEFINER functions in RLS:** if a policy calls a SECURITY DEFINER function, that
  function still needs EXECUTE granted to the role invoking it (e.g., `authenticated`).
  Revoking the grant will silently fail RLS checks and take features down.
- **Storage read policies + new rendition paths:** when a new storage column is added
  (e.g., `feed_path`), ensure all read policies' `IN (path1, path2, ...)` lists include it.
  Missing it leaves the new path unloadable for other users.
- **Column-scoped grants break upserts:** when SELECT is revoked at the table level but
  granted on specific columns only (e.g., on `users` to hide email + invite_code from
  other users), `.upsert()` will 403 because the CONFLICT machinery requires table-level
  SELECT. Workaround: use insert-then-catch-and-update, both with `return=minimal` and no
  `.select()` chain.

## Parked (post-launch backlog)
- Widget + Live Activity (develop countdown)
- LUT refits from new calibration pairs (`LUTS.md`) — the v1 fitted look (flim.cube + adaptive exposure) shipped
- Universal links entitlement (needs match profile regen)
- Personal-photo develop reveal (reuse RollRevealView effect)
- Rename decision window: first couple of months
