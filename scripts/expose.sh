#!/usr/bin/env bash
# Expose a cluster service to the Internet as https://<name>.kleincogroup.com through the
# existing Cloudflare tunnel, and make LAN clients reach it directly (split-horizon).
#
#   scripts/expose.sh [-n] <name> --public
#   scripts/expose.sh [-n] <name> --gated --allow-email a@x.com [--allow-email b@y.com ...] [--add-otp]
#
#   -n             dry run: look everything up, print the API calls that would be made
#   --public       anyone on the Internet can reach it (refuses if an Access app already gates it)
#   --gated        put a Cloudflare Access app in front, allowing only the listed emails
#                  (the gate applies to traffic through Cloudflare; LAN clients go direct)
#   --allow-email  repeatable; required with --gated (re-running replaces the list)
#   --add-otp      with --gated: if the account has no login method at all, add the
#                  One-time PIN identity provider so the listed emails can sign in
#   --replace      allow replacing an existing tunnel route for this name that points at a
#                  different origin (e.g. a non-cluster service on another port)
#
# Order matters: with --gated, the Access app exists before the name is routed, so a failure
# can never leave the service public. Each step is idempotent (re-running converges):
#   1. (--gated) reusable Access policy + self-hosted Access app for the hostname
#   2. tunnel ingress rule <name>.kleincogroup.com -> $EXPOSE_ORIGIN (Traefik), inserted
#      before the http_status:404 catch-all; the whole config object is PUT back
#   3. proxied CNAME <name>.kleincogroup.com -> <tunnel-id>.cfargotunnel.com
#   4. UDM record <name>.kleincogroup.com -> $LAB_NODE_IP via scripts/udm-dns.sh
# Undo with scripts/unexpose.sh <name>. See docs/cloudflare.md.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib/cloudflare.sh
. "$(dirname "$0")/lib/cloudflare.sh"

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

MODE="" NAME="" ADD_OTP=0 REPLACE=0
EMAILS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    --public) [[ -z "$MODE" || "$MODE" == public ]] || die "--public and --gated are exclusive"; MODE=public ;;
    --gated)  [[ -z "$MODE" || "$MODE" == gated ]]  || die "--public and --gated are exclusive"; MODE=gated ;;
    --allow-email) [[ $# -ge 2 ]] || usage; EMAILS+=("${2,,}"); shift ;;
    --allow-email=*) e="${1#*=}"; EMAILS+=("${e,,}") ;;
    --add-otp) ADD_OTP=1 ;;
    --replace) REPLACE=1 ;;
    -h|--help) usage ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$NAME" ]] || die "one name only"; NAME="${1,,}" ;;
  esac
  shift
