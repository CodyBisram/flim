#!/bin/bash
# Weekly creator outreach, Mondays 08:00 New York, on the Pi (flim-outreach.timer).
#
#   outreach-weekly.sh             research, gate, mint one code per person, draft, send, commit, push
#   outreach-weekly.sh --dry-run   research, gate, Gmail drafts marked DRY RUN; no code minted,
#                                  nothing sent, nothing committed or pushed
#
# Five steps, each with only what it needs (docs/ROUTINES.md, "Weekly outreach"):
#   1. Preflight: the database (SET ROLE flim_outreach, outreach_codes_status) and Gmail
#      (headless Claude, ToolSearch only, loads the two Gmail tools and calls neither). Either
#      failing stops the run before any research, any code or any email.
#   2. Research: headless Claude with Read, Glob, Grep, Write, Edit, WebSearch, WebFetch and no
#      MCP tool at all follows the creator-shortlist skill and writes social/outreach/<date>.md
#      plus a plan of the emails it passed through the written gate.
#   3. Gate: scripts/pi/outreach_gate.py re-checks every rule a program can check, including
#      re-reading the page that publishes each address. Anything that fails is held.
#   4. Send: codes minted here, in shell, one per passing entry; then headless Claude with
#      ToolSearch, create_draft and send_message only, and the exact emails in its prompt.
#   5. Status lines written, the file checked for codes, committed and pushed, one ntfy push.
#
# Claude runs on the Pi's claude.ai login (~/.claude/.credentials.json from /login), NOT the
# setup-token in CLAUDE_CODE_OAUTH_TOKEN: that token cannot load claude.ai connectors, so it is
# removed from this script's environment. The repo is public: no code is ever written into it;
# the name to code mapping lives only in the code's note in the database.
set -u

