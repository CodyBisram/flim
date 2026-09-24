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
// DEAD-OWNER PHASE (2026-09-24): account deletion is server-only now (the
// app calls delete_account() and nothing else), so every run FIRST removes
// objects whose top-level folder is the id of no current account, as listed
// by public.list_dead_owner_photos_objects(). Those skip the 48h age check
// and do not count toward HARD_CAP (list_orphaned_photos_objects excludes
// them); a deleted account with hundreds of photos used to stop the whole
// sweep at the cap. Bounded per run by DEAD_OWNER_MAX_PER_RUN, logged as a
// count only. Same dry-run gate as everything else.
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
// Requires: supabase/migrations/2026-09-24_account_purge_complete.sql
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

/// Dead-owner objects removed per run, at most. The account is gone, so the
/// rest simply wait for tomorrow's run; the bound keeps one run's work and
/// its Storage API traffic predictable.
const DEAD_OWNER_MAX_PER_RUN = 5000;

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

interface DeleteResult {
  deletedCount: number;
  deletedBytes: number;
  failedBatches: string[][];
}

/// Real deletion, through the Storage API only. Never storage.objects rows
/// directly. BUCKET is a hardcoded constant, never taken from the request, so
/// this can only ever touch the `photos` bucket. `perObjectLog` writes one
/// line per deleted object (name + size); the dead-owner phase turns it off
/// and logs a count, since a deleted account's file names are its user id.
async function removeCandidates(
  candidates: Candidate[],
  failedAt: string,
  perObjectLog: boolean,
): Promise<DeleteResult> {
  let deletedCount = 0;
  let deletedBytes = 0;
  const failedBatches: string[][] = [];

  for (let i = 0; i < candidates.length; i += DELETE_BATCH_SIZE) {
    const batch = candidates.slice(i, i + DELETE_BATCH_SIZE);
    const names = batch.map((c) => c.object_name);

    const { data: removed, error: removeError } = await supabase.storage.from(BUCKET).remove(names);

    if (removeError) {
      failedBatches.push(names);
      console.log(JSON.stringify({
        at: failedAt,
        ...(perObjectLog ? { names } : { batchSize: names.length }),
        message: removeError.message,
      }));
      continue;
    }

    const removedNames = new Set((removed ?? []).map((r) => r.name));
    for (const c of batch) {
      const wasDeleted = removedNames.has(c.object_name) || (removed?.length ?? 0) === batch.length;
      if (!wasDeleted) continue;
      deletedCount++;
      deletedBytes += c.size_bytes ?? 0;
      if (perObjectLog) {
        console.log(JSON.stringify({ at: "sweep_deleted_object", name: c.object_name, sizeBytes: c.size_bytes }));
      }
    }
  }

  return { deletedCount, deletedBytes, failedBatches };
}

interface DeadOwnerSummary {
  candidates: number;
  candidateBytes: number;
  deletedCount: number;
  deletedBytes: number;
  failedBatchCount: number;
  error?: string;
}

/// Phase 1: objects under the folder of an account that no longer exists.
/// A failure here is logged and reported but does not stop the ordinary
/// sweep below; the two are independent.
async function sweepDeadOwners(dryRun: boolean): Promise<DeadOwnerSummary> {
  const { data, error } = await supabase.rpc("list_dead_owner_photos_objects", {
    p_max_rows: DEAD_OWNER_MAX_PER_RUN,
  });
  if (error) {
    console.log(JSON.stringify({ at: "sweep_dead_owner_query_failed", message: error.message }));
    return { candidates: 0, candidateBytes: 0, deletedCount: 0, deletedBytes: 0, failedBatchCount: 0, error: error.message };
  }
  const rows = (data ?? []) as Candidate[];
  const summary: DeadOwnerSummary = {
    candidates: rows.length,
    candidateBytes: totalBytes(rows),
    deletedCount: 0,
    deletedBytes: 0,
    failedBatchCount: 0,
  };
  if (rows.length > 0 && !dryRun) {
    const r = await removeCandidates(rows, "sweep_dead_owner_batch_failed", false);
    summary.deletedCount = r.deletedCount;
    summary.deletedBytes = r.deletedBytes;
    summary.failedBatchCount = r.failedBatches.length;
  }
  console.log(JSON.stringify({ at: "sweep_dead_owner_run", dryRun, cap: DEAD_OWNER_MAX_PER_RUN, ...summary }));
  return summary;
}

