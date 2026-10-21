#!/usr/bin/env bash
# Vast.ai idle-instance watchdog.
# Runs on the instance itself, samples GPU + container CPU utilization, and posts
# to a Discord webhook when the instance has been idle for too long.
#
# Usage:
#   DISCORD_WEBHOOK_URL=... bash watchdog.sh          # run the watchdog loop
#   DISCORD_WEBHOOK_URL=... bash watchdog.sh --test   # send a test message and exit
#   bash watchdog.sh --sample                         # print one GPU/CPU sample and exit

set -u

# ---------- config ----------
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DISCORD_USER_ID="${DISCORD_USER_ID:-}"
IDLE_GPU_PCT="${IDLE_GPU_PCT:-5}"
IDLE_CPU_PCT="${IDLE_CPU_PCT:-10}"
IDLE_MINUTES="${IDLE_MINUTES:-60}"
REMIND_MINUTES="${REMIND_MINUTES:-30}"
CHECK_INTERVAL_SEC="${CHECK_INTERVAL_SEC:-60}"
INSTANCE_LABEL="${INSTANCE_LABEL:-${VAST_CONTAINERLABEL:-${CONTAINER_ID:-$(hostname)}}}"
NOTIFY_ON_START="${NOTIFY_ON_START:-1}"
NOTIFY_ON_RESUME="${NOTIFY_ON_RESUME:-0}"
LOG_FILE="${LOG_FILE:-/root/watchdog.log}"   # "-" logs to stdout
LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"
LOCK_FILE="${LOCK_FILE:-/tmp/vast_watchdog.lock}"

# ---------- logging ----------
log() {
  local line
  line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  if [ "$LOG_FILE" = "-" ]; then
    echo "$line"
    return
  fi
  if [ -f "$LOG_FILE" ] && [ "$(wc -c <"$LOG_FILE")" -gt "$LOG_MAX_BYTES" ]; then
    : >"$LOG_FILE"
  fi
  echo "$line" >>"$LOG_FILE"
}

# ---------- helpers ----------
now_ns() { date +%s%N; }

# Float comparison: lt A B -> success if A < B
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }

fmt_dur() {
  local s=$1
  printf '%dh %02dm' $((s / 3600)) $(((s % 3600) / 60))
}

json_escape() {
  printf '%s' "$1" | awk 'BEGIN { ORS = "" } {
    gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "")
    if (NR > 1) print "\\n"
    print
  }'
}

# ---------- GPU ----------
GPU_OK=1
GPU_NAMES="none"

gpu_init() {
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    GPU_NAMES=$(nvidia-smi --query-gpu=name --format=csv,noheader | sort | uniq -c |
      awk '{ c = $1; $1 = ""; sub(/^ /, ""); printf "%s%dx %s", (NR > 1 ? ", " : ""), c, $0 }')
  else
    GPU_OK=0
  fi
}

# Max utilization across all GPUs; 0 if nvidia-smi unavailable.
gpu_util() {
  local v
  if [ "$GPU_OK" = 1 ]; then
    v=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null |
      tr -d ' ' | grep -E '^[0-9]+$' | sort -n | tail -1)
  fi
  echo "${v:-0}"
}

# ---------- CPU ----------
# Vast instances are containers on shared hosts: /proc/stat shows the whole host,
# so prefer the container's cgroup CPU accounting.
CPU_MODE=""
CPU_COUNT=""

cpu_init() {
  local quota period
  if [ -f /sys/fs/cgroup/cpu.stat ] && grep -q '^usage_usec' /sys/fs/cgroup/cpu.stat; then
    CPU_MODE="cgroup2"
    if [ -f /sys/fs/cgroup/cpu.max ]; then
      read -r quota period </sys/fs/cgroup/cpu.max
      if [ "$quota" != "max" ]; then
        CPU_COUNT=$(awk -v q="$quota" -v p="$period" 'BEGIN { print q / p }')
      fi
    fi
  elif [ -f /sys/fs/cgroup/cpuacct/cpuacct.usage ] || [ -f /sys/fs/cgroup/cpu,cpuacct/cpuacct.usage ]; then
    CPU_MODE="cgroup1"
    local dir=/sys/fs/cgroup/cpu
    [ -f "$dir/cpu.cfs_quota_us" ] || dir=/sys/fs/cgroup/cpu,cpuacct
    if [ -f "$dir/cpu.cfs_quota_us" ]; then
      quota=$(cat "$dir/cpu.cfs_quota_us")
      period=$(cat "$dir/cpu.cfs_period_us")
      if [ "$quota" -gt 0 ] 2>/dev/null; then
        CPU_COUNT=$(awk -v q="$quota" -v p="$period" 'BEGIN { print q / p }')
      fi
    fi
  else
    CPU_MODE="procstat"
  fi
  # No quota set: fall back to the CPUs this process may run on (respects cpusets).
  if [ -z "$CPU_COUNT" ]; then
    CPU_COUNT=$(nproc 2>/dev/null || echo 1)
  fi
}

