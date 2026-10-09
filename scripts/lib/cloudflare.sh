# shellcheck shell=bash
# Shared helpers for scripts/expose.sh and scripts/unexpose.sh. Source, don't run.
#
# Env (all optional):
#   CLOUDFLARE_API_TOKEN   else read from ~/.config/cloudflare/api-token (or $CF_TOKEN_FILE)
#   CF_ZONE=kleincogroup.com   CF_TUNNEL=homelab   LAB_NODE_IP=192.168.4.243
#   EXPOSE_ORIGIN=https://localhost:443   (where cloudflared sends traffic: Traefik on this node)
#
# IDs are looked up on every run, never hardcoded. The token is passed to curl through a
# 0600 header file, so it never appears in argv / ps, and is never printed.

CF_API="https://api.cloudflare.com/client/v4"
CF_ZONE="${CF_ZONE:-kleincogroup.com}"
CF_TUNNEL="${CF_TUNNEL:-homelab}"
LAB_NODE_IP="${LAB_NODE_IP:-192.168.4.243}"
EXPOSE_ORIGIN="${EXPOSE_ORIGIN:-https://localhost:443}"
DRY_RUN="${DRY_RUN:-0}"
# shellcheck disable=SC2034 # used by the sourcing scripts
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die()  { echo "${0##*/}: $*" >&2; exit 1; }
log()  { echo "${0##*/}: $*" >&2; }
warn() { echo "${0##*/}: WARNING: $*" >&2; }

CF_WORK=""
cf_cleanup() { if [[ -n "$CF_WORK" ]]; then rm -rf "$CF_WORK"; fi; }

cf_init() {
  command -v jq >/dev/null || die "jq is required"
  command -v curl >/dev/null || die "curl is required"
  local token="${CLOUDFLARE_API_TOKEN:-}"
  local file="${CF_TOKEN_FILE:-$HOME/.config/cloudflare/api-token}"
  if [[ -z "$token" && -r "$file" ]]; then token="$(tr -d '[:space:]' < "$file")"; fi
  [[ -n "$token" ]] || die "no Cloudflare token: set CLOUDFLARE_API_TOKEN or create $file"
  CF_WORK="$(umask 077; mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/cf.XXXXXX")"
  trap cf_cleanup EXIT
  printf 'Authorization: Bearer %s\n' "$token" > "$CF_WORK/auth"
  unset token
}

# cf METHOD PATH [JSON] -> .result on stdout. On failure prints Cloudflare's errors, returns 1.
cf() {
  local method="$1" path="$2" body="${3:-}" args code
  args=(-s -o "$CF_WORK/resp" -w '%{http_code}' -X "$method" -H "@$CF_WORK/auth")
  if [[ -n "$body" ]]; then
    code="$(printf '%s' "$body" | curl "${args[@]}" -H 'Content-Type: application/json' --data-binary @- "$CF_API$path")" \
      || { log "$method $path: curl failed"; return 1; }
  else
    code="$(curl "${args[@]}" "$CF_API$path")" || { log "$method $path: curl failed"; return 1; }
  fi
  if [[ "$(jq -r '.success // false' "$CF_WORK/resp" 2>/dev/null)" != true ]]; then
    log "$method $path -> HTTP $code: $(jq -c '.errors // .' "$CF_WORK/resp" 2>/dev/null || head -c 300 "$CF_WORK/resp")"
    return 1
  fi
  jq -c '.result' "$CF_WORK/resp"
}

# cf_write: like cf, but under -n prints the call (body included; bodies never hold secrets).
cf_write() {
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "DRY-RUN: $1 $CF_API$2"
    [[ -n "${3:-}" ]] && jq . <<<"$3" | sed 's/^/    /'
    return 0
  fi
  cf "$@" > /dev/null
}

# Sets ZONE_ID, ACCOUNT_ID, TUNNEL_ID, TUNNEL_TARGET.
cf_lookup_ids() {
  local z t
  z="$(cf GET "/zones?name=${CF_ZONE}")" || die "zone lookup failed"
  ZONE_ID="$(jq -r '.[0].id // empty' <<<"$z")"
  ACCOUNT_ID="$(jq -r '.[0].account.id // empty' <<<"$z")"
  [[ -n "$ZONE_ID" && -n "$ACCOUNT_ID" ]] || die "zone $CF_ZONE not found for this token"
  t="$(cf GET "/accounts/${ACCOUNT_ID}/cfd_tunnel?name=${CF_TUNNEL}&is_deleted=false")" || die "tunnel lookup failed"
  [[ "$(jq 'length' <<<"$t")" == 1 ]] || die "expected exactly one live tunnel named '$CF_TUNNEL', found $(jq 'length' <<<"$t")"
  TUNNEL_ID="$(jq -r '.[0].id' <<<"$t")"
  # shellcheck disable=SC2034 # used by the sourcing scripts
  TUNNEL_TARGET="${TUNNEL_ID,,}.cfargotunnel.com"
  [[ "$(jq -r '.[0].remote_config' <<<"$t")" == true ]] \
    || die "tunnel '$CF_TUNNEL' is locally managed (config.yml); this script only edits remotely managed tunnels"
}