function deadOwnerLine(d: DeadOwnerSummary, dryRun: boolean): string {
  if (d.error) return `dead-owner phase failed: ${d.error}`;
  return dryRun
    ? `dead-owner: ${d.candidates} objects (${d.candidateBytes} bytes) would be deleted`
    : `dead-owner: ${d.deletedCount}/${d.candidates} objects deleted (${d.deletedBytes} bytes), ${d.failedBatchCount} batch(es) failed`;
}

Deno.serve(async (req) => {
  // The scheduler's own secret, checked before anything privileged runs. pg_cron sends it as
  // x-cron-secret; the gateway's bearer is the public key, which every client holds, so it was
  // never an authorization. Fails closed if the secret is unset.
  const cronSecret = Deno.env.get("CRON_SECRET");
  if (!cronSecret) return new Response("cron secret unset", { status: 503 });
  if (req.headers.get("x-cron-secret") !== cronSecret) return new Response("forbidden", { status: 401 });
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

  // Phase 1, before the age-and-cap logic: dead-owner objects never wait and
  // never count toward HARD_CAP.
  const deadOwner = await sweepDeadOwners(dryRun);

  // Phase 2: the ordinary orphan sweep, unchanged in behaviour.
  const { data, error } = await supabase.rpc("list_orphaned_photos_objects", {
    p_min_age_hours: MIN_AGE_HOURS,
    p_max_rows: 5000,
  });

  if (error) {
    console.log(JSON.stringify({ at: "sweep_query_failed", message: error.message }));
    return new Response(`query failed: ${error.message}\n${deadOwnerLine(deadOwner, dryRun)}`, { status: 500 });
  }

  const allCandidates = (data ?? []) as Candidate[];
  const candidateBytes = totalBytes(allCandidates);
  let candidates = allCandidates;

  if (allCandidates.length === 0) {
    console.log(JSON.stringify({ at: "sweep_run", dryRun, candidates: 0 }));
    return new Response(`no orphaned objects found\n${deadOwnerLine(deadOwner, dryRun)}`);
  }

  // Cap check happens before anything else, and blocks the run outright
  // (not just the delete branch) so a runaway candidate set is loud in the
  // logs on a dry run too, not just discovered the day it would matter.
  // Over the cap: the safety stop stays (a bad orphan query must not empty the bucket), but
  // it is no longer silent, and there is a way out. The owner gets one ops alert per day (the
  // social push run delivers it), and a run with `{"batch": true}` in the body processes only
  // the OLDEST HARD_CAP candidates, so a real backlog can be worked down one inspected batch
  // at a time without ever removing the guard. Deletion since 1.5.3 leaves object cleanup to
  // this sweeper on purpose, so a stuck sweeper is a growing bill, not a distant edge case.
  if (candidates.length > HARD_CAP) {
    const batch = body.batch === true;
    console.log(JSON.stringify({
      at: batch ? "sweep_batch_over_cap" : "sweep_aborted_cap_exceeded",
      candidateCount: candidates.length,
      cap: HARD_CAP,
      candidateBytes,
    }));
    if (!batch) {
      const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
      const { data: recent } = await supabase.from("ops_alerts").select("id")
        .eq("source", "sweep-orphaned-storage").gte("created_at", since).limit(1);
      if (!recent?.length) {
        await supabase.from("ops_alerts").insert({
          source: "sweep-orphaned-storage",
          detail: `Stopped: ${candidates.length} orphan candidates (${Math.round(candidateBytes / 1e6)} MB) exceed the cap of ${HARD_CAP}. ` +
            `Inspect list_orphaned_photos_objects(), then run with {"batch": true} to clear the oldest ${HARD_CAP} per run.`,
        });
      }
      return new Response(
        `ABORTED: ${candidates.length} candidate objects exceeds the safety cap of ${HARD_CAP}. ` +
          `Deleted nothing. Owner alerted. Check list_orphaned_photos_objects() for a bad match, then run with {"batch": true}.\n` +
          deadOwnerLine(deadOwner, dryRun),
        { status: 200 },
      );
    }
    candidates = [...candidates].sort((a, b) => a.created_at.localeCompare(b.created_at)).slice(0, HARD_CAP);
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
          deadOwner,
        },
        null,
        2,
      ),
      { headers: { "content-type": "application/json" } },
    );
  }

  // ---- Real deletion, through the Storage API only. Never storage.objects rows directly. ----
  const { deletedCount, deletedBytes, failedBatches } = await removeCandidates(
    candidates,
    "sweep_delete_batch_failed",
    true,
  );

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
      `${failedBatches.length} batch(es) failed\n${deadOwnerLine(deadOwner, dryRun)}`,
  );
});
