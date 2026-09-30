kc config credentials --server http://localhost:8080 --realm master --user admin --password admin
kc create realms -s realm=lab -s enabled=true

# อนุญาต attribute นอก user profile (tenant_id, plan)
$up = kc get users/profile -r lab | ConvertFrom-Json
$up | Add-Member -NotePropertyName unmanagedAttributePolicy -NotePropertyValue ENABLED -Force
$up | ConvertTo-Json -Depth 50 | kc update users/profile -r lab -f -

# client ของ App (lab: public + password grant)
kc create clients -r lab -s clientId=lab-app -s publicClient=true -s directAccessGrantsEnabled=true
$CID = (kc get clients -r lab -q clientId=lab-app --fields id --format csv --noquotes | Select-Object -First 1).Trim()
foreach ($a in 'tenant_id', 'plan') {
  kc create "clients/$CID/protocol-mappers/models" -r lab -s "name=$a" -s protocol=openid-connect `
    -s protocolMapper=oidc-usermodel-attribute-mapper -s "config.`"user.attribute`"=$a" `
    -s "config.`"claim.name`"=$a" -s 'config."access.token.claim"=true' -s 'config."jsonType.label"=String'
}

# users: alice = tenant-a / pro · bob = tenant-b / free
function mkuser($u, $tenant, $plan) {
  kc create users -r lab -s "username=$u" -s enabled=true -s "email=$u@lab.local" -s emailVerified=true `
    -s "firstName=$u" -s lastName=lab -s "attributes.tenant_id=[`"$tenant`"]" -s "attributes.plan=[`"$plan`"]"
  kc set-password -r lab --username $u --new-password $u
}
mkuser alice tenant-a pro
mkuser bob tenant-b free