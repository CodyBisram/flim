#!/usr/bin/env node
//
// Deletes Storage objects in the `photos` bucket that belong to no row in the `photos` table.
//
// Why these exist: `feed_path` was added as a third rendition and never added to either delete
// path, so every photo deletion removed the row, the original and the thumbnail and left the
// 1400px card behind. As of 2026-08-05 that was 286 objects and 160 MB, about 15.5% of all
// storage, billed every month forever.
//
// The app-side fix (Photo.allStoragePaths) stops the leak. This clears what already leaked.
// Run it AFTER that fix ships, or it just runs again.
//
//   node scripts/sweep_orphaned_photos.mjs             # dry run, deletes nothing
//   node scripts/sweep_orphaned_photos.mjs --apply     # actually deletes
//
// Needs, from Supabase Dashboard -> Project Settings -> API:
//   export SUPABASE_URL=https://<ref>.supabase.co
//   export SUPABASE_SERVICE_ROLE_KEY=<service_role key, NOT the publishable key>
//
// The service role key bypasses RLS. Do not paste it anywhere it can be committed, and unset it
// when you are done.

const URL_BASE = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const APPLY = process.argv.includes("--apply");
const BUCKET = "photos";

if (!URL_BASE || !KEY) {
  console.error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first.");
  process.exit(1);
}

const headers = { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };

/** Every photo id currently in the table. Deletion is decided against this set. */
async function livePhotoIds() {
  const ids = new Set();
  const page = 1000;
  for (let from = 0; ; from += page) {
    const res = await fetch(`${URL_BASE}/rest/v1/photos?select=id`, {
      headers: { ...headers, Range: `${from}-${from + page - 1}` },
    });
    if (!res.ok) throw new Error(`photos read failed: ${res.status} ${await res.text()}`);
    const rows = await res.json();
    rows.forEach((r) => ids.add(r.id.toLowerCase()));
    if (rows.length < page) break;
  }
  return ids;
}

/** Every user folder in the bucket. Objects are stored as <user-id>/<file>. */
async function listFolders() {
  const res = await fetch(`${URL_BASE}/storage/v1/object/list/${BUCKET}`, {
    method: "POST",
    headers,
    body: JSON.stringify({ prefix: "", limit: 10000, offset: 0 }),
  });
  if (!res.ok) throw new Error(`folder list failed: ${res.status} ${await res.text()}`);
  return (await res.json()).filter((o) => o.id === null).map((o) => o.name);
}

async function listFolder(folder) {
  const out = [];
  const limit = 1000;
  for (let offset = 0; ; offset += limit) {
    const res = await fetch(`${URL_BASE}/storage/v1/object/list/${BUCKET}`, {
      method: "POST",
      headers,
      body: JSON.stringify({ prefix: folder, limit, offset }),
    });
    if (!res.ok) throw new Error(`list ${folder} failed: ${res.status} ${await res.text()}`);
    const batch = await res.json();
    batch.filter((o) => o.id !== null).forEach((o) => {
      out.push({ path: `${folder}/${o.name}`, size: o.metadata?.size ?? 0 });
    });
    if (batch.length < limit) break;
  }
  return out;
}

// A file is kept if a live photo id appears anywhere in its name.
//
// Deliberately matched on the ID rather than on the thumb_path / feed_path COLUMNS. A row can
// have a null rendition column while the file is genuinely in use (an upload that landed after
// the column write failed, or a path the app resolves another way), and deleting on the column
// would destroy a photograph someone can still see. Matching the id can only ever be too
// cautious, which is the correct direction to be wrong in.
const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

function isOrphan(path, liveIds) {
  const file = path.split("/").pop() ?? "";
  if (/avatar|cover/i.test(file)) return false;          // profile art has no photo row, ever
  const ids = file.match(UUID_RE) ?? [];
  if (ids.length === 0) return false;                    // unrecognised shape, leave it alone
  return !ids.some((id) => liveIds.has(id.toLowerCase()));
}

async function remove(paths) {
  const res = await fetch(`${URL_BASE}/storage/v1/object/${BUCKET}`, {
    method: "DELETE",
    headers,
    body: JSON.stringify({ prefixes: paths }),
  });
  if (!res.ok) throw new Error(`delete failed: ${res.status} ${await res.text()}`);
  return (await res.json()).length;
}

const mb = (b) => (b / 1024 / 1024).toFixed(1);

const liveIds = await livePhotoIds();
const folders = await listFolders();

let all = [];
for (const f of folders) all = all.concat(await listFolder(f));

const orphans = all.filter((o) => isOrphan(o.path, liveIds));
const bytes = orphans.reduce((n, o) => n + o.size, 0);
const totalBytes = all.reduce((n, o) => n + o.size, 0);

console.log(`live photo rows      ${liveIds.size}`);
console.log(`objects in bucket    ${all.length}  (${mb(totalBytes)} MB)`);
console.log(`orphaned             ${orphans.length}  (${mb(bytes)} MB)`);
console.log("");

if (orphans.length === 0) {
  console.log("Nothing to sweep.");
  process.exit(0);
}

for (const o of orphans.slice(0, 15)) console.log(`  ${o.path}  ${mb(o.size)} MB`);
if (orphans.length > 15) console.log(`  ... and ${orphans.length - 15} more`);
console.log("");

// A sweep that suddenly wants most of the bucket means the photos read failed or returned a
// partial page, not that everything is orphaned. Refuse rather than empty the bucket.
if (orphans.length > all.length * 0.5) {
  console.error("REFUSING: more than half the bucket looks orphaned. Check the photos query first.");
  process.exit(1);
}

if (!APPLY) {
  console.log("Dry run. Nothing was deleted. Re-run with --apply to delete these.");
  process.exit(0);
}

let removed = 0;
for (let i = 0; i < orphans.length; i += 100) {
  const batch = orphans.slice(i, i + 100).map((o) => o.path);
  removed += await remove(batch);
  console.log(`deleted ${Math.min(i + 100, orphans.length)} / ${orphans.length}`);
}
console.log(`\nDone. Removed ${removed} objects, freed about ${mb(bytes)} MB.`);
