#!/usr/bin/env bash
# file: tests/create_realm.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"
# shellcheck source=./lab.sh
source "$HERE/lab.sh"          # provides kc()

kc config credentials --server http://localhost:8080 --realm master --user admin --password admin
kc create realms -s realm=lab -s enabled=true

# allow attributes outside the user profile (tenant_id, plan)
kc get users/profile -r lab \
  | jq '.unmanagedAttributePolicy = "ENABLED"' \
  | kc update users/profile -r lab -f -

# App client (lab: public + password grant)
kc create clients -r lab -s clientId=lab-app -s publicClient=true -s directAccessGrantsEnabled=true
CID="$(kc get clients -r lab -q clientId=lab-app --fields id --format csv --noquotes \
  | head -1 | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

for a in tenant_id plan; do
  kc create "clients/$CID/protocol-mappers/models" -r lab \
    -s "name=$a" -s protocol=openid-connect \
    -s protocolMapper=oidc-usermodel-attribute-mapper \
    -s "config.\"user.attribute\"=$a" \
    -s "config.\"claim.name\"=$a" \
    -s 'config."access.token.claim"=true' \
    -s 'config."jsonType.label"=String'
done

# users: alice = tenant-a / pro · bob = tenant-b / free
mkuser() { # $1 = username, $2 = tenant, $3 = plan
  kc create users -r lab -s "username=$1" -s enabled=true -s "email=$1@lab.local" \
    -s emailVerified=true -s "firstName=$1" -s lastName=lab \
    -s "attributes.tenant_id=[\"$2\"]" -s "attributes.plan=[\"$3\"]"
  kc set-password -r lab --username "$1" --new-password "$1"
}
mkuser alice tenant-a pro
mkuser bob   tenant-b free
