#!/bin/zsh
# Load the Developer ID signing identity and the App Store Connect notary key
# into the `release` environment's secrets, which .github/workflows/release.yml
# reads. Run once on the Mac that holds the certificate, and again whenever the
# certificate or the key is renewed.
#
#   scripts/ci-signing-secrets.sh developer-id.p12 AuthKey_<KEYID>.p8 <KEYID> <ISSUER-UUID>
#
# developer-id.p12: Keychain Access → login → My Certificates → right-click
#   "Developer ID Application: … (7V3HZUL435)" → Export → .p12, with a password.
#   Export that one certificate only; the file carries its private key.
# AuthKey_<KEYID>.p8: an App Store Connect API key with the Developer role
#   (appstoreconnect.apple.com → Users and Access → Integrations); the issuer
#   UUID is on the same page.
set -euo pipefail
if (( $# != 4 )); then
  echo "usage: $0 developer-id.p12 AuthKey_<KEYID>.p8 <KEYID> <ISSUER-UUID>" >&2
  exit 2
fi
p12="$1" p8="$2" key_id="$3" issuer="$4"
repo="lucharo/voice2text"
for file in "$p12" "$p8"; do
  [[ -f "$file" ]] || { echo "not a file: $file" >&2; exit 1; }
done

read -rs "password?Password the .p12 was exported with: "
echo
# Prove the password and the contents before anything is uploaded.
export P12_PASSWORD="$password"  # via the environment, never argv
subjects="$(openssl pkcs12 -in "$p12" -passin env:P12_PASSWORD -nokeys -legacy 2>/dev/null \
  || openssl pkcs12 -in "$p12" -passin env:P12_PASSWORD -nokeys)"
if [[ "$subjects" != *"Developer ID Application"*"7V3HZUL435"* ]]; then
  echo "$p12 does not hold a Developer ID Application certificate for team 7V3HZUL435 (or the password is wrong)." >&2
  exit 1
fi

base64 -i "$p12" | gh secret set DEVELOPER_ID_P12 --env release --repo "$repo"
printf '%s' "$password" | gh secret set DEVELOPER_ID_P12_PASSWORD --env release --repo "$repo"
gh secret set ASC_KEY_P8 --env release --repo "$repo" < "$p8"
printf '%s' "$key_id" | gh secret set ASC_KEY_ID --env release --repo "$repo"
printf '%s' "$issuer" | gh secret set ASC_ISSUER_ID --env release --repo "$repo"
gh secret list --env release --repo "$repo"
