// ============================================================
// FLIM sweep-orphaned-storage  (Supabase Edge Function, Deno)
//
// Permanent backstop for Storage objects in the `photos` bucket that got
// their bytes uploaded but never got a row written that points at them.
// Three client bugs were found that can cause this; one of them (the app
// killed by the OS between the Storage PUT finishing and the row insert
// running) has no client-side fix -- there is no hook that reliably fires
// on a kill -- so this has to exist forever, not just until the client is
// patched.
//
// An object counts as orphaned only if its name is in NONE of:
//   photos.storage_path / thumb_path / feed_path
//   posts.storage_path  / thumb_path  / feed_path
//   users.avatar_path   / cover_path
//   rolls.cover_path
// AND it is older than MIN_AGE_HOURS. That whole check lives in
// public.list_orphaned_photos_objects() (see
// supabase/migrations/2026-08-08_orphaned_storage_sweep.sql), not here, so
// there is exactly one place that defines "orphan" and this function can't
// drift from it. Avatars, covers and roll covers live in the SAME `photos`
// bucket as captures -- an earlier draft of this sweep that only checked
// photos+posts would have deleted six users' profile pictures.
//
// DRY RUN IS THE DEFAULT. Deletion only happens when the caller passes
// dryRun=false AND the correct SWEEP_CONFIRM_TOKEN secret. Getting dryRun
// wrong (a stray query param, a copy-pasted curl) degrades to "reports what
// it would do," never to "deletes more than intended."
//
// HARD CAP: if the candidate set is larger than HARD_CAP, nothing is
// deleted, regardless of dryRun or the confirm token. A bug in the orphan
// query (or a schema change that silently drops a referenced column from
// the UNION in list_orphaned_photos_objects) must not be able to empty the
// bucket -- it can, at most, make one run refuse to do anything.
//
// Deploy:
//   supabase functions deploy sweep-orphaned-storage
//   (verify-jwt left ON, unlike the push functions -- this one deletes data,
//   so a request needs a valid Supabase JWT just to be *heard*, on top of
//   the confirm-token gate below for the delete branch specifically.)
// Requires: supabase/migrations/2026-08-08_orphaned_storage_sweep.sql
// Requires the SWEEP_CONFIRM_TOKEN secret for real (non-dry-run) runs:
//   supabase secrets set SWEEP_CONFIRM_TOKEN=<random string>
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.
//
// SCHEDULED (pg_cron job `flim-storage-sweep`): once daily. To (re)register:
//   SELECT cron.unschedule('flim-storage-sweep');
//   SELECT cron.schedule('flim-storage-sweep', '17 9 * * *', $job$
//     SELECT net.http_post(
//       url := 'https://<ref>.supabase.co/functions/v1/sweep-orphaned-storage',
//       headers := jsonb_build_object(
//         'Content-Type', 'application/json',
//         'Authorization', 'Bearer <anon key>'
//       ),
//       body := jsonb_build_object('dryRun', false, 'confirm', '<SWEEP_CONFIRM_TOKEN>')
//     );
//   $job$);
// ============================================================

// Pinned deliberately, see send-daily-digest: an unpinned `@2` re-resolves
// on every deploy and an upstream publishing problem then breaks deploys of
// code that hasn't changed.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.111.0";

const BUCKET = "photos";

/// Uploads land bytes before the row referencing them is written, so
/// anything newer than this is very likely a capture in flight, not garbage.
const MIN_AGE_HOURS = 48;

/// If the candidate set is bigger than this, delete nothing. A bug in the
/// orphan query must not be able to empty the bucket in one run.
const HARD_CAP = 500;

/// Storage API accepts a `prefixes` array per request; kept small and
/// bounded rather than relying on an undocumented server-side limit.
const DELETE_BATCH_SIZE = 64;

const SWEEP_CONFIRM_TOKEN = Deno.env.get("SWEEP_CONFIRM_TOKEN");

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

interface Candidate {
  object_name: string;
  size_bytes: number | null;
  created_at: string;
}

function totalBytes(rows: Candidate[]): number {
  return rows.reduce((sum, r) => sum + (r.size_bytes ?? 0), 0);
}

