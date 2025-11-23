#!/usr/bin/env bash
# install_pi_perf_hybrid.sh
# Production-grade installer:
# - installs jq (if missing), zram-tools, sysbench, python venv/pip
# - configures hybrid swap (zram + /swapfile fallback)
# - installs /usr/local/bin/pi_perf_check.sh
# - installs Flask API under /opt/pi_perf_api and auto-starts it
# - makes safe backups and records state to /var/lib/pi_perf_installer/state.json
#
# Usage: sudo bash install_pi_perf_hybrid.sh

set -euo pipefail
LOG="/var/log/pi_perf_hybrid_installer.log"
STATE_DIR="/var/lib/pi_perf_installer"
STATE_FILE="${STATE_DIR}/state.json"
exec > >(tee -a "$LOG") 2>&1

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0"
  exit 1
fi

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

echo "=== Pi Perf Hybrid Installer === $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# 0) Ensure apt index updated and jq present (pre-check)
echo "[step 0] Ensuring jq present"
if ! command -v jq >/dev/null 2>&1; then
  apt update -y
  apt install -y jq || { echo "Failed to install jq"; exit 1; }
fi

# helper: safe backup
backup_if_exists() {
  local src="$1"
  if [ -e "$src" ] && [ ! -e "${src}.pi_perf_bak" ]; then
    mkdir -p "$(dirname "${src}.pi_perf_bak")"
    cp -a "$src" "${src}.pi_perf_bak"
    echo "backup:$src" >> "${STATE_DIR}/backups.txt"
  fi
}

# 1) packages
echo "[step 1] Installing packages"
apt update -y
apt install -y zram-tools sysbench python3-venv python3-pip || true

# 2) detect hardware, strip nulls
MODEL_RAW="$(cat /proc/device-tree/model 2>/dev/null || echo unknown)"
MODEL="$(printf '%s' "$MODEL_RAW" | tr -d '\000' | tr -d '\r\n')"
TOTAL_RAM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo || echo 0)"
TOTAL_RAM_MB=$((TOTAL_RAM_KB/1024))
echo "[step 2] Model: $MODEL RAM_MB: $TOTAL_RAM_MB"

if [ "$TOTAL_RAM_MB" -le 1024 ]; then
  ZRAM_PERCENT=60
elif [ "$TOTAL_RAM_MB" -le 4096 ]; then
  ZRAM_PERCENT=40
else
  ZRAM_PERCENT=30
fi

# 3) configure /etc/default/zramswap (backup then write)
ZRAM_DEFAULT="/etc/default/zramswap"
echo "[step 3] Configuring zramswap (ALGO=lz4 PERCENT=${ZRAM_PERCENT})"
backup_if_exists "$ZRAM_DEFAULT"
cat > "$ZRAM_DEFAULT" <<EOF
# Managed by pi_perf_hybrid installer
ALGO=lz4
PERCENT=${ZRAM_PERCENT}
PRIORITY=100
EOF

# enable/start zramswap if available
if systemctl list-unit-files | grep -q '^zramswap'; then
  systemctl enable --now zramswap || true
fi

# 4) create disk swap fallback
SWAPFILE="/swapfile"
DISK_SWAP_SIZE="1G"
echo "[step 4] Creating/ensuring disk swapfile at $SWAPFILE size $DISK_SWAP_SIZE"
if [ ! -f "$SWAPFILE" ]; then
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l $DISK_SWAP_SIZE "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=1024
  else
    dd if=/dev/zero of="$SWAPFILE" bs=1M count=1024 status=progress || true
  fi
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
fi

# ensure fstab contains swapfile entry (idempotent)
if ! grep -qF "$SWAPFILE" /etc/fstab 2>/dev/null; then
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
  echo "fstab:added_swapfile" >> "${STATE_DIR}/backups.txt"
fi

# activate swapfile at lower priority than zram
swapon -p 50 "$SWAPFILE" || true

# record swapfile UUID
SWAP_UUID="$(blkid -s UUID -o value "$SWAPFILE" 2>/dev/null || true)"

