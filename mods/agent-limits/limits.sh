#!/bin/sh
# Prints the agents' usage limits as JSON for main.js:
# [{"agent", "name", "updated_at", "unlimited"?, "windows": [{"label", "minutes", "pct", "resets_at"}]}]
# Plans differ: some have no 5-hour window, some only a weekly or monthly one, some none
# ("unlimited": the server answered with no limits). Only windows that exist are listed.
# Local sources: Claude's rate_limits cached by statusline.sh beside this file (optional, set as
# Claude Code's statusLine), and the newest token_count rate_limits in ~/.codex/sessions.
# --live first asks the servers (Claude's OAuth usage API, Codex's app-server, Kimi's /usages,
# Grok's billing) and caches the answers; failures go to stderr and the local data is printed
# anyway. Accounts without a subscription sign-in (API keys) are skipped quietly.
# Any argument that is not --live names an agent to include (claude, codex, kimi, grok);
# with no such arguments every agent is included. Hidden agents are neither fetched nor shown.

PATH="$PATH:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-limits"
CLAUDE_CACHE="$CACHE_DIR/claude.json"
CLAUDE_SERVER_CACHE="$CACHE_DIR/claude-server.json"
CLAUDE_WAIT="$CACHE_DIR/claude-wait-until"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_CACHE="$CACHE_DIR/codex.json"
KIMI_CACHE="$CACHE_DIR/kimi.json"
GROK_CACHE="$CACHE_DIR/grok.json"

# Which agents to fetch and print: every argument that is not --live; empty means all.
LIVE=0
WANTED=""
for arg in "$@"; do
  case "$arg" in
    --live) LIVE=1 ;;
    *) WANTED="$WANTED $arg " ;;
  esac
done
# wanted <agent>: true when the agent is selected (no selection = all selected).
wanted() { case "$WANTED" in *" $1 "*) return 0 ;; *" "*) return 1 ;; *) return 0 ;; esac; }

# Runs a fetcher, keeping its stderr as that agent's last error (cleared on success),
# so a broken agent can still get a row with an "Err" mark even when it has no data.
run_fetch() {
  agent=$1; shift
  err=$("$@" 2>&1 >/dev/null)
  if [ -n "$err" ]; then printf '%s' "$err" >"$CACHE_DIR/$agent.err"; else rm -f "$CACHE_DIR/$agent.err"; fi
}

# Shared by every jq program below: a window's label from its length in minutes.
LABEL='def win_label: if . < 1440 then "\(. / 60 | floor)h" else "\(. / 1440 | floor)d" end;'

# Writes stdin to $1 only if it is a non-empty JSON value, replacing the file atomically.
save() {
  tmp="$1.$$"
  if jq -e . >"$tmp" 2>/dev/null; then mv -f "$tmp" "$1"; else rm -f "$tmp"; return 1; fi
}

fetch_claude() {
  # Claude Code keeps its sign-in in the macOS Keychain, elsewhere in .credentials.json.
  creds=""
  if command -v security >/dev/null 2>&1; then
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  fi
  [ -n "$creds" ] || creds=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null)
  token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [ -n "$token" ] || return 0
  # After a 429 the usage API is left alone until the time it asked for.
  now=$(date +%s)
  until=$(cat "$CLAUDE_WAIT" 2>/dev/null)
  case "$until" in '' | *[!0-9]*) until=0 ;; esac
  if [ "$until" -gt "$now" ]; then
    echo "Claude: the server asked to wait; next check in $(((until - now + 59) / 60)) min" >&2
    return
  fi
  # The token goes through stdin so it never shows in the process list.
  resp=$(printf 'Authorization: Bearer %s\n' "$token" |
    curl -sS -m 10 -H @- -H "anthropic-beta: oauth-2025-04-20" -w '\n%{http_code} %header{retry-after}' \
      https://api.anthropic.com/api/oauth/usage 2>&1)
  status=$(printf '%s' "$resp" | tail -n 1)
  code=${status%% *}
  retry=${status#* }
  body=$(printf '%s' "$resp" | sed '$d')
  case "$code" in
    200) rm -f "$CLAUDE_WAIT" ;;
    429)
      # Retry-After in seconds; a date, or a curl too old to read headers, gets 10 minutes.
      case "$retry" in '' | *[!0-9]*) retry=600 ;; esac
      echo $((now + retry)) >"$CLAUDE_WAIT"
      echo "Claude: too many requests; next check in $(((retry + 59) / 60)) min" >&2
      return
      ;;
    401) echo "Claude: sign-in expired; open Claude Code to renew it" >&2; return ;;
    000) echo "Claude: could not reach the server" >&2; return ;;
    *) echo "Claude: server answered HTTP $code" >&2; return ;;
  esac
  printf '%s' "$body" | jq -c --argjson now "$(date +%s)" '
    def epoch: if . == null then null
      else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601? // null end;
    def win: if . == null then null else {used_percentage: .utilization, resets_at: (.resets_at | epoch)} end;
    ({five_hour: (.five_hour | win), seven_day: (.seven_day | win)} | with_entries(select(.value != null))) as $rl
    | {updated_at: $now, rate_limits: $rl, no_limits: ($rl == {})}' |
    save "$CLAUDE_SERVER_CACHE" || echo "Claude: unexpected answer from the server" >&2
}

