#!/usr/bin/env bash
# Manage custom (static) DNS A records on the UDM Pro through the UniFi Network API.
#
#   scripts/udm-dns.sh [-n] list
#   scripts/udm-dns.sh [-n] set <name> <ipv4>     # idempotent upsert; <name> may be *.sub.domain
#   scripts/udm-dns.sh [-n] rm  <name> [<ipv4>]   # idempotent; all records of that name, or only those -> ipv4
#   scripts/udm-dns.sh [-n] ensure-lab            # *.lab.kleincogroup.com + lab.kleincogroup.com -> LAB_NODE_IP
#
#   -n   dry run: reads still happen (when credentials exist, incl. a session login/logout),
#        DNS writes are printed instead of sent.
#
# Credentials: ~/.config/lab-k3s/udm.env (override with UDM_ENV), chmod 600, never in git:
#   UDM_HOST=192.168.4.1        # default
#   UDM_API_KEY=...             # Network API key (Settings > Control Plane > Integrations; docs/dns.md)
#   UDM_USER=... UDM_PASS=...   # or: a local UniFi OS admin (no 2FA/SSO)
#   UDM_SITE=default            # site's internal name (default)
#   UDM_API=auto                # auto | integration | v2   (see docs/dns.md)
#   UDM_TTL=300                 # TTL for records created via the integration API (it requires one)
#   UDM_CACERT=/path/ca.pem     # optional: verify the UDM's TLS cert instead of accepting self-signed
#
# Two backends (docs/dns.md has the details and what is verified):
#   integration  /proxy/network/integration/v1/sites/{siteId}/dns/policies   (X-API-KEY; the documented API)
#   v2           /proxy/network/v2/api/site/{site}/static-dns                (session login; what the web UI uses)
# auto = integration when UDM_API_KEY is set, else v2 with UDM_USER/UDM_PASS.
#
# Secrets never appear on a command line (curl reads headers/bodies from 0600 files or stdin)
# and are never printed.
set -euo pipefail

LAB_NODE_IP="${LAB_NODE_IP:-192.168.4.243}"
LAB_DOMAIN="${LAB_DOMAIN:-lab.kleincogroup.com}"
DRY_RUN=0

die()  { echo "udm-dns: $*" >&2; exit 1; }
log()  { echo "udm-dns: $*" >&2; }
usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# ---------------------------------------------------------------- config / session
load_config() {
  local env_file="${UDM_ENV:-$HOME/.config/lab-k3s/udm.env}"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
  fi
  UDM_HOST="${UDM_HOST:-192.168.4.1}"
  UDM_SITE="${UDM_SITE:-default}"
  UDM_API="${UDM_API:-auto}"
  UDM_TTL="${UDM_TTL:-300}"
  if ! [[ "$UDM_TTL" =~ ^[0-9]+$ ]] || (( UDM_TTL > 86400 )); then die "UDM_TTL must be 0..86400 seconds"; fi
  BASE="https://${UDM_HOST}"
  if [[ "$UDM_API" == auto ]]; then
    if [[ -n "${UDM_API_KEY:-}" ]]; then UDM_API=integration
    elif [[ -n "${UDM_USER:-}" && -n "${UDM_PASS:-}" ]]; then UDM_API=v2
    else UDM_API=none
    fi
  fi
  case "$UDM_API" in integration|v2|none) ;; *) die "UDM_API must be auto, integration or v2 (got '$UDM_API')";; esac
  if [[ -n "${UDM_CACERT:-}" ]]; then TLS_OPT=(--cacert "$UDM_CACERT"); else TLS_OPT=(--insecure); fi
}

