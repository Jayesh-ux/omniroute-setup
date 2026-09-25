#!/usr/bin/env bash
# Quick-start: revive OmniRoute -> refresh models -> launch OpenCode
# Usage: ~/start-opencode [opencode args...]
export HOME="${HOME:-$HOME}"
export PATH="$HOME/.bun/bin:$PATH"
export OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY:-local-omniroute}"
GW="http://localhost:20128"
PORT="20128"

NODE_BIN="${NODE_BIN:-$(command -v node || echo /usr/local/bin/node)}"
OMNI="$HOME/.bun/bin/omniroute"

# 1. gateway alive?
if ! curl -s -o /dev/null --max-time 3 "$GW/"; then
  echo "[start] starting gateway..."
  setsid nohup "$NODE_BIN" "$OMNI" serve --no-open --port "$PORT" >> /tmp/opencode/omniroute.log 2>&1 < /dev/null &
  disown
  for i in $(seq 1 12); do sleep 5; curl -s -o /dev/null --max-time 3 "$GW/" && break; done
  curl -s -o /dev/null --max-time 3 "$GW/" && echo "[start] gateway UP" || { echo "[start] gateway FAILED"; exit 1; }
fi

# 2. refresh models (skip if ran <6h ago)
LOG="$HOME/.omniroute/daily-refresh.log"
if [ -f "$LOG" ] && [ $(find "$LOG" -mmin -360 2>/dev/null | wc -l) -gt 0 ]; then
  echo "[start] models refreshed recently — skipping"
else
  echo "[start] refreshing models..."
  "$HOME/opencode-omniroute/daily-refresh.sh"
fi

# 3. launch opencode
echo "[start] launching opencode (default: combo/free-coding)"
exec opencode "$@"