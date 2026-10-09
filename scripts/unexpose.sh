#!/usr/bin/env bash
# Undo scripts/expose.sh for <name>.kleincogroup.com: remove the tunnel ingress rule, the
# CNAME, the UDM split-horizon record, and last the Access app + policy expose.sh created.
#
#   scripts/unexpose.sh [-n] [--access-only] [--force] <name>
#
#   -n             dry run: print the API calls instead of making them
#   --access-only  only remove the Access app/policy (turns a gated service public; the
#                  hostname stays routed)
#   --force        also remove a tunnel rule / CNAME that expose.sh did not create
#                  (by default those are reported and left alone)
#
# Order: the route goes first and the Access gate last, so a failure part-way never leaves a
# routed name without its gate. Idempotent: anything already gone is skipped.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib/cloudflare.sh
. "$(dirname "$0")/lib/cloudflare.sh"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

NAME="" ACCESS_ONLY=0 FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    --access-only) ACCESS_ONLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$NAME" ]] || die "one name only"; NAME="${1,,}" ;;
  esac
  shift
done
[[ -n "$NAME" ]] || usage
NAME="${NAME%."${CF_ZONE}"}"
valid_label "$NAME" || die "'$NAME' must be a single DNS label"
reserved_label "$NAME" && die "'$NAME' is reserved in this zone"
FQDN="${NAME}.${CF_ZONE}"
export DRY_RUN

cf_init
cf_lookup_ids
cf_lock

remove_access() {
  local apps pol id
  apps="$(cf_access_apps_for "$FQDN")" || die "listing Access apps failed"
  cf_split_apps "$apps" "$FQDN"
  for id in $(jq -rn --argjson a "$OUR_APPS" --argjson b "$OUR_BYPASS" '($a + $b)[].id'); do
    log "Access: deleting app $id ($FQDN)"
    cf_write DELETE "/accounts/${ACCOUNT_ID}/access/apps/${id}" || die "deleting Access app $id failed"
  done
  [[ "$(jq length <<<"$OTHER_APPS")" == 0 ]] \
    || warn "left alone (not created by expose.sh, still covering $FQDN): $(jq -c 'map(.name)' <<<"$OTHER_APPS")"
  pol="$(cf_policy_by_name "$(policy_name "$FQDN")")" || die "listing Access policies failed"
  for id in $(jq -r '.[].id' <<<"$pol"); do
    log "Access: deleting policy $id"
    cf_write DELETE "/accounts/${ACCOUNT_ID}/access/policies/${id}" || die "deleting Access policy $id failed"
  done
  if [[ "$(jq length <<<"$OUR_APPS")" == 0 && "$(jq length <<<"$OUR_BYPASS")" == 0 && "$(jq length <<<"$pol")" == 0 ]]; then log "Access: nothing to remove"; fi
}

if [[ "$ACCESS_ONLY" == 1 ]]; then
  remove_access
  log "--access-only: $FQDN stays routed and is now public"
  exit 0
fi

# ---- tunnel ingress ----------------------------------------------------------------------------
cfg="$(cf_tunnel_config)"
match="$(jq -c --arg h "$FQDN" '[.ingress[] | select((.hostname // "" | ascii_downcase) == $h)]' <<<"$cfg")"
# Rules expose.sh writes carry originServerName == the hostname.
foreign_rules="$(jq -c --arg h "$FQDN" '[.[] | select((.originRequest.originServerName // "" | ascii_downcase) != $h)]' <<<"$match")"
if [[ "$(jq length <<<"$match")" == 0 ]]; then
  log "tunnel ingress: no rule for $FQDN"
elif [[ "$(jq length <<<"$foreign_rules")" -gt 0 && "$FORCE" != 1 ]]; then
  die "tunnel rule(s) for $FQDN were not created by expose.sh: $(jq -c 'map({service})' <<<"$foreign_rules"). Nothing changed; pass --force to remove anyway."
else
  log "tunnel ingress: removing $FQDN"
  cf_put_tunnel_config "$(jq -c --arg h "$FQDN" '.ingress |= [.[] | select((.hostname // "" | ascii_downcase) != $h)]' <<<"$cfg")" \
    || die "updating the tunnel config failed"
fi

# ---- DNS -----------------------------------------------------------------------------------------
recs="$(cf_dns_records "$FQDN")" || die "DNS lookup failed"
tunnel_cnames="$(jq -c --arg t "$TUNNEL_TARGET" '[.[] | select(.type == "CNAME" and (.content | ascii_downcase) == $t)]' <<<"$recs")"
ours="$(jq -c '[.[] | select((.comment // "") | startswith("lab-k3s expose.sh"))]' <<<"$tunnel_cnames")"
[[ "$FORCE" == 1 ]] && ours="$tunnel_cnames"
for id in $(jq -r '.[].id' <<<"$ours"); do
  log "DNS: deleting CNAME $FQDN -> $TUNNEL_TARGET"
  cf_write DELETE "/zones/${ZONE_ID}/dns_records/${id}" || die "deleting the CNAME failed"
done
[[ "$(jq length <<<"$tunnel_cnames")" == 0 ]] && log "DNS: no tunnel CNAME for $FQDN"
other="$(jq -c --argjson o "$ours" '[.[] | select(.id as $i | ($o | map(.id) | index($i)) | not) | {type,content,comment}]' <<<"$recs")"
[[ "$(jq length <<<"$other")" == 0 ]] || warn "left alone (not created by expose.sh; --force removes a tunnel CNAME): $other"

# ---- UDM (only the record expose.sh sets: -> LAB_NODE_IP) ------------------------------------
udm_args=(); [[ "$DRY_RUN" == 1 ]] && udm_args+=(-n)
if ! "$SCRIPTS_DIR/udm-dns.sh" "${udm_args[@]}" rm "$FQDN" "$LAB_NODE_IP"; then
  warn "the UDM record could not be removed; LAN clients still resolve $FQDN to ${LAB_NODE_IP}."
  warn "Fix ~/.config/lab-k3s/udm.env and run: scripts/udm-dns.sh rm $FQDN $LAB_NODE_IP"
  udm_failed=1
fi

# ---- Access, last --------------------------------------------------------------------------------
remove_access

[[ "${udm_failed:-0}" == 0 ]] || exit 1
log "done. Also drop host $FQDN from the service's Ingress."
