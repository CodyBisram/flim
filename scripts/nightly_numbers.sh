#!/bin/bash
# The nightly numbers, run by .github/workflows/nightly-numbers.yml just after midnight Eastern.
#
# Reads public.nightly_numbers() with the service key, appends one line for yesterday to
# docs/NUMBERS.md (idempotent: a day already there is rewritten, not duplicated), and prints a
# verdict line. Regressions, meaning something broken rather than something quiet, are raised as
# an ops_alerts row, which the social push turns into a push to the owner within minutes:
#   - a capture from the last day is still missing renditions an hour later
#   - a roll developed over an hour ago and nobody has been told
#   - a push gave up after three tries
#   - a cron run failed, or an edge function answered non-200
#   - a crash or hang row landed
#   - a report the owner was never pushed about
# Openers dropping is not an alert; that is what the trend line is for.
set -euo pipefail
[ -z "${FLIM_SERVICE_KEY:-}" ] && source ~/.claude/flim-r2-watch.env
BASE="https://wxvwamwrjlrvqmuaafjv.supabase.co/rest/v1"
AUTH=(-H "apikey: $FLIM_SERVICE_KEY" -H "Authorization: Bearer $FLIM_SERVICE_KEY" -H "Content-Type: application/json")

J=$(curl -sf "${AUTH[@]}" -X POST "$BASE/rpc/nightly_numbers")
ALERT=$(python3 - "$J" "${NUMBERS_FILE:-docs/NUMBERS.md}" <<'PY'
import json, sys, pathlib
d = json.loads(sys.argv[1]); path = pathlib.Path(sys.argv[2])
cols = ["day","accounts","new_accounts","openers","openers_7d_avg","shooters","photos","posts",
        "reactions","comments","follows","reciprocal_pairs_7d","rolls_created","reveals_watched",
        "invites_redeemed","founding_left","db_mb","storage_gb"]
header = ("# FLIM by the day\n\nOne line per day, appended by the nightly numbers job "
          "(scripts/nightly_numbers.sh). Counts are for the Eastern-time day named; "
          "`openers_7d_avg` is the trailing week so a weekend dip reads as a dip; "
          "`reciprocal_pairs_7d` is pairs of people who each reacted to or commented on the other in the last seven days.\n\n| "
          + " | ".join(cols) + " |\n|" + "---|" * len(cols) + "\n")
row = "| " + " | ".join(str(d.get(c, "")) for c in cols) + " |\n"
text = path.read_text() if path.exists() else header
if "\n| day |" not in text and not text.startswith(header.split("\n\n")[0]):
    text = header
lines = [l for l in text.splitlines(keepends=True) if not l.startswith(f"| {d['day']} |")]
lines.append(row)
path.write_text("".join(lines))
problems = []
if d["photos_missing_renditions_24h"]: problems.append(f"{d['photos_missing_renditions_24h']} of {d['photos_24h']} captures missing renditions")
if d["develop_pushes_unsent_over_1h"]: problems.append(f"{d['develop_pushes_unsent_over_1h']} developed roll(s) with no push after an hour")
if d["push_deliveries_failed_terminal_24h"]: problems.append(f"{d['push_deliveries_failed_terminal_24h']} push(es) gave up after 3 tries")
if d["cron_failures_24h"]: problems.append(f"{d['cron_failures_24h']} cron failure(s)")
if d["edge_non_200_24h"]: problems.append(f"{d['edge_non_200_24h']} non-200 edge response(s)")
if d["crash_rows_24h"]: problems.append(f"{d['crash_rows_24h']} crash/hang row(s)")
if d["reports_unnotified"]: problems.append(f"{d['reports_unnotified']} report(s) the owner has not been told about")
summary = (f"{d['day']}: {d['openers']} opened (7d avg {d['openers_7d_avg']}), {d['shooters']} shot "
           f"{d['photos']} photos, {d['posts']} posts, {d['new_accounts']} new accounts")
print(("REGRESSION: " + "; ".join(problems) + " | " if problems else "QUIET: ") + summary)
PY
)
echo "$ALERT"
case "$ALERT" in
  REGRESSION*)
    DETAIL=$(printf '%s' "${ALERT#REGRESSION: }" | cut -d"|" -f1 | python3 -c 'import json,sys; print(json.dumps({"p_source":"nightly numbers","p_detail":sys.stdin.read().strip()}))')
    curl -sf "${AUTH[@]}" -X POST "$BASE/rpc/raise_ops_alert" -d "$DETAIL" >/dev/null;;
esac
