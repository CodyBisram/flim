#!/bin/bash
# The weekly tripwire's arithmetic, so the /tripwire skill judges instead of computes.
#
# Five checks, each a number against a threshold the owner already decided:
#   1. egress run-rate against the R2 trigger: scripts/r2_trigger_check.sh, unchanged
#   2. pg_net bloat: net._http_response over 20 MB means the cleanup cron stopped doing its job
#      (the 2026-08 Disk IO incident was 110 MB of response rows from per-minute crons)
#   3. cron cadences: the push crons at */5 and */2, the cleanup job and the Sunday pg_net
#      vacuum present and active; a reverted cadence is how that incident starts again
#   4. push backlog: rows the push crons should have sent, still unsent after an hour
#   5. database size against the last line of docs/TRIPWIRE.md: over 25% growth in a week
#      is the one check that still needs a person, to say whether the cause is known
#
# Prints one line per check, PASS or ALERT with the number that decided it, then the one-line
# entry for docs/TRIPWIRE.md; `--log` appends that entry. Reads public.tripwire_numbers() with
# the service key from ~/.claude/flim-r2-watch.env (chmod 600, never in the repo), like the
# R2 check does. TRIPWIRE_JSON=<json> substitutes a canned response for a dry run.
set -euo pipefail
cd "$(dirname "$0")/.."
LOG="${TRIPWIRE_FILE:-docs/TRIPWIRE.md}"

R2=$(bash scripts/r2_trigger_check.sh)

if [ -n "${TRIPWIRE_JSON:-}" ]; then
  J="$TRIPWIRE_JSON"
else
  [ -z "${FLIM_SERVICE_KEY:-}" ] && source ~/.claude/flim-r2-watch.env
  BASE="https://wxvwamwrjlrvqmuaafjv.supabase.co/rest/v1"
  AUTH=(-H "apikey: $FLIM_SERVICE_KEY" -H "Authorization: Bearer $FLIM_SERVICE_KEY" -H "Content-Type: application/json")
  J=$(curl -sf "${AUTH[@]}" -X POST "$BASE/rpc/tripwire_numbers")
fi

OUT=$(python3 - "$J" "$R2" "$LOG" <<'PY'
import json, re, sys, pathlib, datetime
d = json.loads(sys.argv[1]); r2 = sys.argv[2]; log = pathlib.Path(sys.argv[3])
lines, entry = [], []

# 1. egress, from the R2 script's own verdict
m = re.search(r"([\d.]+) GB/mo modelled egress", r2)
egress = f"{float(m.group(1)):.1f}GB/mo" if m else "?"
ok = r2.startswith("QUIET")
lines.append(f"1 egress run-rate {egress} of 250GB, R2 trigger 100GB/mo: {'PASS' if ok else 'ALERT'}  ({r2})")
entry.append(f"egress run-rate {egress} of 250GB {'PASS' if ok else 'ALERT'}")

# 2. pg_net
mb = d["pg_net_bytes"] / 1048576
ok = mb <= 20
lines.append(f"2 pg_net net._http_response {mb:.1f}MB, limit 20MB: {'PASS' if ok else 'ALERT'}")
entry.append(f"pg_net {mb:.1f}MB {'PASS' if ok else 'ALERT'}")

# 3. crons
expected = {"flim-develop-push": "*/5 * * * *", "flim-social-push": "*/2 * * * *",
            "flim-cron-cleanup": None, "flim-net-response-vacuum": "0 9 * * 0"}
crons = {c["jobname"]: c for c in d["crons"]}
drift = []
for name, sched in expected.items():
    c = crons.get(name)
    if c is None or not c["active"]:
        drift.append(f"{name} missing or inactive")
    elif sched and c["schedule"] != sched:
        drift.append(f"{name} at '{c['schedule']}', expected '{sched}'")
ok = not drift
lines.append(f"3 cron cadences: {'PASS' if ok else 'ALERT ' + '; '.join(drift)}")
entry.append(f"crons {'PASS' if ok else 'ALERT'}")

# 4. push backlog
b = d["push_backlog_over_1h"]
ok = b == 0
lines.append(f"4 push backlog older than an hour: {b}: {'PASS' if ok else 'ALERT'}")
entry.append(f"backlog {b} {'PASS' if ok else 'ALERT'}")

# 5. database size against the last logged line
db = d["db_bytes"] / 1048576
prev = None
if log.exists():
    for l in reversed(log.read_text().splitlines()):
        m = re.search(r"db (\d+)MB", l)
        if m: prev = int(m.group(1)); break
if prev:
    pct = (db - prev) / prev * 100
    ok = pct <= 25
    lines.append(f"5 database {db:.0f}MB, {pct:+.0f}% vs {prev}MB last logged, limit +25%: {'PASS' if ok else 'ALERT, say whether the cause is known'}")
    entry.append(f"db {db:.0f}MB ({pct:+.0f}%)")
else:
    lines.append(f"5 database {db:.0f}MB, no earlier line to compare: PASS (baseline)")
    entry.append(f"db {db:.0f}MB (baseline)")

print("\n".join(lines))
print("LOG: - " + datetime.date.today().isoformat() + ": " + " · ".join(entry))
PY
)
echo "$OUT"
if [ "${1:-}" = "--log" ]; then
  [ -f "$LOG" ] || printf '# Tripwire log\n\nOne line per weekly check (scripts/tripwire_check.sh).\n\n' > "$LOG"
  echo "$OUT" | sed -n 's/^LOG: //p' >> "$LOG"
  echo "appended to $LOG"
fi
