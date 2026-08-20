#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-release}"
case "$configuration" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 64
        ;;
esac

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_dir="$(cd "$script_dir/.." && pwd)"
scratch_path="${NOCTCORD_BUILD_PATH:-$repository_dir/.build}"
bundle_path="$repository_dir/dist/Noct Cord.app"
contents_path="$bundle_path/Contents"
codesign_identity="${NOCTCORD_CODESIGN_IDENTITY:--}"

swift build \
    --package-path "$repository_dir" \
    --scratch-path "$scratch_path" \
    --configuration "$configuration" \
    --product NoctCordApp

binary_dir="$(swift build \
    --package-path "$repository_dir" \
    --scratch-path "$scratch_path" \
    --configuration "$configuration" \
    --show-bin-path)"

if [[ -e "$bundle_path" ]]; then
    rm -rf -- "$bundle_path"
fi
mkdir -p "$contents_path/MacOS" "$contents_path/Resources" "$contents_path/Frameworks"
cp "$binary_dir/NoctCordApp" "$contents_path/MacOS/NoctCordApp"
cp "$repository_dir/Resources/NoctCordApp-Info.plist" "$contents_path/Info.plist"
if [[ ! -d "$binary_dir/WebRTC.framework" ]]; then
    echo "missing WebRTC.framework beside the built executable" >&2
    exit 1
fi
cp -R "$binary_dir/WebRTC.framework" "$contents_path/Frameworks/"
install_name_tool \
    -add_rpath "@executable_path/../Frameworks" \
    "$contents_path/MacOS/NoctCordApp"
if [[ -f "$repository_dir/Resources/NoctCordIcon.icns" ]]; then
    cp "$repository_dir/Resources/NoctCordIcon.icns" "$contents_path/Resources/NoctCordIcon.icns"
fi
chmod 755 "$contents_path/MacOS/NoctCordApp"
signing_options=(--force --sign "$codesign_identity")
if [[ "$codesign_identity" == "-" ]]; then
    signing_options+=(--timestamp=none)
else
    signing_options+=(--options runtime --timestamp)
fi
codesign "${signing_options[@]}" "$contents_path/Frameworks/WebRTC.framework"
codesign \
    "${signing_options[@]}" \
    --entitlements "$repository_dir/Resources/NoctCordApp.entitlements" \
    "$bundle_path"
codesign --verify --deep --strict --verbose=2 "$bundle_path"
touch "$bundle_path"

echo "$bundle_path"