# Prints "<busy_ns> <wall_ns>" counters; utilization is computed from deltas.
cpu_counters() {
  case "$CPU_MODE" in
    cgroup2)
      awk -v t="$(now_ns)" '$1 == "usage_usec" { printf "%.0f %s\n", $2 * 1000, t }' /sys/fs/cgroup/cpu.stat
      ;;
    cgroup1)
      local f=/sys/fs/cgroup/cpuacct/cpuacct.usage
      [ -f "$f" ] || f=/sys/fs/cgroup/cpu,cpuacct/cpuacct.usage
      echo "$(cat "$f") $(now_ns)"
      ;;
    procstat)
      # busy jiffies / total jiffies, already summed over all CPUs
      awk '$1 == "cpu" { idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i; print total - idle, total; exit }' /proc/stat
      ;;
  esac
}

# cpu_pct "<prev counters>" "<cur counters>"
cpu_pct() {
  awk -v p="$1" -v c="$2" -v n="$CPU_COUNT" -v mode="$CPU_MODE" 'BEGIN {
    split(p, a, " "); split(c, b, " ")
    db = b[1] - a[1]; dw = b[2] - a[2]
    if (dw <= 0) { print 0; exit }
    pct = (mode == "procstat") ? db / dw * 100 : db / (dw * n) * 100
    if (pct < 0) pct = 0
    printf "%.1f\n", pct
  }'
}

# ---------- Discord ----------
discord_send() {
  local payload=$1 attempt code body wait
  local resp
  resp=$(mktemp)
  for attempt in 1 2 3 4; do
    code=$(curl -sS -o "$resp" -w '%{http_code}' --max-time 20 \
      -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" 2>/dev/null)
    case "$code" in
      2??) rm -f "$resp"; return 0 ;;
      429)
        body=$(cat "$resp")
        wait=$(printf '%s' "$body" | grep -oE '"retry_after": *[0-9.]+' | grep -oE '[0-9.]+$')
        wait=$(awk -v w="${wait:-5}" 'BEGIN { printf "%d", w + 1 }')
        log "discord rate limited, retrying in ${wait}s"
        sleep "$wait"
        ;;
      4??)
        log "discord rejected message (HTTP $code): $(head -c 300 "$resp")"
        rm -f "$resp"
        return 1
        ;;
      *)
        wait=$((2 ** attempt))
        log "discord send failed (HTTP ${code:-000}), retry $attempt in ${wait}s"
        sleep "$wait"
        ;;
    esac
  done
  rm -f "$resp"
  log "discord send gave up after retries"
  return 1
}

