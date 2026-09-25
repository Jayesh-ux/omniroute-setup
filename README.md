# OmniRoute + OpenCode (free-tier models, auto-switching)

One-click reproducible build of the OmniRoute gateway + OpenCode integration that runs on the
original machine. It gives OpenCode **every available free model in one provider**, routed through
a priority combo with automatic per-request fallback, plus a refresh script that re-verifies and
re-ranks the model set daily.

- **OmniRoute gateway** v3.8.49 on `http://localhost:20128` (OpenAI-compatible `/v1`)
- **Single upstream provider**: `opencode` → OpenCode's public free tier at `https://opencode.ai/zen/v1`
- **Combo** `free-coding` (priority strategy) over the live-verified free models
- **OpenCode** defaults to `omniroute/combo/free-coding`; per-model limits are re-synced on every refresh

No secrets live in this repo. Machine-local secrets are created by `setup.sh`.

---

## The "no API key" thing — explained (read this first)

There are **two key layers**, and neither is a paid credential:

| Layer | Key | Why |
|---|---|---|
| OpenCode CLI → OmniRoute gateway | `local-omniroute` (fake) | The gateway is a local OpenAI-compatible proxy; it accepts `{env:OMNIROUTE_API_KEY}` from `opencode.json` and doesn't verify it |
| OmniRoute gateway → OpenCode free tier | `temp` (dummy) | The upstream `https://opencode.ai/zen/v1` is **public**: "No signup or API key needed. Rate limits apply." The `temp` value is just a placeholder the gateway requires to fill `Authorization`, the endpoint ignores it (`/v1/models` returns HTTP 200 with no auth at all) |

So nobody needs a real API key to *set up* the gateway. The `temp` key is not a secret and can be
shared freely across machines.

> **Current upstream status (Sep 2026):** the models endpoint is public, but live **chat** calls
> from a dummy `temp` key are currently rejected with
> `403 FreeTierError: OpenCode's free tier can only be used from within OpenCode`
> (`insufficient_quota`). This is upstream rate-limiting/policy, not a bug in this repo — it affects
> the original machine's gateway identically. If `daily-refresh.sh` reports `FATAL: fewer than 2
> models verified`, retry later, or paste a real OpenCode account key (from `opencode auth login`)
> into the provider on all machines. The combo is left untouched when a refresh fails, so a healthy
> chain is never clobbered by a bad upstream day.

---

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

`setup.sh` is idempotent and safe to re-run:

1. Installs bun, `omniroute@3.8.49`, `opencode-ai@1.18.21` if missing.
2. Creates `~/.omniroute/`, writes `.env` with a fresh `STORAGE_ENCRYPTION_KEY` and a random dashboard password (`~/.omniroute-dashboard-password`).
3. Installs `daily-refresh.sh` and `~/start-opencode`.
4. Installs `config/opencode.json.template` → `~/.config/opencode/opencode.json`.
5. Appends `OMNIROUTE_API_KEY=local-omniroute` + bun PATH to `~/.bashrc`.

### One-time: connect the provider (dashboard)

```bash
source ~/.bashrc
omniroute serve --no-open
```

Open `http://localhost:20128`, log in with the password `setup.sh` printed, then **Providers → Add**
with these **exact** values (mismatches here are the #1 cause of "all model tests fail"):

| Field | Value |
|---|---|
| Type | `apikey` |
| **Provider ID** | `opencode` ← must be exactly this; the gateway serves models as `opencode/<name>` |
| Label | `OpenCode Free` |
| API key | `temp` (the public free-tier placeholder — any non-empty string works for catalog sync) |
| **Request URL override** | `https://opencode.ai/zen/v1` ← NOT `opencode.com/v1` |

If you'd rather have a pixel-identical copy, `scp -r ~/.omniroute user@new:~/.omniroute` (brings the
provider, combo, dashboard password, and encryption key along).

### First load of the models

```bash
~/opencode-omniroute/daily-refresh.sh
```

Live-tests every free `opencode/*` candidate, rebuilds `free-coding` from the PASSes, syncs `opencode.json`.

---

## Which models work + auto-switching

### Verified set (last healthy refresh)

| Priority | Model id | Context | Output |
|---|---|---|---|
| 1 | `opencode/big-pickle` | 200k | 32k |
| 2 | `opencode/nemotron-3-ultra-free` | 200k | 32k |
| 3 | `opencode/nemotron-3.5-lightning-free` | 200k | 32k |
| 4 | `opencode/laguna-s-2.1-free` | 1M | 128k |
| 5 | `opencode/mimo-v2.5-free` | 1M | 128k |

