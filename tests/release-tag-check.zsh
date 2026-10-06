#!/bin/zsh
# Exercise the release script's real tag-fetch commands against checkout@v5's
# flattened local tag, without signing or publishing anything.
set -euo pipefail
release_script="${1:-${0:A:h:h}/scripts/release-macos.sh}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q "$scratch/remote"
git -C "$scratch/remote" config user.name 'Release test'
git -C "$scratch/remote" config user.email 'release-test@example.invalid'
tree="$(git -C "$scratch/remote" mktree </dev/null)"
commit="$(git -C "$scratch/remote" commit-tree "$tree" -m fixture)"
git -C "$scratch/remote" -c tag.gpgSign=false tag -a v9.8.7 -m fixture "$commit"
git init -q "$scratch/checkout"
cd "$scratch/checkout"
git remote add origin "$scratch/remote"
git fetch -q origin refs/tags/v9.8.7:refs/tags/v9.8.7
# The Actions checkout overwrites its local annotated tag with the commit.
git update-ref refs/tags/v9.8.7 "$commit"
tag=v9.8.7
fetch_line="$(sed -n '/^    git fetch -q /p' "$release_script")"
resolve_line="$(sed -n '/^    tagged_sha=/p' "$release_script")"
[[ -n "$fetch_line" && -n "$resolve_line" ]]
eval "$fetch_line"$'\n'"$resolve_line"
[[ "$tagged_sha" == "$commit" ]]
[[ "$(git cat-file -t refs/tags/v9.8.7)" == commit ]]
echo 'Release tag check passed: remote commit verified; flattened local tag unchanged.'