Deno.serve(async (req) => {
  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    // No body (or not JSON) is the common case: cron's net.http_post default
    // and a bare curl both land here, and both should mean "dry run."
  }

  const url = new URL(req.url);
  const rawDryRun = url.searchParams.get("dryRun") ?? body.dryRun;
  const requestedReal = rawDryRun === false || rawDryRun === "false";
  const confirm = (url.searchParams.get("confirm") ?? body.confirm) as string | undefined;

  // Default-safe: dry run unless BOTH dryRun=false was requested AND the
  // confirm token matches. A missing/unset secret also forces dry run,
  // rather than either failing closed with an error or, worse, open.
  let dryRun = true;
  let forcedReason: string | null = null;
  if (requestedReal) {
    if (!SWEEP_CONFIRM_TOKEN) {
      forcedReason = "SWEEP_CONFIRM_TOKEN secret not set";
    } else if (confirm !== SWEEP_CONFIRM_TOKEN) {
      forcedReason = "confirm token missing or incorrect";
    } else {
      dryRun = false;
    }
  }
  if (forcedReason) {
    console.log(JSON.stringify({ at: "sweep_forced_dry_run", reason: forcedReason }));
  }

  const { data, error } = await supabase.rpc("list_orphaned_photos_objects", {
    p_min_age_hours: MIN_AGE_HOURS,
    p_max_rows: 5000,
  });

  if (error) {
    console.log(JSON.stringify({ at: "sweep_query_failed", message: error.message }));
    return new Response(`query failed: ${error.message}`, { status: 500 });
  }

  const candidates = (data ?? []) as Candidate[];
  const candidateBytes = totalBytes(candidates);

  if (candidates.length === 0) {
    console.log(JSON.stringify({ at: "sweep_run", dryRun, candidates: 0 }));
    return new Response("no orphaned objects found");
  }

  // Cap check happens before anything else, and blocks the run outright
  // (not just the delete branch) so a runaway candidate set is loud in the
  // logs on a dry run too, not just discovered the day it would matter.
  if (candidates.length > HARD_CAP) {
    console.log(JSON.stringify({
      at: "sweep_aborted_cap_exceeded",
      candidateCount: candidates.length,
      cap: HARD_CAP,
      candidateBytes,
    }));
    return new Response(
      `ABORTED: ${candidates.length} candidate objects exceeds the safety cap of ${HARD_CAP}. ` +
        `Deleted nothing. Check list_orphaned_photos_objects() for a bad match before re-running.`,
      { status: 200 },
    );
  }

  if (dryRun) {
    console.log(JSON.stringify({
      at: "sweep_dry_run",
      candidateCount: candidates.length,
      candidateBytes,
      objects: candidates.map((c) => ({ name: c.object_name, size: c.size_bytes, createdAt: c.created_at })),
    }));
    return new Response(
      JSON.stringify(
        {
          dryRun: true,
          candidateCount: candidates.length,
          candidateBytes,
          objects: candidates,
        },
        null,
        2,
      ),
      { headers: { "content-type": "application/json" } },
    );
  }

  // ---- Real deletion, through the Storage API only. Never storage.objects rows directly. ----
  let deletedCount = 0;
  let deletedBytes = 0;
  const failedBatches: string[][] = [];

  for (let i = 0; i < candidates.length; i += DELETE_BATCH_SIZE) {
    const batch = candidates.slice(i, i + DELETE_BATCH_SIZE);
    const names = batch.map((c) => c.object_name);

    // BUCKET is a hardcoded constant, never taken from the request, so this
    // function can only ever touch the `photos` bucket.
    const { data: removed, error: removeError } = await supabase.storage.from(BUCKET).remove(names);

    if (removeError) {
      failedBatches.push(names);
      console.log(JSON.stringify({ at: "sweep_delete_batch_failed", names, message: removeError.message }));
      continue;
    }

    const removedNames = new Set((removed ?? []).map((r) => r.name));
    for (const c of batch) {
      const wasDeleted = removedNames.has(c.object_name) || (removed?.length ?? 0) === batch.length;
      if (!wasDeleted) continue;
      deletedCount++;
      deletedBytes += c.size_bytes ?? 0;
      // One line per deleted object: name + size, the audit trail the run
      // total below is built from.
      console.log(JSON.stringify({ at: "sweep_deleted_object", name: c.object_name, sizeBytes: c.size_bytes }));
    }
  }

  const summary = {
    at: "sweep_run_complete",
    dryRun: false,
    candidateCount: candidates.length,
    candidateBytes,
    deletedCount,
    deletedBytes,
    failedBatchCount: failedBatches.length,
  };
  console.log(JSON.stringify(summary));

  return new Response(
    `sweep: ${deletedCount}/${candidates.length} objects deleted (${deletedBytes} bytes), ` +
      `${failedBatches.length} batch(es) failed`,
  );
});
