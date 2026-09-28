#!/bin/zsh
# Renders logo.svg into v2t/native/AppIcon.icns, the menu app's bundle icon.
# The mark sits on the macOS icon grid (an 824 px rounded square on a 1024
# canvas) so Finder and the privacy panes show it without a grey backing tile.
#   assets/logo/app-icon.sh   # needs rsvg-convert (brew install librsvg)
set -euo pipefail
here=${0:A:h}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
inner=$(sed -E 's|^<svg[^>]*>||; s|</svg>$||' "$here/logo.svg")
cat > "$work/icon.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
<g clip-path="url(#tile)"><svg x="100" y="100" width="824" height="824" viewBox="0 0 72 72">$inner</svg></g>
</svg>
EOF
mkdir "$work/AppIcon.iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size -o "$work/AppIcon.iconset/icon_${size}x${size}.png" "$work/icon.svg"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) -o "$work/AppIcon.iconset/icon_${size}x${size}@2x.png" "$work/icon.svg"
done
iconutil -c icns -o "$here/../../v2t/native/AppIcon.icns" "$work/AppIcon.iconset"
