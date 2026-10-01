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
swift_build_options=(--configuration "$configuration")
if [[ "$(swift build --help)" == *swiftbuild* ]]; then
    swift_build_options+=(--build-system swiftbuild)
fi
if [[ "${NOCTWEAVE_OFFLINE:-0}" == "1" ]]; then
    swift_build_options+=(--disable-automatic-resolution)
fi

swift build \
    --package-path "$repository_dir" \
    --scratch-path "$scratch_path" \
    "${swift_build_options[@]}" \
    --product NoctCordApp

binary_dir="$(swift build \
    --package-path "$repository_dir" \
    --scratch-path "$scratch_path" \
    "${swift_build_options[@]}" \
    --show-bin-path)"

# swiftbuild keeps binary dependencies in the verified artifact cache rather
# than necessarily copying them beside the executable. Select the cached macOS
# slice for this host, instead of finding an unrelated/stale framework by glob.
webrtc_framework="$binary_dir/WebRTC.framework"
if [[ ! -d "$webrtc_framework" ]]; then
    webrtc_framework="$(python3 - "$scratch_path/workspace-state.json" "$(uname -m)" <<'PY'
import json, pathlib, plistlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
artifacts = [a for a in state["object"]["artifacts"]
             if a["targetName"] == "WebRTC" and a["packageRef"]["identity"] == "webrtc"]
if len(artifacts) != 1:
    raise SystemExit("Expected one resolved WebRTC binary artifact")
root = pathlib.Path(artifacts[0]["path"])
info = plistlib.loads((root / "Info.plist").read_bytes())
slices = [s for s in info["AvailableLibraries"]
          if s["SupportedPlatform"] == "macos"
          and not s.get("SupportedPlatformVariant")
          and sys.argv[2] in s["SupportedArchitectures"]]
if len(slices) != 1:
    raise SystemExit("Expected one WebRTC macOS slice for this architecture")
library = slices[0]
framework = root / library["LibraryIdentifier"] / library["LibraryPath"]
if framework.name != "WebRTC.framework" or not framework.is_dir():
    raise SystemExit("Resolved WebRTC macOS framework is missing")
print(framework)
PY
    )"
fi
test -x "$binary_dir/NoctCordApp"

if [[ -e "$bundle_path" ]]; then
    rm -rf -- "$bundle_path"
fi
mkdir -p "$contents_path/MacOS" "$contents_path/Resources" "$contents_path/Frameworks"
cp "$binary_dir/NoctCordApp" "$contents_path/MacOS/NoctCordApp"
cp "$repository_dir/Resources/NoctCordApp-Info.plist" "$contents_path/Info.plist"
cp -R "$webrtc_framework" "$contents_path/Frameworks/"
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
