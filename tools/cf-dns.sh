#!/usr/bin/env bash
# Point conch-labs.com at GitHub Pages: drop every record that is not needed,
# create the five that are. Idempotent — safe to re-run.
#
# Auth: set ONE of these in your shell, never on the command line.
#   scoped token (Zone:DNS:Edit on this zone only):
#       export CLOUDFLARE_API_TOKEN=...
#   or the global key:
#       export CLOUDFLARE_EMAIL=...  CLOUDFLARE_API_KEY=...
#
# Usage:  bash tools/cf-dns.sh            # show what it would do
#         bash tools/cf-dns.sh --apply    # do it
set -euo pipefail

ZONE_NAME="conch-labs.com"
API="https://api.cloudflare.com/client/v4"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  AUTH=(-H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}")
elif [ -n "${CLOUDFLARE_API_KEY:-}" ] && [ -n "${CLOUDFLARE_EMAIL:-}" ]; then
  AUTH=(-H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}")
else
  echo "no credentials in the environment — set CLOUDFLARE_API_TOKEN, or CLOUDFLARE_EMAIL + CLOUDFLARE_API_KEY" >&2
  exit 1
fi

api() { curl -sS "${AUTH[@]}" -H "Content-Type: application/json" "$@"; }

ZONE_ID=$(api "$API/zones?name=$ZONE_NAME" | python -c 'import json,sys; r=json.load(sys.stdin); print(r["result"][0]["id"] if r.get("result") else "")')
[ -n "$ZONE_ID" ] || { echo "zone $ZONE_NAME not found on this account" >&2; exit 1; }
echo "zone $ZONE_NAME -> $ZONE_ID"

# what the zone must end up holding: GitHub Pages apex + www, proxy OFF so
# GitHub can issue the certificate.
WANT="
A|$ZONE_NAME|185.199.108.153
A|$ZONE_NAME|185.199.109.153
A|$ZONE_NAME|185.199.110.153
A|$ZONE_NAME|185.199.111.153
CNAME|www.$ZONE_NAME|nikitaeight24family.github.io
"

echo
echo "--- existing ---"
api "$API/zones/$ZONE_ID/dns_records?per_page=200" > /tmp/cf_recs.json
python - "$APPLY" <<'PY' > /tmp/cf_plan.txt
import json, sys, os
apply = sys.argv[1] == "1"
zone = os.environ.get("ZONE_NAME", "conch-labs.com")
want = {
    ("A", zone, "185.199.108.153"),
    ("A", zone, "185.199.109.153"),
    ("A", zone, "185.199.110.153"),
    ("A", zone, "185.199.111.153"),
    ("CNAME", "www." + zone, "nikitaeight24family.github.io"),
}
recs = json.load(open("/tmp/cf_recs.json"))["result"]
have = set()
for r in recs:
    key = (r["type"], r["name"], r["content"])
    proxied_wrong = r.get("proxied") is True
    if key in want and not proxied_wrong:
        have.add(key)
        print("KEEP   %s %s -> %s" % key)
    else:
        why = "proxied" if key in want and proxied_wrong else "not needed"
        print("DELETE %s %s -> %s   (%s)" % (key + (why,)))
        print("::del::" + r["id"])
for k in sorted(want - have):
    print("CREATE %s %s -> %s" % k)
    print("::add::" + json.dumps({"type": k[0], "name": k[1], "content": k[2],
                                  "ttl": 1, "proxied": False}))
PY
grep -v '^::' /tmp/cf_plan.txt || true

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "dry run — re-run with --apply to make these changes"
  exit 0
fi

echo
while IFS= read -r line; do
  case "$line" in
    ::del::*) id="${line#::del::}"
              api -X DELETE "$API/zones/$ZONE_ID/dns_records/$id" >/dev/null && echo "deleted $id" ;;
    ::add::*) body="${line#::add::}"
              api -X POST "$API/zones/$ZONE_ID/dns_records" --data "$body" \
                | python -c 'import json,sys; r=json.load(sys.stdin); print("created", r["result"]["type"], r["result"]["name"], "->", r["result"]["content"]) if r.get("success") else print("FAILED", r.get("errors"))' ;;
  esac
done < /tmp/cf_plan.txt

echo
echo "--- zone now holds ---"
api "$API/zones/$ZONE_ID/dns_records?per_page=200" \
  | python -c 'import json,sys
for r in json.load(sys.stdin)["result"]:
    print("  %-6s %-28s %-34s proxied=%s" % (r["type"], r["name"], r["content"], r.get("proxied")))'
rm -f /tmp/cf_recs.json /tmp/cf_plan.txt