fetch_codex() {
  command -v codex >/dev/null 2>&1 || return 0
  [ "$(jq -r '.auth_mode // empty' "$CODEX_HOME/auth.json" 2>/dev/null)" = "chatgpt" ] || return 0
  dir=$(mktemp -d)
  mkfifo "$dir/in"
  codex app-server <"$dir/in" >"$dir/out" 2>/dev/null &
  pid=$!
  exec 3>"$dir/in"
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"herdr_agent_limits","title":"Herdr agent limits","version":"0.1.0"}}}' \
    '{"jsonrpc":"2.0","method":"initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}' >&3
  i=0
  while [ "$i" -lt 75 ] && ! grep -q '"id":2' "$dir/out" && kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    i=$((i + 1))
  done
  exec 3>&-
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  if ! grep -q '"id":2' "$dir/out"; then
    echo "Codex: no answer from codex app-server" >&2
  else
    err=$(jq -r 'select(.id == 2) | .error.message // empty' "$dir/out" 2>/dev/null)
    if [ -n "$err" ]; then
      echo "Codex: $err" >&2
    else
      jq -c --argjson now "$(date +%s)" "$LABEL"'
        def win: {label: (.windowDurationMins | win_label), minutes: .windowDurationMins,
                  pct: .usedPercent, resets_at: .resetsAt};
        select(.id == 2) | .result.rateLimits
        | [(.primary, .secondary) | select(. != null) | win] as $w
        | {agent: "codex", name: "Codex", updated_at: $now, unlimited: ($w == []), windows: $w}' "$dir/out" |
        save "$CODEX_CACHE" || echo "Codex: unexpected answer from codex app-server" >&2
    fi
  fi
  rm -rf "$dir"
}