main() {
  DRY=0
  case "${1:-}" in
    --dry-run) DRY=1 ;;
    "") ;;
    *) echo "usage: $0 [--dry-run]"; return 2 ;;
  esac

  OPS=~/work/flim-ops; REPO=~/work/flim; HERE=$REPO/scripts/pi
  DATE=$(TZ=America/New_York date +%F); WEEK=$(TZ=America/New_York date +"%b %-d")
  SUFFIX=""; MODE="real run"; [ $DRY = 1 ] && { SUFFIX="-dry"; MODE="dry run"; }
  RUN=$OPS/outreach/$DATE$SUFFIX; LOG=$OPS/logs/outreach-$DATE$SUFFIX.log
  FILE=social/outreach/$DATE.md
  umask 077
  mkdir -p "$OPS/logs" "$RUN"
  # shellcheck disable=SC1090
  [ -f ~/.config/watchdog.env ] && . ~/.config/watchdog.env      # NTFY_URL, NTFY_TOPIC, NTFY_TOKEN
  DB_URL=$(sed -n 's/^FLIM_DB_URL=//p' ~/.config/flim-hooks.env 2>/dev/null | head -1)
  # Codes live in these files for the length of one run and are deleted on the way out.
  trap 'rm -f "$RUN/send.json" "$RUN/codes.json" "$RUN/status.tsv" "$RUN/part-b.txt"' EXIT

  exec 9>"$OPS/.lock-outreach"; flock -n 9 || return 0
  exec 8>"$OPS/.lock-repo"; flock -w 900 8 || { stop "another job held ~/work/flim for 15 minutes"; return 1; }
  echo "== $(date -Is) outreach $MODE" >> "$LOG"

  # A real run happens once per date. The marker is written before the send step starts, so a
  # crash or a failed push after sending can never lead to a second email to anyone.
  if [ $DRY = 0 ] && [ -e "$OPS/outreach/$DATE/SEND_STARTED" ]; then
    stop "a real run already reached the send step today; not running again"; return 1
  fi

  cd "$REPO" || { stop "no clone at $REPO"; return 1; }
  git fetch -q origin && git checkout -q main && git reset -q --hard origin/main && git clean -qfd \
    || { stop "git sync of ~/work/flim failed"; return 1; }
  if git cat-file -e "origin/main:$FILE" 2>/dev/null; then
    stop "$FILE is already on main; one batch per day"; return 1
  fi

  # ---- 1. Preflight --------------------------------------------------------------------------
  [ -n "$DB_URL" ] || { stop "no FLIM_DB_URL in ~/.config/flim-hooks.env"; return 1; }
  db_status > "$RUN/status.tsv" 2>> "$LOG" \
    || { stop "database unreachable, or flim_outreach not granted to the Pi's role (see the log)"; return 1; }
  CAN_MINT=$(printf 'SET ROLE flim_outreach;\nSELECT has_function_privilege(%s, %s);\n' \
    "'public.mint_outreach_code(text)'" "'EXECUTE'" | db 2>> "$LOG")
  [ "$CAN_MINT" = t ] || { stop "flim_outreach cannot execute mint_outreach_code"; return 1; }
  EARLIER_USED=$(awk -F'\t' -v today="outreach $DATE:" '$2 > 0 && index($3, today) != 1' "$RUN/status.tsv" | wc -l | tr -d ' ')

  PRE=$(printf '%s\n' 'Call ToolSearch exactly once with the query "select:mcp__claude_ai_Gmail__create_draft,mcp__claude_ai_Gmail__send_message". Call no other tool. Reply with one line: GMAIL_OK if both tool schemas came back, otherwise GMAIL_MISSING and what you saw.' \
    | claude_run "$RUN" 300 --model sonnet --tools ToolSearch --allowedTools "ToolSearch" 2>> "$LOG")
  echo "preflight: $PRE" >> "$LOG"
  case "$PRE" in
    *GMAIL_OK*) ;;
    *) stop "Gmail tools not reachable from headless Claude. On the Pi: claude /login with the claude.ai account (not the setup token), then /mcp should list claude.ai Gmail as connected"; return 1 ;;
  esac

  # ---- 2. Research ---------------------------------------------------------------------------
  part A | sed -e "s|__DATE__|$DATE|g" -e "s|__MODE__|$MODE|g" > "$RUN/part-a.txt"
  claude_run "$REPO" 5400 --model "${OUTREACH_MODEL:-opus}" \
    --tools "Read,Glob,Grep,Write,Edit,WebSearch,WebFetch" \
    --allowedTools "Read,Glob,Grep,Write,Edit,WebSearch,WebFetch" \
    --disallowedTools "mcp__*" < "$RUN/part-a.txt" >> "$LOG" 2>&1
  [ -f "$FILE" ] && [ -f social/outreach/.plan.json ] \
    || { stop "the research step wrote no batch file or no plan (see $LOG)"; return 1; }
  mv social/outreach/.plan.json "$RUN/plan.json"
  OTHER=$(git status --porcelain | grep -v " $FILE\$" || true)
  [ -z "$OTHER" ] || { stop "the research step touched other files: $(echo "$OTHER" | tr '\n' ' ')"; return 1; }

  # ---- 3. Gate -------------------------------------------------------------------------------
  python3 "$HERE/outreach_gate.py" gate --plan "$RUN/plan.json" --file "$FILE" --out "$RUN/gate.json" >> "$LOG" 2>&1 \
    || { stop "the gate could not read the plan (see $LOG)"; return 1; }
  PASSING=$(python3 -c 'import json,sys; print(sum(1 for g in json.load(open(sys.argv[1])) if g["pass"]))' "$RUN/gate.json")

  # ---- 4. Codes, drafts, sends ---------------------------------------------------------------
  SENDSTEP=""
  if [ "$PASSING" -gt 0 ]; then
    if [ $DRY = 0 ]; then
      mint_all || { stop "minting failed; nothing was sent (see $LOG)"; return 1; }
      python3 "$HERE/outreach_gate.py" assemble --gate "$RUN/gate.json" --codes "$RUN/codes.json" --out "$RUN/send.json" >> "$LOG"
      ALLOW="ToolSearch,mcp__claude_ai_Gmail__create_draft,mcp__claude_ai_Gmail__send_message"
      touch "$RUN/SEND_STARTED"
    else
      python3 "$HERE/outreach_gate.py" assemble --gate "$RUN/gate.json" --dry --out "$RUN/send.json" >> "$LOG"
      ALLOW="ToolSearch,mcp__claude_ai_Gmail__create_draft"
    fi
    part B | python3 -c '
import sys
tpl = sys.stdin.read()
send = open(sys.argv[1]).read().strip()
print(tpl.replace("__DATE__", sys.argv[2]).replace("__MODE__", sys.argv[3]).replace("__SENDLIST__", send))
' "$RUN/send.json" "$DATE" "$MODE" > "$RUN/part-b.txt"
    SENDSTEP="--sendstep"
    claude_run "$RUN" 1800 --model sonnet --tools ToolSearch --allowedTools "$ALLOW" \
      < "$RUN/part-b.txt" > "$RUN/part-b.out" 2>> "$LOG"
    # The reply's last JSON line is the result. Unreadable means unconfirmed, never "held".
    python3 - "$RUN/part-b.out" "$RUN/result.json" <<'PY' >> "$LOG" 2>&1 || true
import json, sys
lines = [l.strip() for l in open(sys.argv[1], encoding="utf-8", errors="replace") if l.strip().startswith("{")]
for l in reversed(lines):
    try:
        d = json.loads(l)
    except ValueError:
        continue
    if isinstance(d.get("results"), list):
        json.dump(d, open(sys.argv[2], "w"))
        print("send step result read")
        break
else:
    print("send step result NOT readable")
