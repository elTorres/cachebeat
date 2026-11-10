#!/bin/sh
# cachebeat watcher: an inactivity timer that Claude Code runs as this skill's Stop hook (SKILL.md
# frontmatter, `asyncRewake: true`) — in the background, at the end of every turn, hook JSON on stdin.
# It stays silent while the session is active. Once the session has sat idle for the threshold it
# writes one line to stderr and exits 2: Claude Code wakes Claude with that line, and the wake-up
# request re-reads the conversation from the prompt cache, which restarts the cache TTL. Claude's
# one-character reply ends a turn, the Stop hook starts the next timer, and so on — Claude never
# re-arms anything, and nothing asks for permission. The newest timer wins; older ones exit.
#
# exit 0  nothing to say: not armed, stopped, superseded, or the cache is already cold
# exit 2  wake Claude: a heartbeat, or a one-line notice for the user (stopped itself / deadline)
#
# Only for sessions on the 1-hour cache TTL: once a reply shows 5-minute cache writes, it stops itself.
# The arguments come from the newest /cachebeat in the transcript (typed, or Claude's Skill call):
# [minutes] [hours], or "stop". State: $TMPDIR/cachebeat-<session> holds "<arm id> <N> <end> <hours>"
# plus, after a beat, "<newest reply then> <beat time>"; or "<arm id> stop". <session>.pid = newest
# timer. <end> is <hours> after the latest real activity (a request or a running tool); beats don't
# count, so an abandoned session stops <hours> after it went quiet.
# The hook's `timeout: 90000` in SKILL.md is load-bearing: Claude Code kills an asyncRewake hook at its
# timeout, 10 min by default, which would end every timer before a 50-minute beat.
# Test knobs: CACHEBEAT_UNIT (seconds per "minute", default 60), CACHEBEAT_TICK (poll seconds,
# default 30), CACHEBEAT_LOG (debug log file).

# Started the pre-hook way — `sh beat.sh <minutes> <hours>` as a background command, by a session that
# loaded the old SKILL.md. Its instructions re-arm on exit 0, so answering 0 would loop; exit 5 means
# "tell the user, do not re-arm" there.
if [ $# -gt 0 ]; then echo "cachebeat was updated: run /cachebeat again to re-arm it."; exit 5; fi

# On exit 2 Claude sees everything the hook wrote to stderr, so only the note may go there (fd 3).
exec 3>&2 2>/dev/null
set -f
IN=$(cat)
field() { printf '%s' "$IN" | grep -oE "\"$1\" *: *\"[^\"]*\"" | head -1 | sed 's/.*"\([^"]*\)"$/\1/'; }
SID=$(field session_id); F=$(field transcript_path)
[ -n "$SID" ] || exit 0
U=${CACHEBEAT_UNIT:-60}; TICK=${CACHEBEAT_TICK:-30}; TTL=$((60*U))   # the 1-hour cache TTL
S="${TMPDIR:-/tmp}/cachebeat-$SID"
log() { [ -n "$CACHEBEAT_LOG" ] && echo "$(date +%T) [$$] $*" >> "$CACHEBEAT_LOG"; }

# SessionEnd (/clear, /resume, exit): a wake-up goes to the Claude Code process, not to a session, so a
# timer left running would beat into the next conversation. Disarm; the timer exits on its next tick.
if [ "$(field hook_event_name)" = SessionEnd ]; then rm -f "$S" "$S.pid"; log "session end"; exit 0; fi
[ -r "$F" ] || exit 0

# --- the newest /cachebeat: a typed command, or Claude's Skill tool call ------------------------------
# Structural JSON only (bare quotes): text that merely quotes these lines is escaped (\") in the file.
NAME=$(sed -n 's/^name: *//p' "$(dirname "$0")/SKILL.md" | tr -d '\r ' | head -1)
NAME=${NAME:-cachebeat}; P="[A-Za-z0-9_./-]+:"
INV=$(grep -F "$NAME" "$F" | grep -E "\"role\":\"user\",\"content\":\"<command-message>[^<]*</command-message>\\\\n<command-name>/?($P)?$NAME</command-name>|\"name\":\"Skill\",\"input\":\\{\"skill\":\"($P)?$NAME\"" | tail -1)
int() { printf '%s' "$1" | sed -e 's/^[^0-9]*//' -e 's/[^0-9].*//' -e 's/^0*\([0-9]\)/\1/' | cut -c1-4; }   # leading integer, never octal
is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
if [ -n "$INV" ]; then
  ID=$(printf '%s' "$INV" | grep -oE '"uuid":"[^"]+","timestamp":"[^"]+"' | tail -1 | cut -d'"' -f4)
  { read -r CUR CURN _ CURH _; } < "$S"
  # a /cachebeat not acted on yet, or one armed by a version whose state had no <hours>
  if [ -n "$ID" ] && { [ "$ID" != "$CUR" ] || { is_int "$CURN" && ! is_int "$CURH"; }; }; then
    ARGS=$(printf '%s' "$INV" | grep -oE '<command-args>[^<]*</command-args>|"args":"[^"]*"' | tail -1 \
           | sed -e 's/<[^>]*>//g' -e 's/^"args":"//' -e 's/"$//')
    N=; H=; STOP=
    for t in $ARGS; do
      case "$t" in
        [Ss][Tt][Oo][Pp]|[Oo][Ff][Ff]) STOP=1 ;;
        *[0-9][hH]*) H=$(int "$t") ;;
        *[0-9]*) if [ -z "$N" ]; then N=$(int "$t"); elif [ -z "$H" ]; then H=$(int "$t"); fi ;;
      esac
    done
    if [ -n "$STOP" ]; then
      echo "$ID stop" > "$S"; log "stop"
    else
      N=${N:-50}; H=${H:-3}   # clamp: past ~55 min the 1-hour TTL can lapse before a beat lands
      [ "$N" -lt 5 ] && N=5; [ "$N" -gt 55 ] && N=55; [ "$H" -lt 1 ] && H=1; [ "$H" -gt 24 ] && H=24
      echo "$ID $N $(( $(date +%s) + H*60*U )) $H" > "$S" || exit 0; log "arm N=$N H=$H"
    fi
  fi