# Kimi Code keeps no quota on disk; the /usages endpoint answers with
# {"usages": {"limit_5h": {"used_ratio": 0..1, "reset_time": ISO}, "limit_7d": …,
#  "limit_month_total": …}}. The token comes from ~/.kimi-code/credentials/*.json.
fetch_kimi() {
  token=$(jq -rs 'map(select((.expires_at // 0) > now)) | max_by(.expires_at) | .access_token // empty' \
    "$HOME/.kimi-code"/credentials/*.json 2>/dev/null)
  [ -n "$token" ] || return 0
  printf 'Authorization: Bearer %s\n' "$token" |
    curl -sS -m 10 -H @- "${KIMI_CODE_BASE_URL:-https://api.kimi.com/coding/v1}/usages" 2>/dev/null |
    jq -c --argjson now "$(date +%s)" '
      def epoch: if . == null then null
        else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601? // null end;
      {updated_at: $now, usages: (.usages // {} | with_entries(.value.resets_epoch = (.value.reset_time | epoch)))}' |
    save "$KIMI_CACHE" || echo "Kimi: could not fetch usage (sign in again with kimi?)" >&2
}

# Grok Build: grok.com answers GetGrokCreditsConfig (gRPC-web, protobuf) with the
# credits percentage and the reset epoch. Local CLIs offer no limit source
# (x.ai/billing is not on `grok agent stdio` in current versions), so this is the
# only read. The token is the grok.com / auth.x.ai key from ~/.grok/auth.json.
fetch_grok() {
  key=$(jq -r 'to_entries[] | select(.key | test("grok.com|auth.x.ai|accounts.x.ai")) | .value.key // empty' \
    "$HOME/.grok/auth.json" 2>/dev/null | head -1)
  [ -n "$key" ] || return 0
  # An empty gRPC-web data frame asks for the credits config. The answer has NUL
  # bytes, so it goes to a file: $(...) would strip them and desync the parser.
  tmp_grok=$(mktemp)
  printf '\0\0\0\0\0' |
    curl -sS -m 15 -X POST "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig" \
      -H "Authorization: Bearer $key" -H "Origin: https://grok.com" -H "Referer: https://grok.com/?_s=usage" \
      -H "Content-Type: application/grpc-web+proto" -H "x-grpc-web: 1" -H "x-user-agent: connect-es/2.1.1" \
      --data-binary @- >"$tmp_grok" 2>/dev/null
  [ -s "$tmp_grok" ] || { echo "Grok: no answer from grok.com" >&2; rm -f "$tmp_grok"; return; }
  python3 -c '
import json, struct, sys, time
# Mirrors herdr-usage-bar grokwebbilling.go: walk the protobuf, take the first
# 0..100 fixed32 on a field numbered 1 as the used %, and the future epoch
# varint (path 1/5/1 preferred, else the smallest) as the reset.
data = open(sys.argv[1], "rb").read()
payloads, i = [], 0
while i + 5 <= len(data):
    flag, ln = data[i], int.from_bytes(data[i+1:i+5], "big")
    if flag & 0x80: break
    payloads.append(data[i+5:i+5+ln]); i += 5 + ln
floats, varints = [], []
def scan(buf, path):
    p = 0
    while p < len(buf):
        tag = buf[p]; p += 1
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            v = 0; shift = 0
            while p < len(buf):
                b = buf[p]; p += 1; v |= (b & 0x7f) << shift; shift += 7
                if not b & 0x80: break
            varints.append((path + [field], v))
        elif wire == 5:
            if p + 4 > len(buf): return
            floats.append((path + [field], struct.unpack("<f", buf[p:p+4])[0])); p += 4
        elif wire == 2:
            v = 0; shift = 0
            while p < len(buf):
                b = buf[p]; p += 1; v |= (b & 0x7f) << shift; shift += 7
                if not b & 0x80: break
            sub = buf[p:p+v]; p += v
            scan(sub, path + [field])
        elif wire == 1: p += 8
        else: return
for pl in payloads: scan(pl, [])
now = time.time()
pct = next((v for pth, v in sorted(floats, key=lambda f: len(f[0]))
            if pth and pth[-1] == 1 and 0 <= v <= 100 and v == v), None)
epochs = [(pth, v) for pth, v in varints if 1_700_000_000 <= v <= 2_100_000_000 and v > now]
reset = next((v for pth, v in epochs if pth == [1, 5, 1]), min((v for _, v in epochs), default=None)) if epochs else None
if pct is None: sys.exit(1)
win = {"minutes": 10080 if reset and 0 < (reset - now) / 86400 <= 10 else 43200,
       "pct": round(pct, 1), "resets_at": int(reset) if reset else None}
print(json.dumps({"updated_at": int(now), "primary": win}))
' "$tmp_grok" | save "$GROK_CACHE" || echo "Grok: could not parse the billing answer (sign in again with grok?)" >&2
  rm -f "$tmp_grok"
}


# The statusline's numbers and the server's answer: whichever is newer. spend_limit comes
# from the statusline behind a Claude gateway (daily, weekly or monthly budgets).
claude_limits() {
  wanted claude || return 0
  for f in "$CLAUDE_CACHE" "$CLAUDE_SERVER_CACHE"; do [ -f "$f" ] && cat "$f"; done |
    jq -sc "$LABEL"'
      def win($m): {label: ($m | win_label), minutes: $m, pct: .used_percentage, resets_at};
      max_by(.updated_at // 0) // empty
      | [(.rate_limits.five_hour // empty | win(300)),
         (.rate_limits.seven_day // empty | win(10080)),
         (.rate_limits.spend_limit // empty
          | win({daily: 1440, weekly: 10080, monthly: 43200}[.period // "monthly"] // 43200))] as $w
      | {agent: "claude", name: "Claude", updated_at, unlimited: (.no_limits == true and $w == []), windows: $w}' 2>/dev/null
}

# Resumed Codex sessions keep appending to their original dated file, so order by mtime.
codex_from_logs() {
  [ -d "$CODEX_HOME/sessions" ] || return 0
  find "$CODEX_HOME/sessions" -name '*.jsonl' -mtime -8 -exec ls -t {} + 2>/dev/null | head -10 |
    while IFS= read -r f; do
      grep -h '"token_count"' "$f" | grep -E '"(primary|secondary)":\{' | tail -1
    done |
    jq -Rnc "$LABEL"'
      def win: {label: (.window_minutes | win_label), minutes: .window_minutes, pct: .used_percent, resets_at};
      [inputs | fromjson? | select(.payload.type? == "token_count")
        | select(.payload.rate_limits.primary != null or .payload.rate_limits.secondary != null)]
      | max_by(.timestamp) // empty
      | {agent: "codex", name: "Codex",
         updated_at: (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // null),
         windows: [(.payload.rate_limits.primary, .payload.rate_limits.secondary) | select(. != null) | win]}'
}

# The server's answer and the session logs: whichever is newer.
codex_limits() {
  wanted codex || return 0
  { codex_from_logs; [ -f "$CODEX_CACHE" ] && cat "$CODEX_CACHE"; } |
    jq -sc 'max_by(.updated_at // 0) // empty'
}

# The newest Kimi /usage answer cached by fetch_kimi.
kimi_limits() {
  wanted kimi || return 0
  [ -f "$KIMI_CACHE" ] || return 0
  cat "$KIMI_CACHE" |
    jq -c "$LABEL"'
      def epoch: if . == null then null
        else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601? // null end;
      def win($k; $m): (.usages[$k] // empty) |
        {label: ($m | win_label), minutes: $m, pct: (.used_ratio * 100), resets_at: (.reset_time | epoch)};
      {agent: "kimi", name: "Kimi", updated_at, windows: [
         win("limit_5h"; 300), win("limit_7d"; 10080), win("limit_month_total"; 43200)]}' 2>/dev/null
}

# The newest Grok web-billing answer cached by fetch_grok.
grok_limits() {
  wanted grok || return 0
  [ -f "$GROK_CACHE" ] || return 0
  cat "$GROK_CACHE" |
    jq -c "$LABEL"'
      def win: {label: (.minutes | win_label), minutes, pct, resets_at};
      {agent: "grok", name: "Grok", updated_at, windows: ([.primary, .secondary | select(. != null) | win])}' 2>/dev/null
}

if [ "$LIVE" = 1 ]; then
  mkdir -p "$CACHE_DIR"
  wanted claude && run_fetch claude fetch_claude &
  wanted codex && run_fetch codex fetch_codex &
  wanted kimi && run_fetch kimi fetch_kimi &
  wanted grok && run_fetch grok fetch_grok &
  wait
fi

# Rows with no windows are kept: an agent whose sign-in broke keeps its row so the
# error can sit on it, instead of only a shared indicator that names no one.
rows=$({ claude_limits; codex_limits; kimi_limits; grok_limits; } | jq -sc '.')

# A wanted agent with a recorded error but no data still gets a row: its error is
# shown on the row (main.js paints "Err" at its end), not as a nameless badge.
for pair in claude:Claude codex:Codex kimi:Kimi grok:Grok; do
  agent=${pair%%:*}; name=${pair#*:}
  wanted "$agent" || continue
  echo "$rows" | jq -e --arg a "$agent" 'map(.agent) | index($a) != null' >/dev/null && continue
  [ -f "$CACHE_DIR/$agent.err" ] || continue
  rows=$(echo "$rows" | jq -c --arg a "$agent" --arg n "$name" '. + [{agent: $a, name: $n, windows: []}]')
done
echo "$rows"
