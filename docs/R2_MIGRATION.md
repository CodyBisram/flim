# Moving photo bytes to Cloudflare R2

## Why

Egress is the only FLIM cost that grows with LOOKING rather than shooting, which makes it the
only unbounded one. Measured 2026-08-19: feed cards are ~375kB, one active tester exhausted the
5GB free tier alone, and at 100k users the Supabase bill is roughly $1,675/mo against ~$530 on
R2, whose egress is free. Public launch is explicitly gated on this.

Everything below the owner steps is already built and committed:

| Piece | Where | State |
|---|---|---|
| Delivery Worker (auth via Supabase JWT + RLS-backed RPC) | `cloudflare/worker/` | written |
| `can_view_photo` RPC + `photos.r2_migrated_at` | `supabase/migrations/2026-08-21_r2_can_view_photo.sql` | written, NOT applied |
| Resumable backfill | `scripts/r2_backfill.py` | written, needs credentials |
| Rendition repair (prerequisite: nothing in the library lacks renditions) | `scripts/repair_renditions.py` | RUN 2026-08-21, library clean |

## Owner steps, in order (about 20 minutes)

1. Cloudflare account (free plan is fine to start; Workers paid plan $5/mo once real traffic).
2. Create the R2 bucket, named exactly `flim-photos`.
3. Create an R2 API token (Object Read and Write, scoped to that bucket). Note the Account ID,
   Access Key ID, and Secret Access Key.
4. `npm i -g wrangler && wrangler login`, then from `cloudflare/worker/`:
   `wrangler secret put SUPABASE_JWT_SECRET` (Supabase dashboard → Settings → API → JWT secret),
   set `SUPABASE_ANON_KEY` in wrangler.toml, and `wrangler deploy`. Note the workers.dev URL.
5. Hand the three R2 values and the Worker URL to a session. It applies the migration, runs the
   backfill (resumable, run in chunks with `--limit`), and wires the client seam.

## The client seam (deliberately not wired yet)

Every image byte the app fetches goes through the signed-URL helpers in PhotoService/FeedService.
The cutover is: when a flag is on AND the photo row carries `r2_migrated_at`, build
`https://<worker>/photo/<path>` with the user's session JWT instead of asking Supabase to sign.
Left unwired tonight on purpose: the rolls and feed surfaces are being redesigned in 1.5, and the
seam belongs in whatever those become, not speculatively in what they are tonight.

## Rollback

The flag. Objects live in BOTH stores throughout (the backfill copies, never moves), so turning
the flag off restores Supabase-signed URLs instantly with nothing to migrate back. Supabase
objects are only ever deleted in a separate, owner-approved pass months later, once the bill
proves the migration.
