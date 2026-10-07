#!/usr/bin/env bash
# Fallback for scripts/udm-dns.sh when no UniFi API credential exists: write the lab records
# straight into the Network app's `static_dns` collection over SSH (root@UDM), then restart
# the Network app so it re-provisions dnsmasq. Idempotent. Run from the workstation:
#   scripts/udm-dns-mongo.sh            # ensure *.lab + lab -> 192.168.4.243
# The Network app's UI is unavailable for ~1 minute while it restarts; routing/DNS keep working.
set -euo pipefail
UDM="${UDM_SSH:-root@192.168.4.1}"
IP="${LAB_IP:-192.168.4.243}"
ssh -o BatchMode=yes "$UDM" bash -s "$IP" <<'REMOTE'
set -euo pipefail
IP="$1"
mongo --quiet --port 27117 ace --eval "
var site=db.site.findOne({name:'default'})._id.str;
var changed=0;
['*.lab.kleincogroup.com','lab.kleincogroup.com'].forEach(function(k){
  var d=db.static_dns.findOne({key:k});
  if(!d){ db.static_dns.insert({site_id:site,key:k,record_type:'A',value:'$IP',enabled:true,ttl:NumberInt(0)}); changed++; }
  else if(d.value!=='$IP'||!d.enabled){ db.static_dns.update({_id:d._id},{\$set:{value:'$IP',enabled:true}}); changed++; }
});
print('static_dns changed='+changed);
printjson(db.static_dns.find({},{_id:0,site_id:0}).toArray());
" | tee /tmp/static_dns.out
if grep -q 'changed=0' /tmp/static_dns.out && grep -q 'lab.kleincogroup.com' /run/dnsmasq.dns.conf.d/main.conf; then
  echo "already provisioned"; exit 0
fi
echo "restarting the Network app to re-provision dnsmasq ..."
systemctl restart unifi
for _ in $(seq 1 12); do
  grep -q 'lab.kleincogroup.com' /run/dnsmasq.dns.conf.d/main.conf 2>/dev/null && break
  sleep 10
done
grep 'kleincogroup' /run/dnsmasq.dns.conf.d/main.conf || { echo "records not in dnsmasq config yet; check the UniFi app (Settings > Policy Engine > DNS Record)" >&2; exit 1; }
REMOTE
echo "verify:"; dig +short whoami.lab.kleincogroup.com @192.168.4.1
