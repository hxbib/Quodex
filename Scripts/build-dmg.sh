#!/bin/bash

set -euo pipefail

project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
architecture="${1:-${QUODEX_ARCH:-$(uname -m)}}"
release_dir="${QUODEX_RELEASE_DIR:-${project_dir}/build/release}"
app_dir="${project_dir}/build/${architecture}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${project_dir}/Resources/Info.plist")"
work_dir="$(mktemp -d)"
mount_dir="${work_dir}/Quodex"

cleanup() {
    if mount | grep -Fq "${mount_dir}"; then
        hdiutil detach "${mount_dir}" -quiet || true
    fi
    rm -rf "${work_dir}"
}
trap cleanup EXIT

case "${architecture}" in
    arm64|x86_64) ;;
    *) printf 'Unsupported architecture: %s\n' "${architecture}" >&2; exit 1 ;;
esac

mkdir -p "${release_dir}" "${app_dir}"
QUODEX_ARCH="${architecture}" QUODEX_OUTPUT_DIR="${app_dir}" "${project_dir}/Scripts/build-app.sh"

staging_dir="${work_dir}/staging"
mkdir -p "${staging_dir}/.background"
ditto "${app_dir}/Quodex.app" "${staging_dir}/Quodex.app"
ln -s /Applications "${staging_dir}/Applications"
xcrun swiftc -parse-as-library -warnings-as-errors \
    "${project_dir}/Sources/Quodex/QuodexMark.swift" \
    "${project_dir}/Scripts/render-dmg-background.swift" -o "${work_dir}/render-background"
"${work_dir}/render-background" \
    "${project_dir}/Resources/DMGBackdrop.png" \
    "${staging_dir}/.background/background.png"

readwrite_dmg="${work_dir}/Quodex-rw.dmg"
output_dmg="${release_dir}/Quodex-${version}-${architecture}.dmg"
rm -f "${output_dmg}"
hdiutil create -quiet -fs HFS+ -format UDRW -volname "Quodex" \
    -srcfolder "${staging_dir}" "${readwrite_dmg}"
mkdir -p "${mount_dir}"
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "${mount_dir}" "${readwrite_dmg}"

osascript <<APPLESCRIPT
set rootFolder to POSIX file "${mount_dir}" as alias
tell application "Finder"
    open rootFolder
    set targetWindow to container window of rootFolder
    set current view of targetWindow to icon view
    try
        set toolbar visible of targetWindow to false
    end try
    try
        set statusbar visible of targetWindow to false
    end try
    set bounds of targetWindow to {180, 140, 820, 572}
    set viewOptions to icon view options of targetWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to POSIX file "${mount_dir}/.background/background.png" as alias
    set position of item "Quodex.app" of targetWindow to {180, 205}
    set position of item "Applications" of targetWindow to {460, 205}
    close targetWindow
    delay 2
end tell
APPLESCRIPT

sync
hdiutil detach "${mount_dir}" -quiet
hdiutil convert -quiet "${readwrite_dmg}" -format UDZO -imagekey zlib-level=9 -o "${output_dmg}"

zip_path="${release_dir}/Quodex-${version}-${architecture}.app.zip"
rm -f "${zip_path}"
ditto -c -k --keepParent --sequesterRsrc "${app_dir}/Quodex.app" "${zip_path}"

printf 'Built %s\nBuilt %s\n' "${output_dmg}" "${zip_path}"