# notify <title> <color> <description> [field_name field_value ...]
notify() {
  local title=$1 color=$2 desc=$3
  shift 3
  local fields="" sep="" content=""
  while [ $# -ge 2 ]; do
    fields="$fields$sep{\"name\":\"$(json_escape "$1")\",\"value\":\"$(json_escape "$2")\",\"inline\":true}"
    sep=","
    shift 2
  done
  [ -n "$DISCORD_USER_ID" ] && content="<@$DISCORD_USER_ID>"
  local payload
  payload=$(printf '{"username":"Vast Watchdog","content":"%s","embeds":[{"title":"%s","description":"%s","color":%d,"fields":[%s],"timestamp":"%s"}]}' \
    "$(json_escape "$content")" "$(json_escape "$title")" "$(json_escape "$desc")" "$color" "$fields" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
  discord_send "$payload"
}

COLOR_RED=15548997
COLOR_GREEN=5763719
COLOR_BLUE=3447003

# ---------- main ----------
main_loop() {
  local idle_since=0 last_alert=0 alerted=0
  local prev cur gpu cpu now idle_for

  log "watchdog starting: label=$INSTANCE_LABEL gpu=$GPU_NAMES cpu_mode=$CPU_MODE cpus=$CPU_COUNT" \
    "thresholds: gpu<$IDLE_GPU_PCT% cpu<$IDLE_CPU_PCT% for ${IDLE_MINUTES}m, remind every ${REMIND_MINUTES}m"

  if [ "$NOTIFY_ON_START" = 1 ]; then
    local warn=""
    [ "$GPU_OK" = 0 ] && warn=$'\n⚠️ nvidia-smi unavailable: GPU treated as idle.'
    [ "$CPU_MODE" = "procstat" ] && warn="$warn"$'\n⚠️ No cgroup CPU stats: CPU % is host-wide.'
    notify "🟦 Watchdog started" "$COLOR_BLUE" \
      "Alerting after ${IDLE_MINUTES}m idle (GPU < ${IDLE_GPU_PCT}%, CPU < ${IDLE_CPU_PCT}%).$warn" \
      "Instance" "$INSTANCE_LABEL" "GPU" "$GPU_NAMES"
  fi

  prev=$(cpu_counters)
  while true; do
    sleep "$CHECK_INTERVAL_SEC"
    cur=$(cpu_counters)
    cpu=$(cpu_pct "$prev" "$cur")
    prev=$cur
    gpu=$(gpu_util)
    now=$(date +%s)

    if lt "$gpu" "$IDLE_GPU_PCT" && lt "$cpu" "$IDLE_CPU_PCT"; then
      [ "$idle_since" = 0 ] && idle_since=$now
      idle_for=$((now - idle_since))
      if [ "$idle_for" -ge $((IDLE_MINUTES * 60)) ] &&
        { [ "$alerted" = 0 ] || [ $((now - last_alert)) -ge $((REMIND_MINUTES * 60)) ]; }; then
        log "ALERT idle for $(fmt_dur "$idle_for") (gpu=$gpu% cpu=$cpu%)"
        notify "⚠️ Vast instance idle" "$COLOR_RED" \
          "Idle for **$(fmt_dur "$idle_for")** — stop or destroy it if you're done." \
          "Instance" "$INSTANCE_LABEL" "Idle for" "$(fmt_dur "$idle_for")" \
          "GPU util" "${gpu}%" "CPU util" "${cpu}%" "GPU" "$GPU_NAMES"
        alerted=1
        last_alert=$now
      fi
    else
      if [ "$alerted" = 1 ]; then
        log "busy again after alert (gpu=$gpu% cpu=$cpu%)"
        if [ "$NOTIFY_ON_RESUME" = 1 ]; then
          notify "✅ Vast instance busy again" "$COLOR_GREEN" "Activity resumed." \
            "Instance" "$INSTANCE_LABEL" "GPU util" "${gpu}%" "CPU util" "${cpu}%"
        fi
      fi
      idle_since=0
      alerted=0
    fi
  done
}

gpu_init
cpu_init

case "${1:-}" in
  --sample)
    LOG_FILE="-"
    prev=$(cpu_counters)
    sleep 2
    cpu=$(cpu_pct "$prev" "$(cpu_counters)")
    echo "gpu=$(gpu_util)% cpu=$cpu% cpu_mode=$CPU_MODE cpus=$CPU_COUNT gpus=$GPU_NAMES"
    exit 0
    ;;
esac

if [ -z "$DISCORD_WEBHOOK_URL" ]; then
  echo "DISCORD_WEBHOOK_URL is not set" >&2
  exit 1
fi

case "${1:-}" in
  --test)
    LOG_FILE="-"
    if notify "🧪 Vast watchdog test" "$COLOR_BLUE" "If you see this, alerts work." \
      "Instance" "$INSTANCE_LABEL" "GPU" "$GPU_NAMES"; then
      echo "test message sent"
      exit 0
    fi
    exit 1
    ;;
esac

# Single instance: re-running the on-start script must not spawn duplicates.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "watchdog already running" >&2
    exit 0
  fi
else
  if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
    echo "watchdog already running" >&2
    exit 0
  fi
  echo $$ >"$LOCK_FILE"
fi

main_loop
