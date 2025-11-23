#!/usr/bin/env bash
# pi_perf_validate.sh
# Complete validation suite: JSON + human-readable output.
# Output: /var/tmp/pi_perf_validation_report.json and /var/tmp/pi_perf_validation_human.txt
#
# Usage: sudo bash pi_perf_validate.sh

set -euo pipefail
REPORT="/var/tmp/pi_perf_validation_report.json"
HUMAN="/var/tmp/pi_perf_validation_human.txt"
TMP_ALLOC="/var/tmp/pi_perf_validate.alloc"
IP="$(hostname -I | awk '{print $1}')"
API="http://${IP}:8080/perf"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0"
  exit 1
fi

echo "PI PERFORMANCE VALIDATION - $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "API endpoint: $API"

# Ensure jq present
if ! command -v jq >/dev/null 2>&1; then
  echo "[validator] jq missing: installing..."
  apt update -y
  apt install -y jq
fi

# 1) service & port check
API_SYSTEMD_STATUS=$(systemctl is-active pi-perf-api.service 2>/dev/null || echo "inactive")
PORT_LISTEN=$(ss -tulpn | grep -E ':(8080)\s' || true)

# 2) API call (measure latency)
API_OK=false; API_LAT_MS=0; API_RAW=""
START=$(date +%s%3N)
API_RAW=$(curl -s -m 8 "$API" || echo "")
END=$(date +%s%3N)
if [ -n "$API_RAW" ]; then API_OK=true; fi
API_LAT_MS=$((END - START))

# 3) rate limit test
RATE_LIMITED=false
# perform two quick calls - second should be rate-limited
curl -s -m 3 "$API" >/dev/null || true
RL_OUT=$(curl -s -m 3 "$API" || echo "")
if echo "$RL_OUT" | grep -qi "rate_limited"; then RATE_LIMITED=true; fi

# 4) CPU sysbench short tests
SINGLE=$(sysbench cpu --threads=1 --cpu-max-prime=20000 run 2>&1 || true)
MULTI=$(sysbench cpu --threads=$(nproc) --cpu-max-prime=20000 run 2>&1 || true)

# 5) zram + swap
ZRAM_RAW=$(zramctl 2>&1 || true)
# portable swapon info
SWAPINFO=$(swapon --show NAME,TYPE,SIZE,USED,PRIO 2>/dev/null || swapon --show 2>/dev/null || true)

# 6) temperature & throttling
if command -v vcgencmd >/dev/null 2>&1; then
  TEMP=$(vcgencmd measure_temp 2>/dev/null || "n/a")
  THROTTLED=$(vcgencmd get_throttled 2>/dev/null || "n/a")
else
  RAWTEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
  TEMP="$(awk "BEGIN {printf \"temp=%.1f'C\", $RAWTEMP/1000}")"
  THROTTLED="n/a"
fi

# 7) memory pressure: allocate safe half of MemAvailable
MEMFREE_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
ALLOC_MB=$(( (MEMFREE_KB/1024) / 2 ))
echo "Performing memory-pressure allocation of ${ALLOC_MB} MB (safe test)"
# prevent huge allocations if value is zero
if [ "$ALLOC_MB" -gt 0 ]; then
  dd if=/dev/zero of="$TMP_ALLOC" bs=1M count="$ALLOC_MB" status=none || true
  sync
  rm -f "$TMP_ALLOC"
fi
SWAP_USED_KB=$(awk '/SwapTotal/ {t=$2}/SwapFree/ {f=$2} END{print t-f}' /proc/meminfo || echo 0)

# 8) build JSON report (jq for safe escaping)
jq -n \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg api_status "$API_SYSTEMD_STATUS" \
  --argjson api_ok "$API_OK" \
  --argjson latency_ms "$API_LAT_MS" \
  --arg api_raw "$API_RAW" \
  --argjson rate_limited "$RATE_LIMITED" \
  --arg single "$SINGLE" \
  --arg multi "$MULTI" \
  --arg zram "$ZRAM_RAW" \
  --arg swapinfo "$SWAPINFO" \
  --arg temp "$TEMP" \
  --arg throttled "$THROTTLED" \
  --argjson swap_used_kb "$SWAP_USED_KB" \
  --arg port_listen "$PORT_LISTEN" \
  '{
    timestamp: $ts,
    api: { systemd_status: $api_status, ok: $api_ok, latency_ms: $latency_ms, rate_limited: $rate_limited, raw: $api_raw, port_listen: $port_listen },
    cpu: { single_core: $single, multi_core: $multi },
    thermal: { temperature: $temp, throttled: $throttled },
    memory: { zram: $zram, swapinfo: $swapinfo, swap_used_kb: $swap_used_kb }
  }' > "$REPORT"

# 9) create human-readable interpretation
{
  echo "PI PERFORMANCE VALIDATION - HUMAN SUMMARY"
  echo "Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo ""
  echo "API"
  echo " - systemd status: $API_SYSTEMD_STATUS"
  if [ "$API_OK" = "true" ]; then
    echo " - API responded OK (latency: ${API_LAT_MS} ms)"
  else
    echo " - API did NOT respond or returned empty. Check: sudo systemctl status pi-perf-api.service"
  fi
  if [ "$RATE_LIMITED" = "true" ]; then
    echo " - Rate limiter: working (second quick call returned rate_limited)"
  else
    echo " - Rate limiter: NOT observed (second call did not return rate_limited)"
  fi
  echo " - port listen info (ss):"
  printf "%s\n" "$PORT_LISTEN"
  echo ""
  echo "CPU (sysbench brief)"
  echo " - Single-core output:"
  echo "-----"
  echo "$SINGLE"
  echo "-----"
  echo " - Multi-core output:"
  echo "-----"
  echo "$MULTI"
  echo "-----"
  echo "Thermal & Throttling"
  echo " - Temperature: $TEMP"
  echo " - Throttled flags: $THROTTLED"
  if echo "$THROTTLED" | grep -q "0x0"; then
    echo " - No throttling detected."
  else
    echo " - Throttling/undervoltage flags present. Investigate power/temperature."
  fi
  echo ""
  echo "ZRAM & Swap"
  echo " - zramctl summary:"
  echo "-----"
  echo "$ZRAM_RAW"
  echo "-----"
  echo " - swap devices (NAME,TYPE,SIZE,USED,PRIO):"
  echo "-----"
  echo "$SWAPINFO"
  echo "-----"
  echo " - swap used under pressure (KB): $SWAP_USED_KB"
  if [ "$SWAP_USED_KB" -gt 0 ]; then
    echo " - Swap fallback: USED (good: fallback works when zram full)"
  else
    echo " - Swap fallback: NOT USED (normal if zram sufficient)"
  fi
  echo ""
  echo "OVERALL SUGGESTIONS"
  if [ "$API_OK" != "true" ]; then
    echo " - Fix: check API logs: sudo journalctl -u pi-perf-api.service -n 200 --no-pager"
  fi
  if ! echo "$THROTTLED" | grep -q "0x0"; then
    echo " - Fix: check power/voltage & cooling (throttled flags)"
  fi
} > "$HUMAN"

# 10) Print results
echo ""
echo "JSON report: $REPORT"
jq . "$REPORT" || true
echo ""
echo "Human summary: $HUMAN"
cat "$HUMAN"
echo ""
echo "Done."