Other free candidates the refresh watches but currently drops (often FAIL at test time):
`deepseek-v4-flash-free`, `hy3-free`, `x-preview-f-free`, `muse-spark-1.2-contributor-free`,
`jev-1.13-free`, `space-bunny-free`, `mimo-v2.6-flash-free` — they only enter the chain if a
refresh proves they pass.

### How automatic switching works

**Per-request fallback (the combo).** `free-coding` uses `strategy: priority` over the 5 targets
above in order. When OpenCode asks for `omniroute/combo/free-coding`:

1. Gateway routes to **big-pickle** (rank 100).
2. On error / rate-limit / timeout / empty response for that target, it **fails over to the next
   model in the chain** (nemotron-3-ultra-free → nemotron-3.5-lightning-free → laguna-s-2.1-free →
   mimo-v2.5-free), returning the first valid completion.
3. You are aware of this only via gateway logs (`~/.omniroute/logs/`); OpenCode just gets a reply.

**Daily re-ranking (the refresh).** Each run:
1. Pulls the live model catalog via the gateway.
2. Tests every free candidate + `big-pickle` with a tiny `"Reply with exactly: OK"` call.
3. Keeps only PASSes, sorts by the strength `RANK` map (`big-pickle`=100, `nemotron-3-ultra-free`=90,
   `nemotron-3.5-lightning-free`=80, `hy3-free`=70, `laguna-s-2.1-free`=60, `x-preview-f-free`=55,
   `mimo-v2.5-free`=50, then context size), rebuilds the priority combo, and rewrites
   `opencode.json` limits + `model`/`small_model`.
4. If fewer than 2 models verify, it aborts and **keeps the existing combo untouched**.

That's why the model set "changes by itself": it always mirrors what is actually passing upstream.

### Pinning a model (no fallback)

```bash
opencode --model omniroute/opencode/big-pickle
opencode --model omniroute/combo/free-coding   # full priority chain (default)
```

---

## Daily use — two terminal windows

### Terminal 1 — gateway + refresh

```bash
~/start-opencode
# starts gateway if down → refreshes models if stale (<6h) → launches opencode
```

or keep the gateway running separately:

```bash
omniroute serve --no-open
~/opencode-omniroute/daily-refresh.sh   # anytime you want a model re-check
```

### Terminal 2 — code with OpenCode via OmniRoute

```bash
opencode   # default: omniroute/combo/free-coding
```

---

## Scripts

- `setup.sh` — idempotent fresh-machine installer.
- `start-opencode.sh` — gateway health-check → (re)start → stale-model refresh → launch opencode.
- `daily-refresh.sh` — login to gateway, test candidates, rebuild `free-coding` combo, sync `opencode.json`.
- `config/opencode.json.template` — OpenCode provider config (no secrets; models expanded by refresh).

## Security notes

- `~/.omniroute/storage.sqlite` stores the provider key **encrypted** with `STORAGE_ENCRYPTION_KEY`
  from `~/.omniroute/.env`. Never push either file — in this setup the value is just `temp`, but the
  moment someone pastes a real account key there it becomes a genuine secret.
- `.env`, `*.sqlite`, logs, runtime state, and dashboard password are git-ignored in this repo.
- The dashboard password is written to stdout only once, at `setup.sh` time (`~/.omniroute-dashboard-password`).

## Troubleshooting

- **All model tests FAIL on a fresh install** → check the provider values in the dashboard: Provider
  ID `opencode`, API key `temp`, Request URL override `https://opencode.ai/zen/v1` (not `opencode.com`).
- **`403 FreeTierError … only be used from within OpenCode` / `insufficient_quota`** → upstream
  free-tier rate-limit/policy. Happens on the original machine's gateway too. Wait and retry, or set a
  real OpenCode account key (`opencode auth login`) as the provider key on every machine.
- **Gateway down** → `curl -sf http://localhost:20128/` empty? Run `omniroute serve --no-open`; logs
  at `/tmp/opencode/omniroute.log` and `~/.omniroute/logs/application/`.
- **"Model not found" in opencode** → re-run `daily-refresh.sh`; it rebuilds the list from verified models only.
- **Dashboard login lost** → reset with `omniroute reset-password` or restore `~/.omniroute-dashboard-password`.