fi
{ read -r ID N END H CHECK BEAT_AT; } < "$S"
is_int "$N" && is_int "$END" && is_int "$H" || exit 0   # not armed, or stopped
echo $$ > "$S.pid"                                      # the newest timer wins
save() { echo "$ID $N $END $H${CHECK:+ $CHECK $BEAT_AT}" > "$S"; }
extend() { [ $((LAST + H*60*U)) -gt "$END" ] && { END=$((LAST + H*60*U)); save; }; }

# The last real model response (L): a main-chain assistant entry that Claude Code didn't synthesize
# itself (usage-limit and API-error notices). Only a request refreshes the cache — bookkeeping lines
# (queue-operation, mode, away_summary …) are written without one, so they must not reset the clock.
# BUSY: a tool is still running (its tool_use is the newest main-chain entry; this includes one waiting
# on a permission prompt). Both keep their last value while the transcript doesn't grow, or while the
# last 400 lines hold no request or tool result (e.g. a long tool flooding it with progress entries).
ASSIST='"type":"assistant","uuid":"'
RESULT='"role":"user","content":\[\{"tool_use_id":"'
sig() { printf '%s' "$1" | grep -oE '"type":"assistant","uuid":"[^"]+"' | tail -1 | cut -d'"' -f8; }
num() { printf '%s' "$1" | grep -oE "\"$2\":[0-9]+" | head -1 | grep -oE '[0-9]+$'; }
scan() {
  SIZE=$(wc -c < "$F")
  [ "$SIZE" = "$SCANNED" ] && return
  SCANNED=$SIZE
  REL=$(tail -n 400 "$F" | grep -F '"isSidechain":false' | grep -vF '"model":"<synthetic>"' | grep -E "$ASSIST|$RESULT")
  [ -n "$REL" ] || return
  case "$(printf '%s\n' "$REL" | tail -1)" in *'"content":[{"type":"tool_use"'*) BUSY=1 ;; *) BUSY= ;; esac
  A=$(printf '%s\n' "$REL" | grep -F "$ASSIST" | tail -1)
  [ -n "$A" ] && { L=$A; SIG=$(sig "$L"); }
  W=$(printf '%s\n' "$REL" | grep -F "$ASSIST" | grep -E '"ephemeral_(1h|5m)_input_tokens":[1-9]' | tail -1)
  case "$W" in '') ;; *'"ephemeral_1h_input_tokens":'[1-9]*) WRITES=1h ;; *) WRITES=5m ;; esac
}
refuse_short_ttl() {
  [ "$WRITES" = 5m ] || return 0
  echo "$ID stop" > "$S"; log "5-minute TTL"
  echo "cachebeat stopped itself: this session's prompt cache uses the 5-minute TTL, and cachebeat only works with the 1-hour TTL. Tell the user that in one short line; nothing else." >&3
  exit 2
}