PY
  fi

  # ---- 5. Status, leak check, commit, push, alert --------------------------------------------
  COUNTS=$(python3 "$HERE/outreach_gate.py" finalize --gate "$RUN/gate.json" --result "$RUN/result.json" \
    --file "$FILE" --date "$DATE" $SENDSTEP $([ $DRY = 1 ] && echo --dry) 2>> "$LOG")
  SENT=${COUNTS% *}; HELD=${COUNTS#* }
  [ -n "$SENT" ] || { SENT="?"; HELD="?"; }
  UNREAD=""; [ -n "$SENDSTEP" ] && [ ! -f "$RUN/result.json" ] && UNREAD=" The send step's result was unreadable: check Gmail Sent."

  if [ $DRY = 1 ]; then
    cp "$FILE" "$OPS/logs/outreach-$DATE-dry.md"
    git reset -q --hard origin/main && git clean -qfd
    alert "FLIM outreach dry run" "Outreach dry run: $SENT drafted in Gmail (subject starts DRY RUN, delete them), $HELD held, nothing sent, no codes minted, $EARLIER_USED earlier codes used. File: $OPS/logs/outreach-$DATE-dry.md" "information_source"
    return 0
  fi

  { db_status 2>/dev/null | cut -f1; [ -f "$RUN/codes.json" ] && python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).values()))' "$RUN/codes.json"; } \
    | python3 "$HERE/outreach_gate.py" leakcheck --file "$FILE" \
    || { alert "FLIM outreach: NOT committed" "Outreach: $SENT sent, $HELD held, $EARLIER_USED earlier codes used. The batch file carried an invite code or link, so it was not committed; copy kept at $OPS/logs/outreach-$DATE.md.$UNREAD" "warning"; cp "$FILE" "$OPS/logs/outreach-$DATE.md"; return 1; }

  git add "$FILE" && git commit -q -m "Outreach for $WEEK: $SENT sent, $HELD held." >> "$LOG" 2>&1
  PUSHED=0
  for _ in 1 2 3; do
    if git pull -q --rebase origin main >> "$LOG" 2>&1 && git push -q origin main >> "$LOG" 2>&1; then PUSHED=1; break; fi
    sleep 20
  done
  NOTE=""; [ $PUSHED = 1 ] || { NOTE=" The commit did not push; it is on the Pi's clone only, and the next job's reset will drop it. Copy kept at $OPS/logs/outreach-$DATE.md."; cp "$FILE" "$OPS/logs/outreach-$DATE.md"; }
  alert "FLIM outreach" "Outreach: $SENT sent, $HELD held, $EARLIER_USED earlier codes used.$UNREAD$NOTE" "$([ $PUSHED = 1 ] && [ -z "$UNREAD" ] && echo email || echo warning)"
}

# The two prompt parts, cut from outreach-prompt.md at the "=== PART" lines.
part() { awk -v want="=== PART $1:" 'index($0, "=== PART ") == 1 { on = (index($0, want) == 1); next } on' "$HERE/outreach-prompt.md"; }

# Headless Claude on the claude.ai login, with no permission prompts: anything not in
# --allowedTools is refused (dontAsk), no user or local settings file can widen that
# (--setting-sources project; the repo tracks no settings file), and --tools removes every
# other built-in tool from view. Prompt on stdin, never on the command line.
claude_run() {
  local dir=$1 secs=$2; shift 2
  (cd "$dir" && env -u CLAUDE_CODE_OAUTH_TOKEN -u GH_TOKEN -u ANTHROPIC_API_KEY \
    timeout "$secs" claude -p --output-format text --permission-mode dontAsk --setting-sources project "$@")
}

db() { psql "$DB_URL" -X -q -At -F $'\t' -v ON_ERROR_STOP=1 "$@"; }
db_status() { printf 'SET ROLE flim_outreach;\nSELECT code, uses, note FROM public.outreach_codes_status();\n' | db; }

# One code per passing entry, keyed by entry number. The name goes in as a psql variable, quoted
# by psql, never spliced into SQL.
mint_all() {
  python3 -c 'import json,sys
for g in json.load(open(sys.argv[1])):
    if g["pass"]: print(str(g["n"]) + "\t" + g["name"])' "$RUN/gate.json" > "$RUN/to-mint.tsv"
  echo "{}" > "$RUN/codes.json"
  local n name code
  while IFS=$'\t' read -r n name; do
    code=$(db -v name="$name" <<'SQL' 2>> "$LOG"
SET ROLE flim_outreach;
SELECT public.mint_outreach_code(:'name');
SQL
)
    [[ "$code" =~ ^[A-Z0-9]{6}$ ]] || return 1
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d[sys.argv[2]]=sys.argv[3]; json.dump(d, open(p, "w"))' "$RUN/codes.json" "$n" "$code"
  done < "$RUN/to-mint.tsv"
  rm -f "$RUN/to-mint.tsv"
}

alert() {
  echo "ALERT: $1: $2" >> "$LOG"
  [ -n "${NTFY_URL:-}" ] && curl -s -o /dev/null --max-time 20 -H "Authorization: Bearer ${NTFY_TOKEN:-}" \
    -H "Title: $1" -H "Tags: $3" -d "$2" "$NTFY_URL/${NTFY_TOPIC:-alerts}"
  return 0
}
stop() { alert "FLIM outreach: nothing sent" "$1" "x"; }

main "$@"; exit $?