# 5) sysctl tuning
SYSCTL_FILE="/etc/sysctl.d/99-pi-perf-hybrid.conf"
echo "[step 5] Applying sysctl tuning"
backup_if_exists "$SYSCTL_FILE"
cat > "$SYSCTL_FILE" <<EOF
# pi perf hybrid defaults
vm.swappiness=60
vm.vfs_cache_pressure=50
EOF
sysctl --system >/dev/null || true

# 6) disable dphys-swapfile if present
if systemctl list-unit-files | grep -q '^dphys-swapfile'; then
  echo "[step 6] Disabling dphys-swapfile service"
  systemctl stop dphys-swapfile.service 2>/dev/null || true
  systemctl disable dphys-swapfile.service 2>/dev/null || true
fi

# 7) Install pi_perf_check.sh (uses jq for safe JSON)
CHECK_SCRIPT="/usr/local/bin/pi_perf_check.sh"
echo "[step 7] Installing performance checker -> $CHECK_SCRIPT"
backup_if_exists "$CHECK_SCRIPT"
cat > "$CHECK_SCRIPT" <<'EOSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
OUT_JSON="/var/tmp/pi_perf_report.json"
LOG="/var/log/pi_perf_check.log"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
KERNEL="$(uname -srmp)"
MODEL="$(cat /proc/device-tree/model 2>/dev/null | tr -d '\000' | tr -d '\r\n' || echo unknown)"
TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo || echo 0)
CPU_FREQS=$(for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do if [ -r "$f" ]; then cat "$f"; else echo unknown; fi; done 2>/dev/null)
ZRAM_RAW=$(command -v zramctl >/dev/null 2>&1 && (zramctl --json 2>/dev/null || zramctl 2>/dev/null) || "")
# swapon listing (portable)
SWAP_RAW=$(swapon --show NAME,TYPE,SIZE,USED,PRIO 2>/dev/null || swapon --show 2>/dev/null || "")
FREE_RAW="$(free -h 2>/dev/null || "")"
if command -v vcgencmd >/dev/null 2>&1; then
  TEMP="$(vcgencmd measure_temp 2>/dev/null || "n/a")"
  THROTTLED="$(vcgencmd get_throttled 2>/dev/null || "n/a")"
else
  TEMP="n/a"; THROTTLED="n/a"
fi
SYSBENCH_OUT="$(command -v sysbench >/dev/null 2>&1 && sysbench cpu --cpu-max-prime=20000 run 2>&1 || "sysbench_not_installed")"
# produce JSON with jq (safe escaping)
jq -n \
  --arg ts "$(timestamp)" \
  --arg host "$HOSTNAME" \
  --arg kernel "$KERNEL" \
  --arg model "$MODEL" \
  --arg ram "$TOTAL_RAM_MB" \
  --arg cpu "$CPU_FREQS" \
  --arg zram "$ZRAM_RAW" \
  --arg swap "$SWAP_RAW" \
  --arg free "$FREE_RAW" \
  --arg temp "$TEMP" \
  --arg throttled "$THROTTLED" \
  --arg sysbench "$SYSBENCH_OUT" \
  '{ timestamp:$ts, host:$host, kernel:$kernel, model:$model, total_ram_mb:($ram|tonumber), cpu_freqs:$cpu, zram_raw:$zram, swap_raw:$swap, free_raw:$free, temperature:$temp, throttled:$throttled, sysbench:$sysbench }' > "$OUT_JSON"
echo "Report written to $OUT_JSON"
EOSCRIPT
chmod +x "$CHECK_SCRIPT"

# create systemd oneshot service
SERVICE_UNIT="/etc/systemd/system/pi-perf-check.service"
echo "[step 7b] Installing systemd oneshot for check"
backup_if_exists "$SERVICE_UNIT"
cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=Pi Performance Check (one-shot)
After=network.target

[Service]
Type=oneshot
ExecStart=${CHECK_SCRIPT} --run
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now pi-perf-check.service || true