WORK=""
LOGGED_IN=0
cleanup() {
  if [[ "$LOGGED_IN" == 1 ]]; then
    curl -s -o /dev/null "${TLS_OPT[@]}" -b "$WORK/cookies" -H "@$WORK/auth-headers" \
      -X POST "$BASE/api/auth/logout" || true
  fi
  if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

session_init() {
  [[ -n "$WORK" ]] && return 0
  [[ "$UDM_API" == none ]] && die "no credentials: set UDM_API_KEY or UDM_USER/UDM_PASS in ${UDM_ENV:-$HOME/.config/lab-k3s/udm.env}"
  WORK="$(umask 077; mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/udm-dns.XXXXXX")"
  : > "$WORK/auth-headers"; chmod 600 "$WORK/auth-headers"
  if [[ "$UDM_API" == integration || -n "${UDM_API_KEY:-}" ]]; then
    [[ -n "${UDM_API_KEY:-}" ]] || die "UDM_API=integration needs UDM_API_KEY"
    printf 'X-API-KEY: %s\n' "$UDM_API_KEY" > "$WORK/auth-headers"
  fi
  if [[ "$UDM_API" == v2 && -z "${UDM_API_KEY:-}" ]]; then
    [[ -n "${UDM_USER:-}" && -n "${UDM_PASS:-}" ]] || die "UDM_API=v2 needs UDM_USER/UDM_PASS (or UDM_API_KEY, unverified on v2)"
    local code
    code="$(jq -n '{username: env.UDM_USER, password: env.UDM_PASS, rememberMe: false}' |
      curl -s "${TLS_OPT[@]}" -o "$WORK/login.json" -D "$WORK/login.hdr" -w '%{http_code}' \
        -c "$WORK/cookies" -H 'Content-Type: application/json' --data-binary @- "$BASE/api/auth/login")" \
      || die "cannot reach $BASE (curl failed)"
    [[ "$code" == 200 ]] || die "login to $BASE failed (HTTP $code); check UDM_USER/UDM_PASS (a local admin, no 2FA)"
    LOGGED_IN=1
    local csrf
    csrf="$(tr -d '\r' < "$WORK/login.hdr" | awk -F': ' 'tolower($1)=="x-csrf-token"{print $2}' | tail -1)"
    [[ -n "$csrf" ]] || die "login succeeded but no X-CSRF-Token header came back"
    printf 'X-CSRF-Token: %s\n' "$csrf" > "$WORK/auth-headers"
  fi
}

# api METHOD PATH [JSON-BODY] -> response body on stdout; dies on HTTP >= 400.
api() {
  local method="$1" path="$2" body="${3:-}" code
  session_init
  local args=("${TLS_OPT[@]}" -s -o "$WORK/resp" -D "$WORK/resp.hdr" -w '%{http_code}'
              -X "$method" -H "@$WORK/auth-headers" -H 'Accept: application/json')
  [[ -f "$WORK/cookies" ]] && args+=(-b "$WORK/cookies" -c "$WORK/cookies")
  if [[ -n "$body" ]]; then
    code="$(printf '%s' "$body" | curl "${args[@]}" -H 'Content-Type: application/json' --data-binary @- "$BASE$path")" \
      || die "$method $path: curl failed"
  else
    code="$(curl "${args[@]}" "$BASE$path")" || die "$method $path: curl failed"
  fi
  # UniFi OS rotates the CSRF token on some responses.
  local upd
  upd="$(tr -d '\r' < "$WORK/resp.hdr" | awk -F': ' 'tolower($1)=="x-updated-csrf-token"{print $2}' | tail -1)"
  if [[ -n "$upd" && "$UDM_API" == v2 && -z "${UDM_API_KEY:-}" ]]; then
    printf 'X-CSRF-Token: %s\n' "$upd" > "$WORK/auth-headers"
  fi
  if (( code >= 400 )); then
    log "$method $path -> HTTP $code: $(head -c 400 "$WORK/resp")"
    if [[ "$code" == 401 && "$UDM_API" == v2 && -n "${UDM_API_KEY:-}" ]]; then
      log "the v2 endpoint rejected the API key; use UDM_API=integration or UDM_USER/UDM_PASS"
    fi
    return 1
  fi
  cat "$WORK/resp"
}

# write METHOD PATH [BODY]: like api, but honours -n.
write() {
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "DRY-RUN: $1 $BASE$2${3:+ $3}"
    return 0
  fi
  api "$@" > /dev/null
}

# ---------------------------------------------------------------- backends
# Normalised record lines on stdout: id<TAB>name<TAB>type<TAB>value<TAB>enabled

SITE_ID=""
integration_site_id() {
  [[ -n "$SITE_ID" ]] && return 0
  SITE_ID="$(api GET "/proxy/network/integration/v1/sites?limit=200" |
    jq -r --arg s "$UDM_SITE" '.data[] | select(.internalReference == $s or .name == $s) | .id' | head -1)" \
    || die "listing sites via the integration API failed"
  [[ -n "$SITE_ID" ]] || die "site '$UDM_SITE' not found via the integration API"
}

