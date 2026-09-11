#!/bin/zsh
# Build, sign, notarise and staple a distributable Voice2Text menu-app release.
#
#   scripts/release-macos.sh [--skip-notarize] [--publish]
#
# Produces build/release/Voice2Text-<version>.zip: the Developer ID-signed,
# notarised, stapled Voice2Text.app for other Macs. The engine is not inside;
# the shell runs the `uv tool install voice2text` interpreter of whoever
# launches it, so a managed Mac with no signing identity can still run it.
#
# The identity is auto-detected from the login keychain and can be pinned:
#   V2T_SIGNING_IDENTITY   "Developer ID Application: ..."
# --publish needs a clean checkout and a notarised build; it tags HEAD as
# v<version> (or requires the existing tag to be HEAD), uploads the zip to that
# GitHub Release, and rewrites Casks/voice2text.rb so `brew install --cask
# voice2text` serves it. Notarisation uses one of:
#   NOTARY_PROFILE               keychain profile from `xcrun notarytool store-credentials`
#                                (default: lucharo)
#   ASC_KEY_PATH + ASC_KEY_ID + ASC_ISSUER_ID   App Store Connect API key
set -euo pipefail
setopt nullglob

repo_root="${0:A:h:h}"
app_name="Voice2Text"
app_dir="$repo_root/build/$app_name.app"
release_dir="$repo_root/build/release"
skip_notarize=false
publish=false
gh_repo="lucharo/voice2text"
cask_token="voice2text"
team_id="7V3HZUL435"

for arg in "$@"; do
  case "$arg" in
    --skip-notarize) skip_notarize=true ;;
    --publish) publish=true ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

cd "$repo_root"

if [[ "$publish" == true ]]; then
  if [[ "$skip_notarize" == true ]]; then
    echo "--publish needs a notarised Developer ID build; drop --skip-notarize." >&2
    exit 2
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "--publish needs a clean checkout so the release tag matches the built source." >&2
    exit 2
  fi
  built_sha="$(git rev-parse HEAD)"
fi

version="$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml | head -n 1)"
if [[ -z "$version" ]]; then
  echo "Could not read version from pyproject.toml." >&2
  exit 1
fi

# Only a Developer ID identity from this team: Gatekeeper on other Macs rejects
# everything else, and a managed Mac shows any other publisher as "Not signed".
identities="$(security find-identity -v -p codesigning 2>/dev/null | grep "($team_id)" || true)"
app_identity="${V2T_SIGNING_IDENTITY:-$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)}"
if [[ "$app_identity" != Developer\ ID\ Application:*"($team_id)"* ]]; then
  echo "No 'Developer ID Application' identity for team $team_id in the keychain. Create one at" >&2
  echo "https://developer.apple.com/account/resources/certificates (see README, Optional menu-bar app)." >&2
  exit 1
fi

notary_args=()
if [[ "$skip_notarize" == false ]]; then
  if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    notary_args=(--key "$ASC_KEY_PATH" --key-id "${ASC_KEY_ID:?ASC_KEY_ID is required with ASC_KEY_PATH}" --issuer "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required with ASC_KEY_PATH}")
  else
    notary_args=(--keychain-profile "${NOTARY_PROFILE:-lucharo}")
  fi
fi

notarize() {
  local artifact="$1"
  local staple_target="${2:-$1}"
  if [[ "$skip_notarize" == true ]]; then
    echo "Skipping notarisation for ${artifact:t}"
    return 0
  fi
  echo "Notarising ${artifact:t} ..."
  local log="$release_dir/${artifact:t}.notary.json"
  if ! xcrun notarytool submit "$artifact" "${notary_args[@]}" --wait --output-format json > "$log"; then
    echo "Notarisation failed; see $log" >&2
    exit 1
  fi
  if ! grep -q '"status" *: *"Accepted"' "$log"; then
    local id
    id="$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$log" | head -n 1)"
    echo "Notarisation was not accepted (see $log). Fetch the log with:" >&2
    echo "  xcrun notarytool log $id ${notary_args[*]}" >&2
    exit 1
  fi
  xcrun stapler staple "$staple_target"
}

