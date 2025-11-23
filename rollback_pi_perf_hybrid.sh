#!/usr/bin/env bash
# rollback_pi_perf_hybrid.sh
# Safe rollback for the production installer
#
# Usage: sudo bash rollback_pi_perf_hybrid.sh

set -euo pipefail
STATE_FILE="/var/lib/pi_perf_installer/state.json"
LOG="/var/log/pi_perf_hybrid_rollback.log"
exec > >(tee -a "$LOG") 2>&1

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0"; exit 1
fi

if [ ! -f "$STATE_FILE" ]; then
  echo "No state file found at $STATE_FILE - nothing to rollback safely. Exiting."
  exit 1
fi

echo "=== Pi Perf Hybrid ROLLBACK === $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
# parse state safely
STATE_JSON="$(cat "$STATE_FILE" | tr -d '\000' )"

# helper to read keys with jq safely
read_state() {
  echo "$STATE_JSON" | jq -r "$1" 2>/dev/null || echo ""
}

API_SERVICE_PATH="$(read_state '.api_service')"
API_DIR="$(read_state '.api_dir')"
SWAPFILE_RECORDED="$(read_state '.swapfile')"
SWAP_UUID_RECORDED="$(read_state '.swap_uuid')"

echo "[1] Stopping & disabling services (if present)"
for svc in pi-perf-api.service pi-perf-check.service; do
  if systemctl list-unit-files | grep -q "^${svc}"; then
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl reset-failed "$svc" 2>/dev/null || true
    echo " - disabled $svc"
  fi
done

echo "[2] Removing API directory if present: $API_DIR"
if [ -n "$API_DIR" ] && [ -d "$API_DIR" ]; then
  rm -rf "$API_DIR"
  echo " - removed $API_DIR"
fi

echo "[3] Restoring backups (*.pi_perf_bak) found in system"
# find .pi_perf_bak files and restore if safe
find / -type f -name "*.pi_perf_bak" 2>/dev/null | while read -r bak; do
  orig="${bak%.pi_perf_bak}"
  if [ -e "$orig" ]; then
    echo " - removing created file $orig"
    rm -f "$orig"
  fi
  echo " - restoring $bak -> $orig"
  mv -f "$bak" "$orig" || true
done

echo "[4] Remove swapfile only if UUID matches recorded UUID"
if [ -n "$SWAPFILE_RECORDED" ] && [ -f "$SWAPFILE_RECORDED" ]; then
  current_uuid="$(blkid -s UUID -o value "$SWAPFILE_RECORDED" 2>/dev/null || echo "")"
  if [ -n "$SWAP_UUID_RECORDED" ] && [ "$current_uuid" = "$SWAP_UUID_RECORDED" ]; then
    echo " - swapfile UUID matches recorded state; removing swapfile $SWAPFILE_RECORDED"
    swapoff "$SWAPFILE_RECORDED" 2>/dev/null || true
    rm -f "$SWAPFILE_RECORDED"
    # remove from fstab
    sed -i.bak "\%^${SWAPFILE_RECORDED}%d" /etc/fstab || true
  else
    echo " - swapfile present but UUID mismatch or not recorded; skipping removal for safety"
  fi
else
  echo " - no recorded swapfile present"
fi

echo "[5] Remove sysctl file we added if present"
SYSCTL_FILE="/etc/sysctl.d/99-pi-perf-hybrid.conf"
if [ -f "${SYSCTL_FILE}.pi_perf_bak" ]; then
  mv -f "${SYSCTL_FILE}.pi_perf_bak" "$SYSCTL_FILE" || true
  echo " - restored sysctl backup"
else
  if [ -f "$SYSCTL_FILE" ]; then
    rm -f "$SYSCTL_FILE"
    echo " - removed $SYSCTL_FILE"
  fi
fi

echo "[6] Restore zramswap config backup if present"
ZRAM_DEFAULT="/etc/default/zramswap"
if [ -f "${ZRAM_DEFAULT}.pi_perf_bak" ]; then
  mv -f "${ZRAM_DEFAULT}.pi_perf_bak" "$ZRAM_DEFAULT" || true
  echo " - restored zramswap backup"
fi

echo "Rollback finished. Inspect log: $LOG"
echo "Installer state file preserved at $STATE_FILE (remove manually if desired)"
exit 0