# Pure parsers (no network) so they can be tested against captured JSON.
parse_v2()          { jq -r '.[] | [._id, .key, .record_type, (.value // ""), (if .enabled == false then "false" else "true" end)] | @tsv'; }
parse_integration() {
  jq -r '.data[] | [.id, (.domain // ""),
           ({"A_RECORD":"A","AAAA_RECORD":"AAAA","CNAME_RECORD":"CNAME","MX_RECORD":"MX","TXT_RECORD":"TXT",
             "SRV_RECORD":"SRV","FORWARD_DOMAIN":"FORWARD"}[.type] // .type),
           (.ipv4Address // .ipv6Address // .targetDomain // .mailServerDomain // .text // .serverDomain // .ipAddress // ""),
           (.enabled | tostring)] | @tsv'
}

records() {
  case "$UDM_API" in
    v2) api GET "/proxy/network/v2/api/site/${UDM_SITE}/static-dns" | parse_v2 ;;
    integration)
      integration_site_id
      local offset=0 page total
      while :; do
        page="$(api GET "/proxy/network/integration/v1/sites/${SITE_ID}/dns/policies?offset=${offset}&limit=200")" || return 1
        printf '%s' "$page" | parse_integration || return 1
        total="$(jq -r '.totalCount' <<<"$page")"
        [[ "$total" =~ ^[0-9]+$ ]] || { log "unexpected dns/policies response (no numeric totalCount)"; return 1; }
        offset=$(( offset + $(jq -r '.count // (.data|length)' <<<"$page") ))
        if (( offset >= total )) || (( $(jq -r '.data|length' <<<"$page") == 0 )); then break; fi
      done ;;
    none) die "no credentials (see header of $0)" ;;
  esac
}

create_a() { # name ip
  case "$UDM_API" in
    v2) write POST "/proxy/network/v2/api/site/${UDM_SITE}/static-dns" \
          "$(jq -cn --arg k "$1" --arg v "$2" '{key:$k, record_type:"A", value:$v, enabled:true}')" ;;
    integration) integration_site_id
      write POST "/proxy/network/integration/v1/sites/${SITE_ID}/dns/policies" \
        "$(jq -cn --arg d "$1" --arg v "$2" --argjson t "$UDM_TTL" \
             '{type:"A_RECORD", enabled:true, domain:$d, ipv4Address:$v, ttlSeconds:$t}')" ;;
  esac
}

update_a() { # id name ip
  case "$UDM_API" in
    v2) # PUT the full stored object back with the new value (what the web UI does).
      local cur
      cur="$(api GET "/proxy/network/v2/api/site/${UDM_SITE}/static-dns" | jq -c --arg id "$1" '.[] | select(._id == $id)')" \
        || die "re-reading record $1 failed"
      [[ -n "$cur" ]] || die "record $1 vanished while updating"
      write PUT "/proxy/network/v2/api/site/${UDM_SITE}/static-dns/$1" \
        "$(jq -c --arg v "$3" '. + {value:$v, enabled:true}' <<<"$cur")" ;;
    integration) integration_site_id
      write PUT "/proxy/network/integration/v1/sites/${SITE_ID}/dns/policies/$1" \
        "$(jq -cn --arg d "$2" --arg v "$3" --argjson t "$UDM_TTL" \
             '{type:"A_RECORD", enabled:true, domain:$d, ipv4Address:$v, ttlSeconds:$t}')" ;;
  esac
}

delete_id() {
  case "$UDM_API" in
    v2) write DELETE "/proxy/network/v2/api/site/${UDM_SITE}/static-dns/$1" ;;
    integration) integration_site_id; write DELETE "/proxy/network/integration/v1/sites/${SITE_ID}/dns/policies/$1" ;;
  esac
}

# ---------------------------------------------------------------- verification
# For a wildcard, query a concrete label under it.
probe_name() { if [[ "$1" == '*.'* ]]; then echo "udm-dns-probe.${1#\*.}"; else echo "$1"; fi; }

verify() { # name expected-ip|"" (empty = must not resolve to old ip given as $3)
  local name q ans
  name="$1"; q="$(probe_name "$name")"
  [[ "$DRY_RUN" == 1 ]] && { echo "DRY-RUN: would verify with: dig +short $q @$UDM_HOST"; return 0; }
  command -v dig >/dev/null || { log "dig not installed; skipping verification"; return 0; }
  for _ in 1 2 3 4 5; do
    ans="$(dig +short +time=2 +tries=1 A "$q" "@$UDM_HOST" 2>/dev/null | tr '\n' ' ' || true)"
    if [[ -n "$2" ]]; then
      [[ " $ans" == *" $2 "* ]] && { log "verified: $q -> $ans(via $UDM_HOST)"; return 0; }
    else
      [[ " $ans" != *" ${3:-none} "* ]] && { log "verified: $q no longer -> ${3:-?} (now: ${ans:-no answer})"; return 0; }
    fi
    sleep 2
  done
  log "WARNING: after 5 tries $q still answers '${ans:-no answer}' via $UDM_HOST"
  return 1
}