# 1. Portable bundle: no baked user paths, Developer ID, hardened runtime,
#    audio-input entitlement, secure timestamp (`v2t menubar build`).
mkdir -p "$release_dir"
/bin/rm -f -- "$release_dir/$app_name-$version".zip "$release_dir"/*.notary.json
uv run v2t menubar build "$app_dir" --identity "$app_identity"
built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
if [[ "$built_version" != "$version" ]]; then
  echo "pyproject.toml says $version but the bundle says $built_version; run 'uv sync' so the installed package matches." >&2
  exit 1
fi
for key in V2THome V2TPythonExecutable V2TConfig; do
  if /usr/libexec/PlistBuddy -c "Print :$key" "$app_dir/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Info.plist bakes $key; a release bundle must carry no user paths." >&2
    exit 1
  fi
done

# 2. Notarise the app (submitted as a zip), staple the ticket into the bundle,
#    then zip the stapled bundle: that zip is the release asset.
submission="$release_dir/$app_name-$version-submission.zip"
ditto -c -k --keepParent "$app_dir" "$submission"
notarize "$submission" "$app_dir"
/bin/rm -f -- "$submission"
final_zip="$release_dir/$app_name-$version.zip"
ditto -c -k --keepParent "$app_dir" "$final_zip"

# 3. Verification: every check prints its verdict; a failure stops the release.
echo "--- verification"
codesign --verify --deep --strict --verbose=2 "$app_dir"
codesign -dvv "$app_dir" 2>&1 | grep -E '^(Authority=|TeamIdentifier=|Timestamp=)' | head -n 4
entitlements="$(codesign -d --entitlements - "$app_dir" 2>/dev/null || true)"
if [[ "$entitlements" != *com.apple.security.device.audio-input* ]]; then
  echo "The bundle lacks the audio-input entitlement; the hardened runtime would block the microphone." >&2
  exit 1
fi
if [[ "$skip_notarize" == false ]]; then
  spctl -a -vv -t exec "$app_dir"
  xcrun stapler validate "$app_dir"
else
  echo "spctl assessment skipped: unnotarised builds are rejected by Gatekeeper on other Macs."
fi
# The zip must round-trip the stapled bundle byte for byte.
unpacked="$(mktemp -d)"
ditto -x -k "$final_zip" "$unpacked"
codesign --verify --deep --strict "$unpacked/$app_name.app"
if [[ "$skip_notarize" == false ]]; then
  xcrun stapler validate "$unpacked/$app_name.app"
fi
/bin/rm -rf -- "$unpacked"

# 4. Optional publish: GitHub Release plus the Homebrew cask in this repo.
update_cask() {
  local cask="$1" new_version="$2" sha="$3"
  sed -i '' \
    -e "s/^  version \".*\"/  version \"$new_version\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" \
    "$cask"
  if ! grep -q "version \"$new_version\"" "$cask" || ! grep -q "sha256 \"$sha\"" "$cask"; then
    echo "Rewriting $cask failed; its version and sha256 lines did not take." >&2
    return 1
  fi
}

if [[ "$publish" == true ]]; then
  tag="v$version"
  head_sha="$(git rev-parse HEAD)"
  if [[ "$head_sha" != "$built_sha" || -n "$(git status --porcelain)" ]]; then
    echo "The checkout changed during the build (built ${built_sha:0:12}, now ${head_sha:0:12}); not publishing." >&2
    exit 1
  fi
  if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    git fetch -q origin "refs/tags/$tag:refs/tags/$tag"
    tagged_sha="$(git rev-list -n 1 "$tag")"
    if [[ "$tagged_sha" != "$head_sha" ]]; then
      echo "Tag $tag already points at ${tagged_sha:0:12}, not HEAD ${head_sha:0:12}. Bump the version in pyproject.toml for a new release." >&2
      exit 1
    fi
  else
    git tag -a "$tag" -m "voice2text $version" "$head_sha"
    if ! git push -q origin "refs/tags/$tag"; then
      git tag -d "$tag" >/dev/null
      echo "Could not push tag $tag; local tag removed so a retry starts clean." >&2
      exit 1
    fi
  fi
  if ! gh release view "$tag" --repo "$gh_repo" >/dev/null 2>&1; then
    # Release notes are this version's CHANGELOG section, when there is one.
    notes="$release_dir/$tag.notes.md"
    sed -n "/^## $version\$/,/^## /p" CHANGELOG.md | sed '1d;$d' > "$notes"
    if [[ ! -s "$notes" ]]; then
      echo "Release $version of voice2text." > "$notes"
    fi
    printf '\n---\n\nNotarised Developer ID build of %s. Install the menu app with `brew install --cask %s` (see README) and the engine with `uv tool install voice2text==%s`.\n' "$head_sha" "$cask_token" "$version" >> "$notes"
    gh release create "$tag" --repo "$gh_repo" --verify-tag --title "voice2text $version" --notes-file "$notes"
  fi
  # The tag is proven to be HEAD, so replacing the asset only ever rebuilds the same source.
  gh release upload "$tag" "$final_zip" --repo "$gh_repo" --clobber
  zip_sha="$(shasum -a 256 "$final_zip" | awk '{ print $1 }')"
  update_cask "Casks/$cask_token.rb" "$version" "$zip_sha"
  echo "Published $tag; Casks/$cask_token.rb now points at it. Commit it, then:"
  echo "  brew trust --tap lucharo/$cask_token && brew trust --cask lucharo/$cask_token/$cask_token"
  echo "  brew tap lucharo/$cask_token https://github.com/$gh_repo.git && brew install --cask $cask_token"
fi

echo "--- artifacts"
ls -1 "$release_dir/$app_name-$version".*