# The whole tunnel configuration object (.config), as stored by Cloudflare.
cf_tunnel_config() {
  local r
  r="$(cf GET "/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations")" || die "reading tunnel config failed"
  jq -e '.config.ingress | type == "array"' <<<"$r" >/dev/null || die "tunnel config has no ingress list; refusing to write"
  jq -c '.config' <<<"$r"
}

# PUT the whole config object back (the PUT replaces everything: ingress, originRequest, warp-routing).
cf_put_tunnel_config() {
  local cfg="$1"
  # Safety: the last rule must still be a hostname-less catch-all.
  jq -e '.ingress | length > 0 and (.[-1] | has("hostname") | not)' <<<"$cfg" >/dev/null \
    || die "refusing to PUT a config whose last ingress rule is not a catch-all"
  cf_write PUT "/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" "$(jq -c '{config: .}' <<<"$cfg")"
}

# All DNS records with exactly this name (any type).
cf_dns_records() { cf GET "/zones/${ZONE_ID}/dns_records?name=$1&per_page=100"; }

# Access apps whose domain is this hostname (paginated list, filtered locally).
cf_access_apps_for() {
  local host="$1" page=1 r all="[]"
  while :; do
    r="$(cf GET "/accounts/${ACCOUNT_ID}/access/apps?page=${page}&per_page=100")" || return 1
    all="$(jq -c --argjson a "$all" '$a + .' <<<"$r")"
    [[ "$(jq 'length' <<<"$r")" -lt 100 ]] && break
    page=$((page + 1))
  done
  # Match the legacy .domain/.self_hosted_domains and the newer .destinations[].uri, ignoring
  # any path, plus wildcard apps (*.zone) that would also cover the host.
  jq -c --arg h "$host" '
    def hostof: ascii_downcase | sub("^https?://"; "") | sub("/.*$"; "");
    def covers: hostof as $d | $d == $h or ($d | startswith("*.")) and ($h | endswith($d[1:]));
    [.[] | select(
        ([.domain // empty] + (.self_hosted_domains // []) + [(.destinations // [])[] | .uri // empty])
        | any(covers))]' <<<"$all"
}

# An Access app is "ours" (created by expose.sh, safe to update/delete) only if it carries our
# name and protects exactly this one hostname.
app_name() { echo "lab-k3s ${1%%.*}"; }
# shellcheck disable=SC2034 # OUR_APPS/OTHER_APPS are read by the sourcing scripts
# Path-scoped "bypass" apps expose.sh --bypass-path creates for one host.
bypass_app_name() { echo "lab-k3s bypass ${1%%.*} ${2}"; }
BYPASS_POLICY_NAME="lab-k3s bypass everyone"
cf_split_apps() { # apps-json fqdn -> sets OUR_APPS / OUR_BYPASS / OTHER_APPS
  OUR_APPS="$(jq -c --arg n "$(app_name "$2")" --arg h "$2" \
    '[.[] | select(.name == $n and ((.domain // "") | ascii_downcase) == $h
                   and ((.self_hosted_domains // [$h]) | length) <= 1)]' <<<"$1")"
  OUR_BYPASS="$(jq -c --arg p "$(bypass_app_name "$2" "")" --arg h "$2" \
    '[.[] | select((.name // "") | startswith($p))
              | select(((.domain // "") | ascii_downcase) | startswith($h + "/"))]' <<<"$1")"
  OTHER_APPS="$(jq -c --argjson o "$OUR_APPS" --argjson b "$OUR_BYPASS" \
    '[.[] | select(.id as $i | (($o + $b) | map(.id) | index($i)) | not)]' <<<"$1")"
}

# Serialise read-modify-write of the tunnel config between concurrent runs on this host.
cf_lock() {
  command -v flock >/dev/null || { warn "flock not found; not locking"; return 0; }
  exec 9>"${XDG_RUNTIME_DIR:-/tmp}/lab-k3s-cloudflare.lock"
  flock -w 120 9 || die "another expose/unexpose run holds the lock"
}

# Reusable Access policies created by expose.sh carry this name.
policy_name() { echo "lab-k3s allow ${1}"; }

cf_policy_by_name() {
  local name="$1" page=1 r all="[]"
  while :; do
    r="$(cf GET "/accounts/${ACCOUNT_ID}/access/policies?page=${page}&per_page=100")" || return 1
    all="$(jq -c --argjson a "$all" '$a + .' <<<"$r")"
    [[ "$(jq 'length' <<<"$r")" -lt 100 ]] && break
    page=$((page + 1))
  done
  jq -c --arg n "$name" '[.[] | select(.name == $n)]' <<<"$all"
}

valid_label() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }

# Names reserved by policy (home = the UDM's DDNS record; lab = the internal domain).
reserved_label() { case "$1" in home|lab|www|mail|_*) return 0 ;; *) return 1 ;; esac; }
