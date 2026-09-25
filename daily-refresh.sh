#!/usr/bin/env bash
# Daily OmniRoute free-model refresh:
#   1. Ensure gateway is running (restart if dead)
#   2. Live-test every free-tier candidate through the gateway
#   3. Rebuild the "free-coding" fallback combo from verified models only
#   4. Sync ~/.config/opencode/opencode.json model list + limits
# Log: ~/.omniroute/daily-refresh.log
set -u
export HOME="${HOME:-$(eval echo ~)}"
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

NODE_BIN="${NODE_BIN:-$(command -v node || echo /usr/local/bin/node)}"
OMNI="${OMNI:-$HOME/.bun/bin/omniroute}"
GW="${GATEWAY_URL:-http://localhost:20128}"
PORT="${GATEWAY_PORT:-20128}"
PW_FILE="$HOME/.omniroute-dashboard-password"
OCFG="$HOME/.config/opencode/opencode.json"
LOG="$HOME/.omniroute/daily-refresh.log"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# --- 1. gateway health / revival -------------------------------------------
if ! curl -s -o /dev/null --max-time 5 "$GW/"; then
  log "gateway down - starting"
  pkill -f "[o]mniroute serve" 2>/dev/null
  pkill -f "[o]mniroute restart" 2>/dev/null
  mkdir -p /tmp/opencode
  setsid nohup "$NODE_BIN" "$OMNI" serve --no-open --port "$PORT" >> /tmp/opencode/omniroute.log 2>&1 < /dev/null &
  disown
  up=0
  for i in $(seq 1 30); do
    sleep 5
    if curl -s -o /dev/null --max-time 3 "$GW/"; then up=1; break; fi
  done
  [ "$up" = "1" ] && log "gateway revived after ~$((i*5))s" || {
    log "WARNING: setsid start slow - trying direct start"
    "$NODE_BIN" "$OMNI" serve --no-open --port "$PORT" &
    sleep 60
    if curl -s -o /dev/null --max-time 5 "$GW/"; then log "gateway started via direct"; else log "FATAL: gateway failed to start"; exit 1; fi
  }
fi

# --- 2+3+4. test candidates, rebuild combo, sync config ----------------------
python3 - "$GW" "$PW_FILE" "$OCFG" <<'PY' | tee -a "$LOG"
import json,sys,urllib.request,time,http.cookiejar
gw,pw_file,ocfg=sys.argv[1],sys.argv[2],sys.argv[3]

cj=http.cookiejar.CookieJar()
opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
req=urllib.request.Request(gw+"/api/auth/login",method="POST",
    data=json.dumps({"password":open(pw_file).read().strip()}).encode(),
    headers={"Content-Type":"application/json"})
opener.open(req,timeout=15)

def api(path,method="GET",body=None):
    req=urllib.request.Request(gw+path,method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Content-Type":"application/json"})
    try: return json.load(opener.open(req,timeout=30))
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read())
        except: return {}

# strength ranking (higher = earlier in chain); unknown verified models append by context size
RANK={"opencode/big-pickle":100,"opencode/nemotron-3-ultra-free":90,"opencode/nemotron-3.5-lightning-free":80,
      "opencode/hy3-free":70,"opencode/laguna-s-2.1-free":60,"opencode/x-preview-f-free":55,
      "opencode/mimo-v2.5-free":50,
      "no-think/oc/nemotron-3-ultra-free":45,"no-think/oc/hy3-free":44,
      "oc/nemotron-3-ultra-free":43,"oc/hy3-free":42}

cat={m["id"]:m for m in json.load(urllib.request.urlopen(gw+"/v1/models",timeout=20))["data"]}
# primary opencode/* + oc/* alternate paths + no-think/ fast variants
candidates=sorted({i for i in cat if i.startswith("opencode/") and ("free" in i or i=="opencode/big-pickle")})
candidates+=["no-think/oc/nemotron-3-ultra-free","no-think/oc/hy3-free",
             "oc/nemotron-3-ultra-free","oc/hy3-free"]
candidates=list(dict.fromkeys(candidates))  # dedupe preserving order
print(f"[refresh] catalog has {len(cat)} models; testing {len(candidates)} free candidates")

verified=[]
for attempt in (1,2):
    for m in candidates:
        if m in verified: continue
        body=json.dumps({"model":m,"stream":False,"max_tokens":50,
            "messages":[{"role":"user","content":"Reply with exactly: OK"}]}).encode()
        req=urllib.request.Request(gw+"/v1/chat/completions",data=body,
            headers={"Content-Type":"application/json","User-Agent":"opencode/1.18.21"})
        ok=False
        try:
            r=json.load(urllib.request.urlopen(req,timeout=60)); ok=bool(r.get("choices"))
        except Exception: pass
        print(f"[refresh]   {m}: {'PASS' if ok else 'FAIL'}{'' if ok else f' (attempt {attempt})'}")
        if ok: verified.append(m)
        time.sleep(8)
    if len(verified)>=2 or attempt==2: break
    print("[refresh]   retrying failures once after cooldown")
    time.sleep(45)

if len(verified)<2:
    print("[refresh] FATAL: fewer than 2 models verified; keeping existing combo untouched"); sys.exit(0)

def _ctx(mid):
    lookup=mid
    if mid.startswith("no-think/"):
        base=mid.split("/")[-1]; lookup=f"opencode/{base}" if f"opencode/{base}" in cat else f"oc/{base}"
    return cat.get(lookup,{}).get("context_length") or 0
verified.sort(key=lambda x:(-RANK.get(x,10),-_ctx(x)))
print(f"[refresh] chain: {' > '.join(verified)}")

for c in api("/api/combos").get("combos",[]):
    if c["name"]=="free-coding": api(f"/api/combos/{c['id']}","DELETE")
r=api("/api/combos","POST",{"name":"free-coding","model":verified[0],"strategy":"priority","models":verified})
print(f"[refresh] combo rebuilt with {len(r.get('models',[]))} targets")

cfg=json.load(open(ocfg))
cfg.setdefault("provider",{})["omniroute"]={"name":"OmniRoute","npm":"@ai-sdk/openai-compatible",
    "options":{"baseURL":"http://localhost:20128/v1","apiKey":"{env:OMNIROUTE_API_KEY}"},
    "models":{"combo/free-coding":{"limit":{"context":200000,"output":32768},"tool_call":True,
        "description":"AUTO-FALLBACK (%d verified): %s"%(len(verified)," > ".join(i.split("/",1)[1] for i in verified))}}}
for mid in verified:
    # look up real limits: strip no-think/ and oc/ prefixes to find base model
    lookup=mid
    if mid.startswith("no-think/"):
        base=mid.split("/")[-1]
        lookup=next((f"opencode/{base}" if f"opencode/{base}" in cat else f"oc/{base}" for base in [base] if f"opencode/{base}" in cat or f"oc/{base}" in cat), mid)
    ctx=cat.get(lookup,{}).get("context_length") or 200000
    out=cat.get(lookup,{}).get("max_output_tokens") or min(32768,max(4096,ctx//6))
    cfg["provider"]["omniroute"]["models"][mid]={"limit":{"context":ctx,"output":out},"tool_call":True}
cfg["model"]="omniroute/combo/free-coding"
cfg["small_model"]="omniroute/"+next((m for m in verified if m!="opencode/big-pickle"),"opencode/hy3-free")
json.dump(cfg,open(ocfg,"w"),indent=2)
print(f"[refresh] opencode.json synced ({len(verified)+1} entries)")
PY

log "refresh complete"