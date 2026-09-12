#!/bin/bash

set -euo pipefail

project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
release_dir="${project_dir}/build/release"

mkdir -p "${release_dir}"
rm -f "${release_dir}"/Quodex-*.dmg "${release_dir}"/Quodex-*.app.zip \
    "${release_dir}/SHA256SUMS.txt"

for architecture in arm64 x86_64; do
    "${project_dir}/Scripts/build-dmg.sh" "${architecture}"
done

(
    cd "${release_dir}"
    shasum -a 256 Quodex-*.dmg Quodex-*.app.zip > SHA256SUMS.txt
)

printf 'Release artifacts are in %s\n' "${release_dir}"
