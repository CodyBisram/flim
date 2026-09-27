#!/bin/bash
# Weekly creator outreach, Mondays 08:00 New York, on the Pi (flim-outreach.timer).
#
#   outreach-weekly.sh             research, gate, mint one code per person, draft, send, commit, push
#   outreach-weekly.sh --dry-run   research, gate, every email sent to the owner only, subject
#                                  starting DRY RUN; no code minted, nothing committed or pushed
#
# Five steps, each with only what it needs (docs/ROUTINES.md, "Weekly outreach"):
#   1. Preflight: the database (SET ROLE flim_outreach, outreach_codes_status) and Gmail (an
#      SMTP login with the app password, nothing sent). Either failing stops the run before any
#      research, any code or any email.
#   2. Research: headless Claude with Read, Glob, Grep, Write, Edit, WebSearch, WebFetch and no
#      MCP tool at all follows the creator-shortlist skill and writes social/outreach/<date>.md
#      plus a plan of the emails it passed through the written gate.
#   3. Gate: scripts/pi/outreach_gate.py re-checks every rule a program can check, including
#      re-reading the page that publishes each address. Anything that fails is held.
#   4. Send: codes minted here, in shell, one per passing entry; then outreach_send.py hands the
#      exact emails to Gmail's SMTP server. Not the Gmail connector: it rewrote every link into an
#      expiring google.com redirect (the first batch, 2026-09-25).
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
  # The postal address every email must carry (CAN-SPAM). Kept on the Pi, never in the public repo.
  POSTAL=$(sed -n 's/^FLIM_OUTREACH_POSTAL=//p' ~/.config/flim-hooks.env 2>/dev/null | head -1)
  POSTAL=${POSTAL#[\"\']}; POSTAL=${POSTAL%[\"\']}   # a quoted value must not put the quotes in every email
  # The Gmail account the emails go out from, and an app password for it (Google Account,
  # Security, App passwords). Handed to outreach_send.py through its environment only.
  GMAIL_ADDRESS=$(sed -n 's/^FLIM_GMAIL_ADDRESS=//p' ~/.config/flim-hooks.env 2>/dev/null | head -1)
  GMAIL_ADDRESS=${GMAIL_ADDRESS#[\"\']}; GMAIL_ADDRESS=${GMAIL_ADDRESS%[\"\']}
  GMAIL_APP_PASSWORD=$(sed -n 's/^FLIM_GMAIL_APP_PASSWORD=//p' ~/.config/flim-hooks.env 2>/dev/null | head -1)
  GMAIL_APP_PASSWORD=${GMAIL_APP_PASSWORD#[\"\']}; GMAIL_APP_PASSWORD=${GMAIL_APP_PASSWORD%[\"\']}
  # Codes live in these files for the length of one run and are deleted on the way out.
  trap 'rm -f "$RUN/send.json" "$RUN/codes.json" "$RUN/status.tsv"' EXIT

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
  [ -n "$POSTAL" ] || { stop "no FLIM_OUTREACH_POSTAL in ~/.config/flim-hooks.env; every email needs a postal address"; return 1; }
  db_status > "$RUN/status.tsv" 2>> "$LOG" \
    || { stop "database unreachable, or flim_outreach not granted to the Pi's role (see the log)"; return 1; }
  CAN_MINT=$(printf 'SET ROLE flim_outreach;\nSELECT has_function_privilege(%s, %s);\n' \
    "'public.mint_outreach_code(text)'" "'EXECUTE'" | db 2>> "$LOG")
  [ "$CAN_MINT" = t ] || { stop "flim_outreach cannot execute mint_outreach_code"; return 1; }
  EARLIER_USED=$(awk -F'\t' -v today="outreach $DATE:" '$2 > 0 && index($3, today) != 1' "$RUN/status.tsv" | wc -l | tr -d ' ')

  { [ -n "$GMAIL_ADDRESS" ] && [ -n "$GMAIL_APP_PASSWORD" ]; } \
    || { stop "no FLIM_GMAIL_ADDRESS or FLIM_GMAIL_APP_PASSWORD in ~/.config/flim-hooks.env"; return 1; }
  PRE=$(gmail_send --check 2>> "$LOG")
  echo "preflight: $PRE" >> "$LOG"
  [ "$PRE" = GMAIL_OK ] \
    || { stop "Gmail SMTP login failed (see the log): check FLIM_GMAIL_ADDRESS and the app password"; return 1; }

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
      python3 "$HERE/outreach_gate.py" assemble --gate "$RUN/gate.json" --codes "$RUN/codes.json" --postal "$POSTAL" --out "$RUN/send.json" >> "$LOG" \
        || { stop "assembling the emails failed; nothing was sent (see $LOG)"; return 1; }
      touch "$RUN/SEND_STARTED"
    else
      python3 "$HERE/outreach_gate.py" assemble --gate "$RUN/gate.json" --dry --postal "$POSTAL" --out "$RUN/send.json" >> "$LOG" \
        || { stop "assembling the drafts failed (see $LOG)"; return 1; }
    fi
    SENDSTEP="--sendstep"
    # Straight to Gmail's SMTP server, not the Gmail connector: the connector rewrote every link
    # into an expiring google.com redirect. A dry run sends each email to the owner instead.
    # result.json is written as it goes; a missing one means the step died before any send.
    gmail_send --send "$RUN/send.json" --out "$RUN/result.json" $([ $DRY = 1 ] && echo --dry) >> "$LOG" 2>&1 || true
  fi

  # ---- 5. Status, leak check, commit, push, alert --------------------------------------------
  COUNTS=$(python3 "$HERE/outreach_gate.py" finalize --gate "$RUN/gate.json" --result "$RUN/result.json" \
    --file "$FILE" --date "$DATE" $SENDSTEP $([ $DRY = 1 ] && echo --dry) 2>> "$LOG")
  SENT=${COUNTS% *}; HELD=${COUNTS#* }
  [ -n "$SENT" ] || { SENT="?"; HELD="?"; }
  UNREAD=""; [ -n "$SENDSTEP" ] && [ ! -f "$RUN/result.json" ] && UNREAD=" The send step left no result: check Gmail Sent."

  if [ $DRY = 1 ]; then
    cp "$FILE" "$OPS/logs/outreach-$DATE-dry.md"
    git reset -q --hard origin/main && git clean -qfd
    alert "FLIM outreach dry run" "Outreach dry run: $SENT test copies sent to you (subject starts DRY RUN), $HELD held, nothing sent to anyone else, no codes minted, $EARLIER_USED earlier codes used. File: $OPS/logs/outreach-$DATE-dry.md" "information_source"
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

# The Gmail credentials reach the sender through its environment only, never its arguments.
gmail_send() {
  FLIM_GMAIL_ADDRESS="$GMAIL_ADDRESS" FLIM_GMAIL_APP_PASSWORD="$GMAIL_APP_PASSWORD" \
    python3 "$HERE/outreach_send.py" "$@"
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
