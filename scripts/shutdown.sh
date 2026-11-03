# Waits for replication (and the weekly scrub) to finish, sends a status
# report to the main server, then powers off and sets an RTC alarm for
# WAKE_TIME tomorrow. Cron command: bash /root/scripts/shutdown.sh

# ---------- Settings ----------
WAKE_TIME="02:00"
MAX_WAIT_MIN=360
POOL="tank"
SCRUB_DAY=7
SCRIPT_DIR="/root/scripts"
LOG="$SCRIPT_DIR/power.log"
STAY_ON_FLAG="$SCRIPT_DIR/stay_on"

MAIN="truenas_admin@100.75.161.40"
MAIN_FLAG="/mnt/data/ilyich/stay_on"
MAIN_LOG="/mnt/data/ilyich/remote_backup.log"
SSH_KEY="$SCRIPT_DIR/krupskaya.pem"
KNOWN_HOSTS="$SCRIPT_DIR/known_hosts"

# ---------- Helpers ----------
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

ssh_main() {
  ssh -i "$SSH_KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" \
      -o BatchMode=yes -o ConnectTimeout=15 "$MAIN" "$@"
}

pool_ok() { zpool list "$POOL" >/dev/null 2>&1; }

busy() {
  local n
  n=$(midclt call core.get_jobs '[["state","=","RUNNING"],["method","=","replication.run"]]' | jq length)
  [ "${n:-0}" -gt 0 ] && return 0
  zpool status "$POOL" 2>/dev/null | grep -q "in progress" && return 0
  return 1
}

report() {
  echo "===== $(hostname) report $(date '+%F %T %Z') ====="
  echo "Powered on:  $(uptime -s)"
  echo "Outcome:     $1"
  echo
  midclt call replication.query | jq -r '.[] |
    (.state.datetime
      | if type == "object" then ."$date" else . end
      | if type == "number" then (. / 1000 | strftime("%F %T UTC"))
        elif . == null then "n/a" else tostring end) as $when |
    "Task:        \(.name)\n  State:     \(.state.state // "unknown")\n  Last run:  \($when)\n  Last snap: \(.state.last_snapshot // "n/a")\n  \n  Error:     \(.state.error // "none")\n  Warnings:  \(.state.warnings // [] | if length == 0 then "none" else join("; ") end)"'
  echo
  if pool_ok; then
    zpool list -H -o name,health,size,alloc,free,cap "$POOL" |
      awk '{print "Pool: "$1"  health="$2"  size="$3"  used="$4"  free="$5"  cap="$6}'
    zpool status "$POOL" | grep -E "scan:|errors:" | sed 's/^ */  /'
  else
    echo "Pool: $POOL NOT IMPORTED"
  fi
  echo
}

# ---------- Main ----------
log "check started"

if ! pool_ok; then
  OUTCOME="pool $POOL not imported; no replication possible"
else
  # Wait for replication / any running scrub, up to MAX_WAIT_MIN minutes
  i=0
  while [ "$i" -lt "$MAX_WAIT_MIN" ] && busy; do
    sleep 60
    i=$((i + 1))
  done

  if busy; then
    OUTCOME="still busy after ${MAX_WAIT_MIN} min; replication will resume next run"
  else
    OUTCOME="replication done (waited ${i} min)"
  fi

  # Weekly scrub, run after replication so they don't compete
  if [ "$(date +%u)" -eq "$SCRUB_DAY" ]; then
    log "weekly scrub starting"
    zpool scrub -w "$POOL"
    log "weekly scrub finished"
    OUTCOME="$OUTCOME; weekly scrub done"
  fi
fi
log "$OUTCOME"

# Stay on if a flag exists locally or on the main server
if [ -e "$STAY_ON_FLAG" ] || ssh_main test -e "$MAIN_FLAG"; then
  STAY_ON=1
  OUTCOME="$OUTCOME; stay-on flag set, staying on"
else
  STAY_ON=0
  NEXT=$(date -d "tomorrow $WAKE_TIME" +%s)
  OUTCOME="$OUTCOME; shutting down, next wake $(date -d "@$NEXT" '+%F %T %Z')"
fi

# Write report locally and append it to the log on the main server
report "$OUTCOME" | tee -a "$LOG" | ssh_main "cat >> '$MAIN_LOG'" \
  || log "could not send report to main server"

[ "$STAY_ON" -eq 1 ] && exit 0
rtcwake -m off -t "$NEXT" >> "$LOG" 2>&1
