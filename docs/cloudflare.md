# Cloudflare: publishing a service to the Internet

Lab services are LAN-only by default (`<name>.lab.kleincogroup.com`, see [dns.md](dns.md)).
To publish one, run `scripts/expose.sh`. It routes `https://<name>.kleincogroup.com` through
the existing Cloudflare Tunnel `homelab`, which runs as the `cloudflared` systemd service on
notatonix. Nothing on the router is opened.

```
scripts/expose.sh   <name> --public
scripts/expose.sh   <name> --gated --allow-email you@example.com [--allow-email ...] [--add-otp]
                    [--idp google] [--session-duration 730h]   # login method(s), session length (max 1 month)
scripts/unexpose.sh <name>                 # remove all of it
scripts/unexpose.sh --access-only <name>   # drop the Access gate; the name stays published
# -n on any of them: dry run. Reads still happen; writes are printed instead of sent.
```

You must pick `--public` or `--gated` every time. There is no default.

## What `expose.sh` does

Every step is idempotent. Re-running converges to the same state and never duplicates.
Runs on this host are serialized with a `flock`, because each one reads, modifies and
writes back the whole tunnel config.

**Preflight.** Before writing anything, the script looks up the IDs: zone
`kleincogroup.com`, its account, and tunnel `homelab`. They are never hardcoded; override
them with `CF_ZONE` and `CF_TUNNEL`. It then refuses to continue if the name belongs to
something else:

- the name has a DNS record other than a CNAME to this tunnel;
- the tunnel already routes the name to a **different origin** (a non-cluster service on
  the same host), unless you pass `--replace`;
- an Access app it didn't create covers the name. That includes apps matched by `domain`,
  `self_hosted_domains` or `destinations[].uri`, and wildcard apps like `*.kleincogroup.com`;
- the name is reserved by policy: `home` is the UDM's DDNS record, `lab` is the internal
  domain, and `www` and `mail` are kept free.

Then, in this order:

1. **Access** (`--gated` only, see below). This runs *before* the name is routed. If
   Access setup fails, nothing is published.
2. **Tunnel ingress.** Inserts this rule just before the final `http_status:404`
   catch-all:
   ```json
   {"hostname": "<name>.kleincogroup.com", "service": "https://localhost:443",
    "originRequest": {"originServerName": "<name>.kleincogroup.com", "noTLSVerify": false}}
   ```
   It then PUTs the **whole** `config` object back. The PUT replaces everything, including
   `ingress`, `originRequest` and `warp-routing`, so a partial object would wipe the other
   rules. The script refuses to write if the last rule would not be a catch-all.
   cloudflared connects to Traefik on the node with TLS and SNI `<name>.kleincogroup.com`.
   Traefik presents the `*.kleincogroup.com` wildcard, so the certificate is verified
   end to end (`noTLSVerify: false`). Set `EXPOSE_ORIGIN` to change the origin URL.
3. **DNS.** Creates a proxied CNAME `<name>.kleincogroup.com →
   <tunnel-id>.cfargotunnel.com` with the comment `lab-k3s expose.sh -> tunnel homelab`.
   `unexpose.sh` uses that comment to recognise its own records.
4. **LAN shortcut.** Runs `scripts/udm-dns.sh set <name>.kleincogroup.com 192.168.4.243`,
   so LAN clients skip the tunnel (split horizon). If this step fails, for example because
   `udm.env` is missing, the Cloudflare side is already done: the script says so and exits
   non-zero. Re-run it after fixing the credentials.
5. **Reminder.** Prints that **the service's Ingress must also list the host
   `<name>.kleincogroup.com`**. Traefik routes by Host header, so without it the tunnel
   gets a 404. The `*.kleincogroup.com` cert is already in Traefik's default TLSStore, so no
   `secretName` is needed:

   ```yaml
   spec:
     ingressClassName: traefik
     tls:
       - hosts: [foo.lab.kleincogroup.com, foo.kleincogroup.com]
     rules:
       - host: foo.lab.kleincogroup.com
         http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: foo, port: {number: 80}}}}]}
       - host: foo.kleincogroup.com
         http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: foo, port: {number: 80}}}}]}
   ```

`unexpose.sh` reverses this, removing the route first and the gate last, so a failure
partway through never leaves a routed name ungated:

1. Removes the ingress rule (PUTting the whole config back).
2. Deletes the CNAME.
3. Removes the UDM record, but only if it points at 192.168.4.243 (`udm-dns.sh rm <fqdn>
   192.168.4.243`).
4. Deletes the Access app `lab-k3s <name>` and the policy `lab-k3s allow <fqdn>`.

It only removes what `expose.sh` created: an ingress rule whose `originServerName` is the
hostname, and a CNAME carrying the comment. Anything else is reported and left alone;
`--force` removes a foreign tunnel rule or CNAME. Access apps that the script didn't
create are never deleted. Anything already gone is skipped.

## The one-label limit

The zone is on the Free plan. Its **Universal SSL** certificate covers `kleincogroup.com` and
`*.kleincogroup.com` only. A wildcard covers exactly one label, so
`foo.kleincogroup.com` is covered but `foo.lab.kleincogroup.com` is not. A proxied name two
levels deep would fail the TLS handshake at Cloudflare's edge. Fixing that would take
Advanced Certificate Manager (paid) or a custom certificate. So public names are always
`<name>.kleincogroup.com`. The script accepts only a single label, and the internal
`*.lab` names never go through Cloudflare's proxy.