sleep 2   # the hook can start a moment before Claude Code has written the turn's last entries
L=; SIG=; BUSY=; SCANNED=; WRITES=
scan; refuse_short_ttl; PREV=$SIG; LAST=$(date +%s)
[ -n "$CHECK" ] || extend
while :; do
  sleep "$TICK"
  [ "$(cat "$S.pid")" = $$ ] || { log "superseded"; exit 0; }
  # Git Bash / MSYS reports PPID=1 when the parent is a native Windows process (Claude Code), so
  # there is no parent to watch there; SessionEnd, the .pid file and the auto-stop still apply.
  [ "$PPID" = 1 ] || kill -0 "$PPID" || { log "Claude Code is gone"; exit 0; }
  { read -r ID2 N END _; } < "$S"
  [ "$ID2" = "$ID" ] || { log "re-armed or stopped"; exit 0; }
  case "$N$END" in ''|*[!0-9]*) log "stopped"; exit 0 ;; esac
  NOW=$(date +%s)
  if [ "$NOW" -ge "$END" ]; then
    echo "$ID stop" > "$S"; log "deadline"
    echo "cachebeat reached its auto-stop time and is now off. Tell the user that in one short line; nothing else." >&3
    exit 2
  fi
  scan; refuse_short_ttl
  if [ -n "$SIG" ] && [ "$SIG" != "$PREV" ]; then    # a new request: reset (a beat's reply isn't activity)
    PREV=$SIG; LAST=$NOW; [ -n "$CHECK" ] || extend
  fi

  # After a beat (CHECK = the newest reply when it fired): once the next reply has landed, did it read
  # the conversation from cache? If not, this session's cache expires too soon for a heartbeat to help.
  if [ -n "$CHECK" ] && [ -n "$SIG" ] && [ "$SIG" != "$CHECK" ]; then
    CHECK=; save
    R=$L; [ $((NOW - ${BEAT_AT:-0})) -le $((10*U)) ] || R=   # that reply came much later: proves nothing
    CR=$(num "$R" cache_read_input_tokens); CC=$(num "$R" cache_creation_input_tokens)
    log "after beat: cache_read=$CR cache_creation=$CC"
    # (A compaction rebuilds the cache whatever the TTL, so it proves nothing either.)
    if [ -n "$R" ] && ! tail -n 400 "$F" | grep -q '"subtype":"compact_boundary"' &&
       [ "${CC:-0}" -gt "${CR:-0}" ]; then
      echo "$ID stop" > "$S"
      echo "cachebeat stopped itself: its heartbeat came back uncached (cache_read=$CR, cache_creation=$CC), so this session's prompt cache expires too soon for a heartbeat to help. Tell the user that in one short line; nothing else." >&3
      exit 2
    fi
  fi

  [ -n "$BUSY" ] && { LAST=$NOW; extend; }   # a wake-up couldn't land before the running tool returns anyway
  IDLE=$((NOW - LAST))
  if [ "$IDLE" -ge $((TTL - U)) ]; then    # e.g. the machine slept through the TTL: a beat now would
    log "idle ${IDLE}s, cache already cold: standing down"; exit 0   # only pay to rebuild it
  fi
  if [ "$IDLE" -ge $((N*U)) ]; then
    CHECK=${SIG:-none}; BEAT_AT=$NOW; save; log "beat idle=${IDLE}s"   # marker for the next run
    echo "idle heartbeat to keep the prompt cache warm. Reply with exactly . and nothing else; no tools." >&3
    exit 2
  fi
done