# 8) Install Flask API under /opt and start it (Option A)
API_DIR="/opt/pi_perf_api"
echo "[step 8] Installing Flask API into $API_DIR"
backup_if_exists "$API_DIR"
mkdir -p "$API_DIR"
python3 -m venv "$API_DIR/venv"
"$API_DIR/venv/bin/pip" install --upgrade pip setuptools wheel
"$API_DIR/venv/bin/pip" install flask

# write app
cat > "$API_DIR/pi_perf_api.py" <<'PYAPP'
#!/usr/bin/env python3
from flask import Flask, jsonify, send_file
import os, subprocess, time, fcntl
APP = Flask(__name__)
REPORT = "/var/tmp/pi_perf_report.json"
CHECK_SCRIPT = "/usr/local/bin/pi_perf_check.sh"
RATE_LIMIT_S = 5
REPORT_TTL = 300
LOCKFILE = "/var/lock/pi_perf_api.lock"
LAST_CALL = "/var/tmp/pi_perf_api_lastcall"
def lock(fn):
    os.makedirs("/var/lock", exist_ok=True)
    with open(LOCKFILE, "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        return fn()
def rate_limited():
    now = time.time()
    last = 0.0
    if os.path.exists(LAST_CALL):
        try:
            with open(LAST_CALL,"r") as fh:
                last = float(fh.read().strip() or "0")
        except:
            last = 0.0
    if now - last < RATE_LIMIT_S:
        return True, RATE_LIMIT_S - (now - last)
    with open(LAST_CALL,"w") as fh:
        fh.write(str(now))
    return False, 0
@APP.route("/perf")
def perf():
    def handler():
        limited, rem = rate_limited()
        if limited:
            return jsonify({"error":"rate_limited","retry_after_seconds": rem}), 429
        need_run = True
        if os.path.exists(REPORT):
            age = time.time() - os.path.getmtime(REPORT)
            if age < REPORT_TTL:
                need_run = False
        if need_run:
            try:
                subprocess.run([CHECK_SCRIPT, "--run"], check=True, timeout=120)
            except subprocess.CalledProcessError:
                return jsonify({"error":"check_failed"}), 500
            except subprocess.TimeoutExpired:
                return jsonify({"error":"check_timeout"}), 504
        if os.path.exists(REPORT):
            return send_file(REPORT, mimetype="application/json")
        return jsonify({"error":"no_report"}), 500
    return lock(handler)
@APP.route("/perf/raw")
def perf_raw():
    return perf()
if __name__ == "__main__":
    APP.run(host="0.0.0.0", port=8080)
PYAPP

chmod 750 "$API_DIR"
chmod +x "$API_DIR/pi_perf_api.py"

# systemd unit for API
API_SERVICE="/etc/systemd/system/pi-perf-api.service"
echo "[step 8b] Installing systemd unit for API"
backup_if_exists "$API_SERVICE"
cat > "$API_SERVICE" <<EOF
[Unit]
Description=Pi Performance API
After=network.target

[Service]
User=root
WorkingDirectory=${API_DIR}
ExecStart=${API_DIR}/venv/bin/python ${API_DIR}/pi_perf_api.py
Restart=on-failure
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pi-perf-api.service || true

# 9) Finalize & write state file (safe JSON without merges)
echo "[final] Writing state file to $STATE_FILE"
jq -n \
  --arg model "$MODEL" \
  --arg ram_mb "$TOTAL_RAM_MB" \
  --arg zram_percent "$ZRAM_PERCENT" \
  --arg swapfile "$SWAPFILE" \
  --arg swap_uuid "$SWAP_UUID" \
  --arg api_dir "$API_DIR" \
  --arg api_service "/etc/systemd/system/pi-perf-api.service" \
  '{ installed_at: now|strftime("%Y-%m-%dT%H:%M:%SZ"), model:$model, total_ram_mb:($ram_mb|tonumber), zramswap_percent:($zram_percent|tonumber), swapfile:$swapfile, swap_uuid:$swap_uuid, api_dir:$api_dir, api_service:$api_service }' > "$STATE_FILE"

echo "Installation complete. Log: $LOG"
echo "State saved to: $STATE_FILE"
echo "API: http://<pi-ip>:8080/perf (auto-started)"
exit 0
