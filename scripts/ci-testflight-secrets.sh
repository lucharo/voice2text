#!/bin/zsh
# Load the Apple Distribution signing identity from the login keychain and the
# App Store Connect key from ~/.appstoreconnect into the `testflight`
# environment's secrets, which .github/workflows/testflight.yml reads. Run once
# on the Mac that holds the certificate, and again whenever the certificate or
# a key is renewed. macOS asks for the login password once per certificate in
# the keychain.
#
# appstore.yml needs a second key whose role can create an App Store version
# (App Manager or Admin; the upload key's cannot, #132). Name it to load it too:
#   RELEASE_KEY_ID=<key id> scripts/ci-testflight-secrets.sh
# It reads ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8, from the same
# issuer, into ASC_RELEASE_KEY_ID and ASC_RELEASE_KEY_P8.
set -euo pipefail
repo="lucharo/voice2text"
identity="Apple Distribution: Luis Chaves Rodriguez (7V3HZUL435)"
keychain="login.keychain-db"
key_id="AZ756K8XB6"
p8="$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8"
issuer_file="$HOME/.appstoreconnect/issuer_id"
release_key_id="${RELEASE_KEY_ID:-}"
release_p8="$HOME/.appstoreconnect/private_keys/AuthKey_$release_key_id.p8"

if [[ -n "$release_key_id" && ! -f "$release_p8" ]]; then
  echo "no $release_p8 for RELEASE_KEY_ID=$release_key_id" >&2; exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export P12_PASSWORD="$(openssl rand -base64 24)"  # protects the file in transit; nobody types it

# LibreSSL has no -legacy; OpenSSL 3 needs it to read what `security export` writes.
pem() {
  openssl pkcs12 -in "$work/all.p12" -passin env:P12_PASSWORD -legacy "$@" 2>/dev/null \
    || openssl pkcs12 -in "$work/all.p12" -passin env:P12_PASSWORD "$@"
}

# Print the PEM blocks of $2 whose bag attributes contain $1.
blocks() {
  awk -v id="$1" '
    /^Bag Attributes/ { keep = 0 }
    index($0, id) { keep = 1 }
    keep && /-----BEGIN/ { body = 1 }
    keep && body { print }
    /-----END/ { body = 0 }
  ' "$2"
}

# `security export` takes every identity in a keychain, so pick out the one CI needs:
# a Developer ID key has no business in this environment.
security export -k "$keychain" -t identities -f pkcs12 -P "$P12_PASSWORD" -o "$work/all.p12"
pem -nokeys -clcerts > "$work/certs.pem"
pem -nocerts -nodes > "$work/keys.pem"
# After a renewal the old certificate has the same name, and it would be picked just as readily.
matches="$(grep -cF "friendlyName: $identity" "$work/certs.pem" || true)"
(( matches == 1 )) || { echo "$matches certificates named \"$identity\": delete the old one from the keychain" >&2; exit 1; }
local_key="$(awk -v name="friendlyName: $identity" '
  /friendlyName/ { hit = index($0, name) }
  hit && /localKeyID/ { sub(/^ *localKeyID: */, ""); print; exit }
' "$work/certs.pem")"
[[ -n "$local_key" ]] || { echo "no \"$identity\" in the keychain" >&2; exit 1; }
blocks "$local_key" "$work/certs.pem" > "$work/cert.pem"
blocks "$local_key" "$work/keys.pem" > "$work/key.pem"
# 3DES and SHA-1: `security import` on the runner refuses OpenSSL 3's newer defaults.
openssl pkcs12 -export -in "$work/cert.pem" -inkey "$work/key.pem" -name "$identity" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -passout env:P12_PASSWORD -out "$work/one.p12"

base64 -i "$work/one.p12" | gh secret set APPLE_DISTRIBUTION_P12 --env testflight --repo "$repo"
printf '%s' "$P12_PASSWORD" | gh secret set APPLE_DISTRIBUTION_P12_PASSWORD --env testflight --repo "$repo"
gh secret set ASC_KEY_P8 --env testflight --repo "$repo" < "$p8"
printf '%s' "$key_id" | gh secret set ASC_KEY_ID --env testflight --repo "$repo"
gh secret set ASC_ISSUER_ID --env testflight --repo "$repo" < "$issuer_file"
if [[ -n "$release_key_id" ]]; then
  gh secret set ASC_RELEASE_KEY_P8 --env testflight --repo "$repo" < "$release_p8"
  printf '%s' "$release_key_id" | gh secret set ASC_RELEASE_KEY_ID --env testflight --repo "$repo"
else
  echo "RELEASE_KEY_ID not set: ASC_RELEASE_KEY_ID and ASC_RELEASE_KEY_P8 left as they are (appstore.yml needs them)" >&2
fi
gh secret list --env testflight --repo "$repo"
