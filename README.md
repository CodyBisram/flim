# FLIM

A native iOS instant/disposable-camera app. Shoot now, see it later — photos hide and
"develop" over time, then reveal with an instant-film look baked in at capture. Invite-only.

## Stack

- **SwiftUI** (iOS 26 target), `@Observable` throughout — no `ObservableObject`
- **AVFoundation** for capture, **Core Image** for the instant-film processing
- **Supabase** — Postgres + Row Level Security, email OTP auth, private Storage bucket
- iOS 26 **Liquid Glass** styling app-wide
- **xcodegen**-managed project (`project.yml` is the source of truth)

## Features

- Email OTP sign-in, gated by an invite allowlist; users can self-invite with a friend's code
- Full-screen camera with a film-strip picker and instant-film look baked in at capture
- **Darkroom** — developing placeholders, countdown, and reveal moment
- **Rolls** — shared friend groups via 6-char invite codes (max 50 members)
- Signature **FLIM Original look**: fitted 3D LUT + scene-adaptive exposure, shipped as flim.cube
- **Social layer** — photo feed with posts/captions, follows, reactions/comments, user pages,
  activity view, discovery/search, reporting + blocking (RLS-enforced, bidirectional)
- Remote push notifications (APNs via Edge Functions; local fallback on-device)

## Project layout

```
Flim/
  Config/        Supabase client
  Models/        AppUser, Roll, Photo, FilmStock, Social
  Services/      Auth, Photo, Roll, Feed, Notification, RemotePush, InstantFilmProcessor
  Views/         Auth, Camera, Darkroom, Rolls, Profile, Feed, Main, Components
supabase/
  schema.sql     Tables, RLS policies, and RPCs
  migrations/    Idempotent SQL migrations (applied to production, mirrored in schema.sql)
  functions/     Edge Functions (send-develop-push, send-social-push)
  push/          Remote push backend (legacy, superseded by Edge Functions)
web/             Invite landing page + legal site (Vercel)
scripts/         LUT fitting (fit_lut.py)
project.yml      xcodegen project definition
```

## Getting started

### Requirements

- macOS with full **Xcode 26.x** (Command Line Tools alone is not enough)
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

### Build

```bash
# Generate the Xcode project from project.yml
xcodegen generate

# Build for the simulator
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Flim.xcodeproj -scheme Flim \
  -destination 'generic/platform=iOS Simulator' build
```

Then open `Flim.xcodeproj` in Xcode and run on an iOS 26 simulator or device.

### Supabase setup

1. **Paste migrations**, then run `supabase/schema.sql` in the SQL editor:
   - `supabase/migrations/` holds paste-ready, idempotent migrations (already applied to
     production). Paste each into the editor and run once; they are then mirrored in
     `schema.sql` for historical reference. (New migrations get their own dated file.)
   - `schema.sql` is the source of truth for the full schema state (idempotent — safe to
     re-run). It creates the tables, RLS policies, and RPCs.
2. Create a **private** Storage bucket named `photos` and add the per-user policies
   documented in `schema.sql`.
3. Add the project URL and publishable key to `Flim/Config/SupabaseClient.swift`.

### Photo upload pipeline

Each capture uploads three renditions to private Storage:
- **full**: original processed image (sRGB-tagged JPEG with ICC profile)
- **thumb**: small grid thumbnail
- **feed**: ~1400px rendition for feed cards (pixel-identical at display width, ~1/3 the egress)

All files are sRGB-tagged ICC JPEGs; access is via signed URLs (RLS-enforced per user).

### Invite allowlist

FLIM is invite-only — only allow-listed emails can request a sign-in code:

```sql
INSERT INTO public.allowed_emails (email, note) VALUES ('them@example.com', 'Name');
```

### Remote push (optional setup)

Local develop notifications work with no backend. To enable APNs push when roll-mates' photos
develop, deploy the auth key — see `supabase/functions/send-develop-push/` and
`send-social-push/` for the Edge Function code.
