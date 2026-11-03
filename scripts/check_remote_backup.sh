   
# Runs on the MAIN server once a day. Checks the newest report from the
# remote backup server and emails if it is missing/stale or shows problems.
# Uses TrueNAS's own email settings (System > General Settings > Email).
# Cron command: bash /mnt/data/scripts/check_remote_backup.sh

# ---------- Settings ----------
LOG="/mnt/data/ilyich/remote_backup.log"
REMOTE_NAME="ilyich"
MAX_AGE_HOURS=20        # alert if the newest report is older than this
WEEKLY_OK_DAY=7         # also send an "all OK" email on this day (1=Mon..7=Sun), 0 = never

# ---------- Helpers ----------
send_mail() {
  midclt call -j mail.send \
    "$(jq -n --arg s "$1" --arg t "$2" '{subject: $s, text: $t}')" > /dev/null
}

# ---------- Checks ----------
if [ ! -s "$LOG" ]; then
  send_mail "[$REMOTE_NAME] Backup check: no log found" "The report log $LOG is missing or empty."
  exit 1
fi

# Newest report = from the last "=====" header to the end of the file
LAST=$(awk '/^===== /{buf=""} {buf = buf $0 "\n"} END {printf "%s", buf}' "$LOG")
HEADER=$(printf '%s\n' "$LAST" | head -n 1)

# Header format: ===== host report YYYY-MM-DD HH:MM:SS TZ =====
STAMP=$(echo "$HEADER" | awk '{print $4, $5, $6}')
REPORT_EPOCH=$(date -d "$STAMP" +%s 2>/dev/null || echo 0)
AGE_H=$(( ($(date +%s) - REPORT_EPOCH) / 3600 ))

PROBLEMS=()

if [ "$AGE_H" -ge "$MAX_AGE_HOURS" ]; then
  PROBLEMS+=("No new report in the last ${MAX_AGE_HOURS}h (newest: ${STAMP:-unknown}). The remote may not have woken up, or could not reach this server.")
else
  grep -q "still busy" <<<"$LAST" &&
    PROBLEMS+=("Replication did not finish within the time limit.")
  grep -q "^Task:" <<<"$LAST" ||
    PROBLEMS+=("Report lists no replication tasks.")
  grep "^  State:" <<<"$LAST" | grep -vq "FINISHED" &&
    PROBLEMS+=("A replication task did not finish successfully.")
  grep "^  Error:" <<<"$LAST" | grep -vq "none$" &&
    PROBLEMS+=("A replication task reported an error.")
  grep "^  Warnings:" <<<"$LAST" | grep -vq "none$" &&
    PROBLEMS+=("A replication task reported warnings.")
  grep -q "^Pool:" <<<"$LAST" ||
    PROBLEMS+=("Report has no pool status (pool may not be imported).")
  grep "^Pool:" <<<"$LAST" | grep -vq "health=ONLINE" &&
    PROBLEMS+=("Backup pool is not healthy.")
  grep "errors:" <<<"$LAST" | grep -vq "No known data errors" &&
    PROBLEMS+=("Backup pool reports data errors.")
fi

# ---------- Notify ----------
if [ ${#PROBLEMS[@]} -gt 0 ]; then
  BODY="$(printf -- '- %s\n' "${PROBLEMS[@]}")

Newest report:
$LAST"
  send_mail "[$REMOTE_NAME] Backup problem detected" "$BODY"
elif [ "$(date +%u)" -eq "$WEEKLY_OK_DAY" ]; then
  send_mail "[$REMOTE_NAME] Backup OK" "No problems found this week.

Newest report:
$LAST"
fi
