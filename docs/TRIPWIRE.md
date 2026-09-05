# FLIM weekly tripwire log

- 2026-08-26: egress run-rate 17.4GB/mo of 250GB PASS (first logged as ALERT against the dead 5GB free-tier gate; recalibrated to Pro same day) · pg_net 3.3MB PASS · crons PASS · backlog 0 PASS · db 34MB (baseline)
- 2026-09-05: egress run-rate 21.0GB/mo of 250GB PASS · pg_net 15MB PASS (up from 3.3MB baseline, no recurring VACUUM) · crons PASS · backlog 0 PASS · db 49MB (+44% vs 34MB baseline, most of the delta is pg_net bloat)