## Access gating (`--gated`)

`--gated` puts Cloudflare Access (Zero Trust) in front of the hostname. A visitor coming
through Cloudflare must sign in, and only the listed emails are allowed.

**The gate only applies to traffic that comes through Cloudflare.** On the LAN, the UDM
answers `<name>.kleincogroup.com` with 192.168.4.243, so every LAN and VLAN client,
on any VLAN that can route to the host, goes straight to Traefik and never sees Access. The same service is also
reachable on its `<name>.lab.kleincogroup.com` name. If the app needs authentication
against LAN clients too, it has to do that itself.

- Creates or updates a **reusable Access policy** named `lab-k3s allow <fqdn>`:
  `POST/PUT /accounts/{account}/access/policies` with
  `{"decision":"allow","include":[{"email":{"email":"..."}}, ...]}`.
  Re-running with a different `--allow-email` list replaces the list.
- Creates or updates a **self-hosted Access application** `lab-k3s <name>` for the
  hostname: `POST/PUT /accounts/{account}/access/apps` with `type: self_hosted`,
  `session_duration: 24h`, and `policies: [{id, precedence: 1}]`.
- **Login method.** An allowed email still needs a way to prove who it is. If the account
  has no identity providers, the script warns. Re-run with `--add-otp` to add **One-time
  PIN** (`type: onetimepin`; Cloudflare emails a code), or add a provider (e.g. Google) in
  the Zero Trust dashboard under Settings → Authentication. On 2026-10-07 this account had
  **zero** identity providers. Cloudflare's docs say new Zero Trust orgs default to a
  "Cloudflare identity provider" and no longer add OTP automatically.
- **Zero Trust must be enabled on the account once**, at <https://one.dash.cloudflare.com>:
  choose a team name and the **Free** plan, which covers up to 50 users. Cloudflare may ask
  for a payment method even on the free plan. The script tries to read the Access
  organization first. If it can't, it warns: either Zero Trust isn't enabled or the token
  can't read organizations. If creating the app then fails, the script stops *before*
  routing the name: nothing is published. Enable Zero Trust and re-run.

Going from gated to public is deliberately two steps:
`unexpose.sh --access-only <name>`, then `expose.sh <name> --public`. `expose.sh --public`
refuses while an Access app still covers the hostname, so a typo can't silently un-gate a
service.

## API token

Read from `CLOUDFLARE_API_TOKEN` or `~/.config/cloudflare/api-token`. It is never
printed, and curl reads it from a 0600 temp file, so it is never in `ps` either. Needed
permissions:

| permission | for |
|------------|-----|
| Account · Cloudflare Tunnel · Edit | ingress config |
| Zone · DNS · Edit (kleincogroup.com) | CNAME (cert-manager's DNS-01 uses the same token) |
| Zone · Zone · Read | zone lookup |
| Account · Access: Apps and Policies · Edit | `--gated`, and `unexpose.sh` cleanup |
| Account · Access: Organizations, Identity Providers, and Groups · Edit | `--add-otp`; reading the org (optional) |

Verified read-only on 2026-10-07 with the current token: zone, tunnel and tunnel-config
reads work, and so do reads of the Access apps, reusable policies and identity providers
lists. Reading `access/organizations` and `access/groups` returns "Authentication error"
(code 10000), so the token lacks the Organizations/Groups permission or Zero Trust isn't
enabled. Write permissions were not exercised. Nothing was changed in Cloudflare while
writing these scripts.

## Checking state by hand

```
H=$(umask 077; mktemp); printf 'Authorization: Bearer %s\n' "$(cat ~/.config/cloudflare/api-token)" > "$H"
A=https://api.cloudflare.com/client/v4
ACC=$(curl -s -H @"$H" "$A/zones?name=kleincogroup.com" | jq -r '.result[0].account.id')
TID=$(curl -s -H @"$H" "$A/accounts/$ACC/cfd_tunnel?name=homelab&is_deleted=false" | jq -r '.result[0].id')
curl -s -H @"$H" "$A/accounts/$ACC/cfd_tunnel/$TID/configurations" | jq '.result.config.ingress'
rm -f "$H"
dig +short <name>.kleincogroup.com @1.1.1.1          # Cloudflare edge IPs
curl -sI https://<name>.kleincogroup.com             # 200, or a redirect to the Access login if gated
```

If a fresh name doesn't resolve, the local resolver may have cached an earlier NXDOMAIN.
Check with `dig @1.1.1.1`.

## Not verified yet

- The origin `https://localhost:443`. k3s wasn't installed when this was written. Traefik is
  published by ServiceLB (klipper) on the node's ports 80/443, and connections from
  cloudflared to *localhost* depend on how that port mapping treats loopback. If the tunnel
  answers 502, re-run with `EXPOSE_ORIGIN=https://192.168.4.243:443` (the node IP). The
  SNI/`originServerName` stays the same.
- Creating the Access app/policy, and `--add-otp`. The request bodies follow Cloudflare's
  API reference. They were checked with `-n`, never sent.