done
[[ -n "$NAME" ]] || usage
[[ -n "$MODE" ]] || die "choose --public or --gated explicitly (there is no default)"
NAME="${NAME%."${CF_ZONE}"}"
valid_label "$NAME" || die "'$NAME' must be a single DNS label (Universal SSL covers only <name>.${CF_ZONE})"
reserved_label "$NAME" && die "'$NAME' is reserved in this zone"
if [[ "$MODE" == gated ]]; then
  [[ ${#EMAILS[@]} -gt 0 ]] || die "--gated needs at least one --allow-email"
  for e in "${EMAILS[@]}"; do [[ "$e" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "bad email '$e'"; done
else
  [[ ${#EMAILS[@]} -eq 0 ]] || die "--allow-email only makes sense with --gated"
fi
FQDN="${NAME}.${CF_ZONE}"
export DRY_RUN

cf_init
cf_lookup_ids
cf_lock
log "zone ${CF_ZONE} (${ZONE_ID}), tunnel ${CF_TUNNEL} (${TUNNEL_ID})"

# ---- preflight: read everything, refuse before writing anything ----------------------------
recs="$(cf_dns_records "$FQDN")" || die "DNS lookup failed"
foreign="$(jq -c --arg t "$TUNNEL_TARGET" '[.[] | select(.type != "CNAME" or (.content | ascii_downcase) != $t)]' <<<"$recs")"
[[ "$(jq length <<<"$foreign")" == 0 ]] \
  || die "$FQDN already has DNS records not pointing at the tunnel; not touching them: $(jq -c 'map({type,content})' <<<"$foreign")"

rule="$(jq -cn --arg h "$FQDN" --arg s "$EXPOSE_ORIGIN" \
  '{hostname:$h, service:$s, originRequest:{originServerName:$h, noTLSVerify:false}}')"
cfg="$(cf_tunnel_config)"
existing="$(jq -c --arg h "$FQDN" '[.ingress[] | select((.hostname // "" | ascii_downcase) == $h)]' <<<"$cfg")"
others="$(jq -c --arg s "$EXPOSE_ORIGIN" '[.[] | select(.service != $s)]' <<<"$existing")"
if [[ "$(jq length <<<"$others")" -gt 0 && "$REPLACE" != 1 ]]; then
  die "the tunnel already routes $FQDN elsewhere: $(jq -c 'map({service, path})' <<<"$others"). Not taking it over; pass --replace if that is really intended."
fi

if apps="$(cf_access_apps_for "$FQDN")"; then
  cf_split_apps "$apps" "$FQDN"
  if [[ "$(jq length <<<"$OTHER_APPS")" -gt 0 ]]; then
    if [[ "$MODE" == public ]]; then
      die "$FQDN is covered by Access app(s) not managed by this script: $(jq -c 'map(.name)' <<<"$OTHER_APPS"). Not making it public."
    else
      die "$FQDN is already covered by Access app(s) not managed by this script: $(jq -c 'map(.name)' <<<"$OTHER_APPS"). Not touching them."
    fi
  fi
  if [[ "$MODE" == public && "$(jq length <<<"$OUR_APPS")" -gt 0 ]]; then
    die "$FQDN is gated by $(jq -c 'map(.name)' <<<"$OUR_APPS"). To make it public, first run: scripts/unexpose.sh --access-only $NAME"
  fi
else
  [[ "$MODE" == gated ]] && die "listing Access apps failed (token needs Access: Apps and Policies Edit)"
  warn "could not list Access apps (token permission?); cannot confirm $FQDN is not already gated"
  OUR_APPS="[]"
fi

# ---- 1. Access (gated only) -- before the name is routed ---------------------------------------
if [[ "$MODE" == gated ]]; then
  if org="$(cf GET "/accounts/${ACCOUNT_ID}/access/organizations" 2>/dev/null)"; then
    log "Zero Trust org: $(jq -r '.auth_domain // "?"' <<<"$org")"
  else
    warn "could not read the Zero Trust organization (token lacks 'Access: Organizations' read, or Zero Trust"
    warn "was never enabled on this account). If the steps below fail, enable it once at"
    warn "https://one.dash.cloudflare.com (pick a team name and the Free plan: up to 50 users)."
  fi

  idps="$(cf GET "/accounts/${ACCOUNT_ID}/access/identity_providers")" || die "listing identity providers failed; nothing was changed"
  if [[ "$(jq length <<<"$idps")" == 0 ]]; then
    if [[ "$ADD_OTP" == 1 ]]; then
      log "Access: adding the One-time PIN login method"
      cf_write POST "/accounts/${ACCOUNT_ID}/access/identity_providers" '{"type":"onetimepin","name":"One-time PIN","config":{}}' \
        || die "adding One-time PIN failed; the name was NOT routed"
    else
      warn "no identity providers are configured on this account. Unless the account's default login"
      warn "method works for you, allowed users will have no way to sign in. Re-run with --add-otp to add"
      warn "One-time PIN (emailed code), or add a login method under Zero Trust > Settings > Authentication."
    fi
  fi

  pname="$(policy_name "$FQDN")"
  pbody="$(jq -cn --arg n "$pname" '{name:$n, decision:"allow",
            include:[$ARGS.positional[] | {email:{email:.}}], exclude:[], require:[]}' --args "${EMAILS[@]}")"
  pol="$(cf_policy_by_name "$pname")" || die "listing Access policies failed; nothing was changed"
  if [[ "$(jq length <<<"$pol")" == 0 ]]; then
    log "Access: creating policy '$pname' for ${EMAILS[*]}"
    if [[ "$DRY_RUN" == 1 ]]; then cf_write POST "/accounts/${ACCOUNT_ID}/access/policies" "$pbody"; PID="<new-policy-id>"
    else PID="$(cf POST "/accounts/${ACCOUNT_ID}/access/policies" "$pbody" | jq -r '.id')" || die "creating the Access policy failed; the name was NOT routed"
    fi
  else
    PID="$(jq -r '.[0].id' <<<"$pol")"
    log "Access: updating policy '$pname' -> ${EMAILS[*]}"
    cf_write PUT "/accounts/${ACCOUNT_ID}/access/policies/${PID}" "$pbody" || die "updating the Access policy failed"
  fi

  abody="$(jq -cn --arg n "$(app_name "$FQDN")" --arg d "$FQDN" --arg p "$PID" \
    '{type:"self_hosted", name:$n, domain:$d, session_duration:"24h", app_launcher_visible:false,
      policies:[{id:$p, precedence:1}]}')"
  if [[ "$(jq length <<<"$OUR_APPS")" == 0 ]]; then
    log "Access: creating self-hosted app for $FQDN"
    cf_write POST "/accounts/${ACCOUNT_ID}/access/apps" "$abody" \
      || die "creating the Access app failed (is Zero Trust enabled on account ${ACCOUNT_ID}?); the name was NOT routed"
  else
    log "Access: updating app $(jq -r '.[0].id' <<<"$OUR_APPS") for $FQDN"
    cf_write PUT "/accounts/${ACCOUNT_ID}/access/apps/$(jq -r '.[0].id' <<<"$OUR_APPS")" "$abody" \
      || die "updating the Access app failed"
  fi
fi

# ---- 2. tunnel ingress ----------------------------------------------------------------------
if [[ "$(jq length <<<"$existing")" == 1 && "$(jq -cS '.[0]' <<<"$existing")" == "$(jq -cS . <<<"$rule")" ]]; then
  log "tunnel ingress for $FQDN already present"
else
  # Drop any rule(s) for this host (case-insensitive), insert ours just before the catch-all.
  new="$(jq -c --arg h "$FQDN" --argjson r "$rule" \
    '.ingress |= ([.[] | select((.hostname // "" | ascii_downcase) != $h)] | .[:-1] + [$r] + .[-1:])' <<<"$cfg")"
  log "tunnel ingress: $( [[ "$(jq length <<<"$existing")" == 0 ]] && echo adding || echo replacing) $FQDN -> $EXPOSE_ORIGIN"
  cf_put_tunnel_config "$new" || die "updating the tunnel config failed"
fi

# ---- 3. proxied CNAME ------------------------------------------------------------------------
cname="$(jq -c '[.[] | select(.type == "CNAME")]' <<<"$recs")"
if [[ "$(jq length <<<"$cname")" == 0 ]]; then
  log "DNS: creating proxied CNAME $FQDN -> $TUNNEL_TARGET"
  cf_write POST "/zones/${ZONE_ID}/dns_records" "$(jq -cn --arg n "$FQDN" --arg c "$TUNNEL_TARGET" --arg t "$CF_TUNNEL" \
    '{type:"CNAME", name:$n, content:$c, proxied:true, ttl:1, comment:("lab-k3s expose.sh -> tunnel " + $t)}')" \
    || die "creating the CNAME failed"
elif [[ "$(jq -r '.[0].proxied' <<<"$cname")" != true ]]; then
  log "DNS: CNAME exists but is not proxied; enabling proxy"
  cf_write PATCH "/zones/${ZONE_ID}/dns_records/$(jq -r '.[0].id' <<<"$cname")" '{"proxied":true}' || die "enabling proxy failed"
else
  log "DNS: proxied CNAME already present"
fi

# ---- 4. split-horizon record on the UDM ------------------------------------------------------
udm_rc=0
udm_args=(); [[ "$DRY_RUN" == 1 ]] && udm_args+=(-n)
"$SCRIPTS_DIR/udm-dns.sh" "${udm_args[@]}" set "$FQDN" "$LAB_NODE_IP" || udm_rc=$?

# ---- verify + reminder ------------------------------------------------------------------------
if [[ "$DRY_RUN" != 1 ]] && command -v dig >/dev/null; then
  pub=""
  for _ in 1 2 3 4 5; do
    pub="$(dig +short +time=2 +tries=1 A "$FQDN" @1.1.1.1 2>/dev/null | tr '\n' ' ' || true)"
    [[ -n "$pub" ]] && break
    sleep 3
  done
  log "public DNS (1.1.1.1): $FQDN -> ${pub:-no answer yet (may take a minute)}"
fi

cat >&2 <<MSG

Next: the service's Ingress must also list host ${FQDN}; Traefik routes by Host header, so
without it the tunnel gets a 404. The *.${CF_ZONE} wildcard cert is already in Traefik's
default TLSStore, so no secretName is needed:
    tls:   [{hosts: [<name>.lab.${CF_ZONE}, ${FQDN}]}]
    rules: [{host: ${FQDN}, http: ...same paths/backend as the lab host...}]
Then test: curl -sI https://${FQDN}   (LAN: direct to ${LAB_NODE_IP}; elsewhere: via the tunnel)
MSG
[[ "$MODE" == gated ]] && warn "the Access gate applies to traffic through Cloudflare only; LAN clients reach $FQDN directly."
if [[ "$udm_rc" != 0 ]]; then
  warn "Cloudflare side is done, but the UDM record failed (exit $udm_rc): LAN clients will go out"
  warn "through the tunnel until it exists. Fix ~/.config/lab-k3s/udm.env and re-run this command"
  warn "(it is idempotent), or add the record by hand (docs/dns.md)."
  exit "$udm_rc"
fi
