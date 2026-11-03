# Post Init script. Makes sure the USB pool came up after boot.
# If it didn't: reset the USB enclosure and reboot, or power off and cold-boot
# again later. Also tells the kernel to spin the drive down at shutdown so it
# isn't powered off while spinning.
# TrueNAS: System > Advanced > Init/Shutdown Scripts
#   Type: Script, Script: /root/scripts/boot_check.sh, When: Post Init, Timeout: 600

# ---------- Settings ----------
POOL="tank"
USB_ID="152d:0583"        # JMicron enclosure (from lsusb)
WAKE_TIME="02:00"         # same as shutdown.sh
MAX_RETRIES=3             # boot retries before giving up until tomorrow
COLD_RETRY_MIN=30         # minutes powered off before a cold retry
DIR="/root/scripts"
LOG="$DIR/boot.log"
COUNT_FILE="$DIR/.boot_retries"
STAY_ON_FLAG="$DIR/stay_on"

# ---------- Helpers ----------
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

usb_dev() {   # sysfs directory of the enclosure, if it enumerated
  local d
  for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ] || continue
    if [ "$(cat "$d/idVendor"):$(cat "$d/idProduct")" = "$USB_ID" ]; then
      readlink -f "$d"
      return 0
    fi
  done
  return 1
}

disk_size() { # sectors the enclosure's disk reports; 0 if none or not ready
  local dev b
  dev=$(usb_dev) || { echo 0; return; }
  b=$(find "$dev" -type d -path '*/block/sd*' -prune 2>/dev/null | head -1)
  if [ -n "$b" ]; then cat "$b/size"; else echo 0; fi
}

enable_clean_spindown() {  # kernel sends STOP UNIT at shutdown, after ZFS is done
  local dev f
  dev=$(usb_dev) || return
  for f in $(find "$dev" -path '*/scsi_disk/*/manage_shutdown' 2>/dev/null); do
    echo 1 > "$f" && log "clean spin-down at shutdown enabled ($f)"
  done
}

# ---------- Main ----------
mkdir -p "$DIR"
log "boot check started"

# Give TrueNAS up to 2 minutes to finish importing
for _ in $(seq 1 24); do
  zpool list "$POOL" >/dev/null 2>&1 && break
  sleep 5
done

if zpool list "$POOL" >/dev/null 2>&1; then
  rm -f "$COUNT_FILE"
  enable_clean_spindown
  log "$POOL is online"
  exit 0
fi

n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
log "$POOL missing after boot (failure $((n + 1))), disk reports $(disk_size) sectors"

if [ -e "$STAY_ON_FLAG" ]; then
  log "stay_on flag set; not retrying"
  exit 0
fi

if [ "$n" -ge "$MAX_RETRIES" ]; then
  rm -f "$COUNT_FILE"
  NEXT=$(date -d "tomorrow $WAKE_TIME" +%s)
  log "giving up for today; powering off until $(date -d "@$NEXT" '+%F %T %Z')"
  rtcwake -m off -t "$NEXT" >> "$LOG" 2>&1
  exit 0
fi
echo $((n + 1)) > "$COUNT_FILE"

# First try re-attaching the enclosure (the drive has had time to spin up by now)
dev=$(usb_dev)
if [ -n "$dev" ]; then
  log "resetting USB device $dev"
  echo 0 > "$dev/authorized"; sleep 10
  echo 1 > "$dev/authorized"; sleep 45
fi

if [ "$(disk_size)" -gt 0 ]; then
  log "disk visible after USB reset; rebooting so TrueNAS imports $POOL"
  systemctl reboot
else
  log "disk still not ready; powering off, cold retry in $COLD_RETRY_MIN min"
  rtcwake -m off -s $((COLD_RETRY_MIN * 60)) >> "$LOG" 2>&1
fi
