# FLIM — App Store Connect listing

Copy-paste-ready metadata + a screenshot plan + reviewer notes. Tweak the voice to taste.

---

## Name & subtitle
- **App name:** `FLIM`
- **Subtitle** (30 char max): `Disposable camera for friends`

## Promotional text (170 char max — editable anytime without review)
> Shoot on film, wait for it to develop, and share the moment with the people who actually matter. No likes to chase. No feed to doomscroll. Just your people.

## Description
> **FLIM is a disposable camera for your closest friends.**
>
> Point, shoot, and let it develop — just like the real thing. Your photos don't appear instantly. They take their time, so every roll feels like a little surprise waiting to happen.
>
> **Shoot on film.** Every photo gets FLIM's warm, grainy film look baked right in. No filters to fiddle with — it just looks good.
>
> **Rolls, together.** Start a roll with friends and everyone's shots land in one place when they develop. Trips, parties, nights out — one shared roll, revealed together.
>
> **A feed that's just your people.** Follow friends, react, and comment. It's invite-only and private by design — what you share stays between you and the people you choose.
>
> **No pressure, no doomscroll.** No public likes. No algorithm. No strangers. Just a calmer, warmer way to share moments with the friends who matter.
>
> Grab an invite from a friend and start shooting.

## Keywords (100 char max, comma-separated, no spaces)
`disposable,film,camera,photo,friends,retro,vintage,analog,rolls,develop,aesthetic,private,social,grain`

## Category
- **Primary:** Photo & Video
- **Secondary:** Social Networking

## Age rating
Answer Apple's questionnaire honestly. Because FLIM has **user-generated photos + comments**, expect **17+** unless you emphasize the moderation controls (report, block, remove within 24h) — with those, **12+** is defensible. Do **not** understate UGC; that gets flagged. Recommended: answer "Yes" to user-generated content, "Yes" to the moderation controls you have.

## Support & marketing URLs
- **Support URL:** `https://flim-app.com/support`
- **Marketing URL:** `https://flim-app.com`
- **Privacy Policy URL:** `https://flim-app.com/privacy`

---

## App Privacy ("nutrition label") answers
Data collected & **linked to the user**:
- **Contact Info → Email address** — app functionality (sign-in). Not used for tracking.
- **User Content → Photos** — app functionality.
- **User Content → Other (comments, reactions)** — app functionality.
- **Identifiers → Device ID (APNs token)** — app functionality (notifications only).

Not collected: location, contacts, browsing history, purchases, advertising data. **No tracking.**

---

## Screenshots (shot-list)
6.9" (iPhone 16 Pro Max) + 6.5" required. Shoot these on-device (clean status bar via `xcrun simctl status_bar` or a real device):
1. **The camera** — clean viewfinder + shutter. Caption: *"Shoot like a disposable."*
2. **The Darkroom grid** — a few developed shots. Caption: *"Watch them develop."*
3. **A feed post** — photo + reactions + a comment. Caption: *"A feed that's just your friends."*
4. **A shared roll** — roll cover + members. Caption: *"Start a roll together."*
5. **The reveal / a great developed photo full-screen.** Caption: *"Every moment, on film."*

Tip: seed a nice-looking account first so the screenshots aren't empty.

---

## Reviewer notes (App Store Connect → App Review Information)
FLIM is **invite-only**, so give the reviewer a way in:

> FLIM is invite-only. We've added a reviewer account to our allowlist. To sign in:
> 1. Open the app, enter the email: **[reviewer@flim-app.com or a demo email you control]**
> 2. Tap "Have a password? Sign in" and use password: **[demo password]**
>    (This bypasses the email code so you don't need inbox access.)
>
> Once in, you can shoot a photo (it develops in ~60s), view the Darkroom, browse the feed, and create/join a roll. Report and Block are in the ••• menu on any photo.

**Setup before submitting:**
1. Create the demo account in Supabase (Auth → Add User, email + password, auto-confirm).
2. Add that email to the allowlist: `INSERT INTO public.allowed_emails (email) VALUES ('lower@case.com');`

✅ **Good news on the gating:** builds under App Review run in Apple's **sandbox** (sandbox receipt), and `AppInfo.isAppStore` only returns `true` for a genuinely-live download (production receipt). So the **password sign-in will show for the reviewer** and hide for the public — exactly what we want. No changes needed.

Belt-and-suspenders (optional): use a demo email whose inbox you can access, so if anything's off the reviewer could also use the emailed code.
