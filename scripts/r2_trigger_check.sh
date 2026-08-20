#!/bin/bash
# The R2 migration tripwire, run weekly by a scheduled job.
#
# Prints one line starting with TRIGGER when the owner-agreed threshold fires, otherwise a QUIET
# line. The thresholds, agreed 2026-08-21 after the full stay-or-migrate discussion:
#   - storage pace puts the 100 GB Supabase Pro ceiling under 26 weeks away, or
#   - modelled egress pace exceeds 100 GB/month (app opens x 9 MB/session), or
#   - weekly app opens exceed 2,000 (an early growth surge the other two would lag).
# The third trigger the gauges can't see, deliberately opening the invite list, stays human.
#
# Reads the long-lived service key from ~/.claude/flim-r2-watch.env (chmod 600, never in the
# repo); queries PostgREST directly so it works regardless of rotated management tokens.
set -euo pipefail
# CI provides FLIM_SERVICE_KEY as a secret; local runs read the private env file.
[ -z "${FLIM_SERVICE_KEY:-}" ] && source ~/.claude/flim-r2-watch.env
BASE="https://wxvwamwrjlrvqmuaafjv.supabase.co/rest/v1"
AUTH=(-H "apikey: $FLIM_SERVICE_KEY" -H "Authorization: Bearer $FLIM_SERVICE_KEY")

J=$(curl -s "${AUTH[@]}" -H "Content-Type: application/json" -X POST "$BASE/rpc/r2_watch_numbers")
python3 - "$J" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
gb = d["storage_bytes"] / 1073741824
pace_wk = (d["storage_bytes_14d"] / 1073741824) / 2
weeks_left = (100 - gb) / pace_wk if pace_wk > 0 else 9999
egress_mo = (d["app_opens_7d"] / 7) * 30 * 9 / 1024
opens = d["app_opens_7d"]
fired = []
if weeks_left < 26: fired.append(f"storage ceiling {weeks_left:.0f} weeks away at {pace_wk:.2f} GB/wk")
if egress_mo > 100: fired.append(f"modelled egress {egress_mo:.0f} GB/mo")
if opens > 2000: fired.append(f"{opens} app opens this week, growth surge")
if fired:
    print("TRIGGER: " + "; ".join(fired))
else:
    print(f"QUIET: {gb:.2f} GB stored, {pace_wk:.2f} GB/wk pace, {egress_mo:.1f} GB/mo modelled egress, {opens} opens/wk")
PY
