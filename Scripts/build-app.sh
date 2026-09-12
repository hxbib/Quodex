#!/bin/bash

set -euo pipefail

project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
architecture="${QUODEX_ARCH:-$(uname -m)}"
output_dir="${QUODEX_OUTPUT_DIR:-${project_dir}/build}"
bundle_dir="${output_dir}/Quodex.app"
contents_dir="${bundle_dir}/Contents"
icon_work_dir="$(mktemp -d)"
trap 'rm -rf "${icon_work_dir}"' EXIT

cd "${project_dir}"
case "${architecture}" in
    arm64|x86_64) ;;
    *) printf 'Unsupported architecture: %s\n' "${architecture}" >&2; exit 1 ;;
esac

swift build -c release --arch "${architecture}" --product Quodex -Xswiftc -warnings-as-errors

if [ -e "${bundle_dir}" ]; then
    rm -rf "${bundle_dir}"
fi
mkdir -p "${contents_dir}/MacOS" "${contents_dir}/Resources"

cp "${project_dir}/.build/${architecture}-apple-macosx/release/Quodex" "${contents_dir}/MacOS/Quodex"
cp "${project_dir}/Resources/Info.plist" "${contents_dir}/Info.plist"
shared_source_hash="$(find Sources/Quodex -name '*.swift' ! -name DistributionProfile.swift -type f -print | LC_ALL=C sort | while IFS= read -r source; do shasum -a 256 "${source}"; done | shasum -a 256 | cut -d ' ' -f 1)"
/usr/libexec/PlistBuddy -c "Add :QuodexSharedSourceSHA256 string ${shared_source_hash}" "${contents_dir}/Info.plist"

iconset_dir="${icon_work_dir}/AppIcon.iconset"
mkdir -p "${iconset_dir}"
sips -s format png "${project_dir}/Resources/AppIcon.svg" --out "${icon_work_dir}/AppIcon.png" >/dev/null
for icon_size in 16 32 128 256 512; do
    sips -z "${icon_size}" "${icon_size}" "${icon_work_dir}/AppIcon.png" \
        --out "${iconset_dir}/icon_${icon_size}x${icon_size}.png" >/dev/null
    double_size=$((icon_size * 2))
    sips -z "${double_size}" "${double_size}" "${icon_work_dir}/AppIcon.png" \
        --out "${iconset_dir}/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "${iconset_dir}" -o "${contents_dir}/Resources/AppIcon.icns"

codesign --force --sign - --timestamp=none "${bundle_dir}"
codesign --verify --deep --strict "${bundle_dir}"

printf 'Built %s (%s)\n' "${bundle_dir}" "${architecture}"
