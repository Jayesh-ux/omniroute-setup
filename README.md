# OmniRoute + OpenCode setup (free-tier faas-coding)

Reproduces the OmniRoute gateway + OpenCode integration exactly as configured on the original machine:

- **OmniRoute gateway** v3.8.49 on `http://localhost:20128` (OpenAI-compatible endpoint `/v1`)
- **Provider**: `opencode` ("OpenCode Free") — the single upstream that broadcasts every free `opencode/*` model
- **Combo** `free-coding` (priority strategy) over the live-verified free models
- **OpenCode** uses `omniroute/combo/free-coding` as its default model, with auto-fallback chains and per-model limits that a daily refresh keeps in sync.

No secrets are stored in this repo. Secrets live in `~/.omniroute/` on each machine and are created by `setup.sh`.

## What gets installed

| Component | Version | Install path |
|---|---|---|
| bun | 1.4.x | `~/.bun/bin/bun` |
| OmniRoute | 3.8.49 | `~/.bun/bin/omniroute` (bun global) |
| opencode CLI | 1.18.21 | npm global (`opencode`) |
| gateway data | — | `~/.omniroute/` (`storage.sqlite`, `.env`) |
| refresh script | — | `~/opencode-omniroute/daily-refresh.sh` |
| launch script | — | `~/start-opencode` |
| opencode config | — | `~/.config/opencode/opencode.json` |

## Setup on a new machine

```bash
git clone git@github.com:Jayesh-ux/omniroute-setup.git
cd omniroute-setup
./setup.sh
```

`setup.sh` is idempotent and safe to re-run. It:

1. Installs bun, `omniroute@3.8.49`, and `opencode-ai@1.18.21` if missing.
2. Creates `~/.omniroute/` and populates `.env` with a fresh `STORAGE_ENCRYPTION_KEY` plus a random dashboard password (`~/.omniroute-dashboard-password`).
3. Installs `daily-refresh.sh` → `~/opencode-omniroute/daily-refresh.sh` and `start-opencode` → `~/start-opencode`.
4. Installs `config/opencode.json.template` → `~/.config/opencode/opencode.json`.
5. Appends `OMNIROUTE_API_KEY=local-omniroute` and bun PATH to `~/.bashrc`.

### One-time: connect the provider (dashboard)

Credential step — the only manual thing (the API key is never stored in this repo):

```bash
source ~/.bashrc
omniroute serve --no-open
```

Open `http://localhost:20128` in a browser, log in with the password printed by `setup.sh`, then **Providers → Add**:

- Type: `apikey`
- Provider ID: `opencode`
- Label: `OpenCode Free`
- API key: paste the same key used on the original machine
  (get it from the original machine's dashboard: Providers → OpenCode Free → show key; or `scp` the whole `~/.omniroute` dir over if you prefer a pixel-identical copy)

Request URL override: `https://opencode.com/v1` (whatever the original machine uses).

### First load of "all the models"

```bash
# one terminal — starts gateway (if down), live-tests every free opencode/* model,
# rebuilds the free-coding combo from verified models, syncs opencode.json
~/opencode-omniroute/daily-refresh.sh
```

After it finishes, the gateway catalog, the `free-coding` combo, and `~/.config/opencode/opencode.json` all contain every verified model.

## Daily use — two terminals

### Terminal 1 — gateway + model refresh

```bash
~/start-opencode            # starts gateway if down → refreshes models if stale (<6h) → then opens opencode
```

or, to keep the gateway-only side running:

```bash
omniroute serve --no-open   # gateway on :20128
~/opencode-omniroute/daily-refresh.sh   # refresh models/combo whenever you want
```

### Terminal 2 — code with OpenCode via OmniRoute

```bash
opencode                        # default model = omniroute/combo/free-coding
opencode --model omniroute/opencode/big-pickle      # pin the top model
opencode --model omniroute/combo/free-coding         # full priority chain
```

Available models on the original machine (after refresh):

| Model | Context | Output |
|---|---|---|
| `opencode/big-pickle` | 200k | 32k |
| `opencode/nemotron-3-ultra-free` | 200k | 32k |
| `opencode/nemotron-3.5-lightning-free` | 200k | 32k |
| `opencode/laguna-s-2.1-free` | 1M | 128k |
| `opencode/mimo-v2.5-free` | 1M | 128k |

Chain used by `combo/free-coding` (priority order): `big-pickle → nemotron-3-ultra-free → nemotron-3.5-lightning-free → laguna-s-2.1-free → mimo-v2.5-free`.

The set changes as upstream availability shifts — that is what `daily-refresh.sh` handles automatically.

## Scripts

- `setup.sh` — one-shot installer for a fresh machine (idempotent).
- `start-opencode.sh` — gateway health-check → (re)start → stale-model refresh → launch opencode. Installed as `~/start-opencode`.
- `daily-refresh.sh` — login to gateway, live-test every free candidate, rebuild `free-coding` combo, sync `opencode.json` limits. Installed as `~/opencode-omniroute/daily-refresh.sh`.
- `config/opencode.json.template` — OpenCode provider config template (no secrets; models get expanded by `daily-refresh.sh`).

## Security notes

- `~/.omniroute/storage.sqlite` holds the provider API key **encrypted** with `STORAGE_ENCRYPTION_KEY` from `~/.omniroute/.env`. Never push either file — that leaks the credential.
- `.env`, `*.sqlite`, logs, runtime state, and the dashboard password are git-ignored here.
- To clone this to another machine you only need the plain API key (one paste) — not the whole encrypted store.

## Troubleshooting

- Gateway down → `curl -sf http://localhost:20128/` empty? Run `omniroute serve --no-open` and watch `/tmp/opencode/omniroute.log`. Logs also at `~/.omniroute/logs/application/`.
- "Model not found" in opencode → re-run `daily-refresh.sh`; the combo is rebuilt from live-verified models only, and sets `opencode.json`'s model list accordingly.