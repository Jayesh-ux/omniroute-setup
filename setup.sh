#!/usr/bin/env bash
# Idempotent bootstrap for a fresh OmniRoute + OpenCode build.
# Usage: ./setup.sh   (run as the user who will run opencode, HOME based)
set -euo pipefail

OMNI_VERSION="3.8.49"
OPENCODE_VERSION="1.18.21"
GATEWAY_PORT="${GATEWAY_PORT:-20128}"

log(){ printf '[setup] %s\n' "$*"; }

command -v node >/dev/null 2>&1 && NODE_BIN="$(command -v node)" || {
  log "node not found in PATH - this machine's build uses node 22 (see /opt/node22/bin or /usr/local/bin)"
}

# 1. bun (if missing)
if [ ! -x "$HOME/.bun/bin/bun" ]; then
  log "installing bun..."
  curl -fsSL https://bun.sh/install | bash
else
  log "bun already present"
fi
export BUN_INSTALL="$HOME/.bun"
export PATH="$HOME/.bun/bin:$PATH"

# 2. omniroute (bun global, pinned to the version that matches the original machine)
if ! omniroute --version >/dev/null 2>&1 || [ "$(omniroute --version)" != "$OMNI_VERSION" ]; then
  log "installing omniroute@$OMNI_VERSION..."
  bun add -g omniroute@"$OMNI_VERSION"
else
  log "omniroute@$OMNI_VERSION present"
fi

# 3. opencode CLI (npm global, pinned)
if ! command -v opencode >/dev/null 2>&1 || [ "$(opencode --version 2>/dev/null || true)" != "$OPENCODE_VERSION" ]; then
  log "installing opencode-ai@$OPENCODE_VERSION..."
  npm install -g opencode-ai@"$OPENCODE_VERSION"
else
  log "opencode@$OPENCODE_VERSION present"
fi

# 4. gateway data dir
DATA_DIR="$HOME/.omniroute"
mkdir -p "$DATA_DIR"/{call_logs,db_backups,logs,runtime,server}
log "data dir ready: $DATA_DIR"

# 5. storage encryption key (only generated once; required to persist the provider key encrypted)
ENV_FILE="$DATA_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  log ".env exists - keeping existing STORAGE_ENCRYPTION_KEY"
else
  KEY="$(openssl rand -hex 32 2>/dev/null || true)"
  [ -n "$KEY" ] || KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf 'STORAGE_ENCRYPTION_KEY=%s\n' "$KEY" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log "wrote $ENV_FILE (fresh STORAGE_ENCRYPTION_KEY)"
fi

# 6. dashboard password
PW_FILE="$HOME/.omniroute-dashboard-password"
if [ -f "$PW_FILE" ]; then
  log "dashboard password already set"
else
  PW="$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' | head -c 16 || true)"
  [ -n "$PW" ] || PW="omniroute-$(date +%s)"
  printf '%s\n' "$PW" > "$PW_FILE"
  chmod 600 "$PW_FILE"
  log "dashboard password -> $PW_FILE  (value: $PW — save it)"
fi

# 7. install scripts into their canonical locations
SRC="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/opencode-omniroute"
install -m 0755 "$SRC/daily-refresh.sh" "$HOME/opencode-omniroute/daily-refresh.sh"
install -m 0755 "$SRC/start-opencode.sh" "$HOME/start-opencode"
log "installed daily-refresh.sh + ~/start-opencode"

# 8. opencode config
mkdir -p "$HOME/.config/opencode"
install -m 0644 "$SRC/config/opencode.json.template" "$HOME/.config/opencode/opencode.json"
log "installed ~/.config/opencode/opencode.json"

# 9. env exports for opencode -> gateway
BASHRC="$HOME/.bashrc"
need_bashrc=0
grep -q 'export OMNIROUTE_API_KEY=' "$BASHRC" 2>/dev/null || { printf '\nexport OMNIROUTE_API_KEY="local-omniroute"\n' >> "$BASHRC"; need_bashrc=1; }
grep -q 'BUN_INSTALL' "$BASHRC" 2>/dev/null || {
  printf 'export BUN_INSTALL="$HOME/.bun"\nexport PATH="$BUN_INSTALL/bin:$PATH"\n' >> "$BASHRC"
  need_bashrc=1
}
[ "$need_bashrc" = "1" ] && log "appended env exports to ~/.bashrc (re-export for this shell: source ~/.bashrc)" \
                        || log "~/.bashrc already configured"

log "done. Next steps:"
log "  1) source ~/.bashrc"
log "  2) omniroute serve --no-open   (gateway on :$GATEWAY_PORT)"
log "  3) browser -> http://localhost:$GATEWAY_PORT -> log in with the dashboard password"
log "  4) Providers -> Add:  Provider ID 'opencode' / label 'OpenCode Free' / apikey"
log "     API key: temp   |   Request URL override: https://opencode.ai/zen/v1"
log "  5) ~/opencode-omniroute/daily-refresh.sh   (loads all models + combo)"
log "  6) opencode   (default model: omniroute/combo/free-coding)"