# ---------------------------------------------------------------- commands
# Labels: letters/digits/_/-, not starting or ending with '-'. 127 = the UniFi API's max length.
valid_name() { [[ "$1" =~ ^(\*\.)?([A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?\.)+[A-Za-z]{2,63}$ ]] && (( ${#1} <= 127 )); }
# Dotted quad, each octet 0-255 without leading zeros.
valid_ip()   { local o='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'; [[ "$1" =~ ^$o\.$o\.$o\.$o$ ]]; }

cmd_list() {
  local out
  out="$(records)" || die "listing records failed"
  { printf 'NAME\tTYPE\tVALUE\tENABLED\tID\n'
    [[ -n "$out" ]] && awk -F'\t' -v OFS='\t' '{print $2,$3,$4,$5,$1}' <<<"$out" | sort; } | column -t -s $'\t'
}

cmd_set() {
  local name="${1,,}" ip="$2" all same others n
  valid_name "$name" || die "invalid name '$1'"
  valid_ip "$ip" || die "invalid IPv4 '$ip'"
  if [[ "$UDM_API" == none && "$DRY_RUN" == 1 ]]; then
    echo "DRY-RUN: no UDM credentials; would upsert A $name -> $ip"; return 0
  fi
  all="$(records)" || die "listing records failed; nothing changed"
  same="$(awk -F'\t' -v n="$name" 'tolower($2)==n' <<<"$all")"
  others="$(awk -F'\t' '$3!="A"' <<<"$same")"
  same="$(awk -F'\t' '$3=="A"' <<<"$same")"
  [[ -z "$others" ]] || die "$name already has non-A record(s); remove them first:"$'\n'"$others"
  n="$(grep -c . <<<"$same" || true)"
  if (( n == 0 )); then
    log "creating A $name -> $ip"; create_a "$name" "$ip" || die "create failed"
  elif (( n == 1 )); then
    local id val en; IFS=$'\t' read -r id _ _ val en <<<"$same"
    if [[ "$val" == "$ip" && "$en" == true ]]; then
      log "unchanged: A $name -> $ip"
    else
      log "updating A $name: $val -> $ip"; update_a "$id" "$name" "$ip" || die "update failed"
    fi
  else
    die "$name has $n A records; refusing to guess. Run: $0 rm '$name' && $0 set '$name' $ip"
  fi
  verify "$name" "$ip"
}

cmd_rm() { # name [value]: with a value, only records with exactly that value are removed
  local name="${1,,}" only="${2:-}" match id val ips=""
  valid_name "$name" || die "invalid name '$1'"
  if [[ "$UDM_API" == none && "$DRY_RUN" == 1 ]]; then
    echo "DRY-RUN: no UDM credentials; would delete records named $name${only:+ with value $only}"; return 0
  fi
  match="$(records | awk -F'\t' -v n="$name" -v v="$only" 'tolower($2)==n && (v=="" || $4==v)')" \
    || die "listing records failed; nothing changed"
  [[ -n "$match" ]] || { log "nothing to remove for $name${only:+ -> $only}"; return 0; }
  while IFS=$'\t' read -r id _ _ val _; do
    log "deleting $name ($val, id $id)"; delete_id "$id" || die "delete of $id failed"; ips="$val"
  done <<<"$match"
  # Not fatal: a covering wildcard (e.g. *.lab) can legitimately still answer the same IP.
  verify "$name" "" "$ips" || log "(if a wildcard record covers $name, that answer is expected)"
}

cmd_ensure_lab() {
  cmd_set "*.${LAB_DOMAIN}" "$LAB_NODE_IP"
  cmd_set "${LAB_DOMAIN}" "$LAB_NODE_IP"
}

main() {
  while getopts ':nh' o; do
    case "$o" in n) DRY_RUN=1 ;; h) usage ;; *) usage ;; esac
  done
  shift $((OPTIND - 1))
  [[ $# -ge 1 ]] || usage
  command -v jq >/dev/null || die "jq is required"
  command -v curl >/dev/null || die "curl is required"
  load_config
  local cmd="$1"; shift
  # Open the session here, in the top-level shell: later calls run inside $(...) subshells,
  # which share these files but would not run (or inherit) the cleanup trap.
  [[ "$UDM_API" != none ]] && session_init
  case "$cmd" in
    list)       [[ $# -eq 0 ]] || usage; cmd_list ;;
    set)        [[ $# -eq 2 ]] || usage; cmd_set "$1" "$2" ;;
    rm)         [[ $# -ge 1 && $# -le 2 ]] || usage; cmd_rm "$1" "${2:-}" ;;
    ensure-lab) [[ $# -eq 0 ]] || usage; cmd_ensure_lab ;;
    *) usage ;;
  esac
}

# Allow `source scripts/udm-dns.sh` (tests) without running main.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
