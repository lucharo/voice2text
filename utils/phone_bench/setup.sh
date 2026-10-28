#!/bin/bash
# Fetch the pinned ANEMLL sources, generate the Xcode project, and (with `build`) build the app for a device.
#   ./setup.sh          fetch + generate
#   ./setup.sh build    fetch + generate + Release build into build/
# Env: V2T_TEAM (Apple development team for signing).
set -euo pipefail
cd "$(dirname "$0")"
ANEMLL_URL=https://github.com/Anemll/Anemll
ANEMLL_REV=f4ad26d061dc2e426faa19f81c367343bdeb9f0d   # 0.3.5 beta
ST_VERSION=1.3.5                                         # must match SwiftTransformers in project.yml
export V2T_TEAM=${V2T_TEAM:-7V3HZUL435}

if [ "$(git -C .deps/Anemll rev-parse HEAD 2>/dev/null)" != "$ANEMLL_REV" ]; then
  rm -rf .deps/Anemll && mkdir -p .deps/Anemll
  git -C .deps/Anemll init -q
  git -C .deps/Anemll fetch -q --depth 1 "$ANEMLL_URL" "$ANEMLL_REV"
  git -C .deps/Anemll checkout -q FETCH_HEAD
fi
# ANEMLL asks for swift-transformers' main branch, and a path package's branch requirement overrides the app's
# version pin. Pin it to the version mlx-swift-lm's tokenizer loader uses, so one app links one copy.
pkg=.deps/Anemll/anemll-swift-cli/Package.swift
sed -i '' -E "s#(swift-transformers\", )branch: \"main\"#\\1exact: \"$ST_VERSION\"#" "$pkg"
grep -q "swift-transformers\", exact: \"$ST_VERSION\"" "$pkg" || { echo "could not pin swift-transformers in $pkg" >&2; exit 1; }
rm -f .deps/Anemll/anemll-swift-cli/Package.resolved

for d in models clips cleanup bark; do [ -d "Res/$d" ] || { echo "Res/$d missing: run ./stage.py first" >&2; exit 1; }; done
xcodegen generate --quiet
# Package.resolved pins every transitive package too; the generated project is not committed, so carry it over.
mkdir -p V2TPhoneBench.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved V2TPhoneBench.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

if [ "${1:-}" = build ]; then
  nice -n 19 xcodebuild -project V2TPhoneBench.xcodeproj -scheme BenchApp -configuration Release \
    -destination generic/platform=iOS -derivedDataPath build -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation -quiet build
  echo "built: $(pwd)/build/Build/Products/Release-iphoneos/BenchApp.app"
fi
