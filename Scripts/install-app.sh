#!/bin/bash

set -euo pipefail

project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
built_app="${project_dir}/build/Quodex.app"
if [ -n "${QUODEX_INSTALL_DIR:-}" ]; then
    destination_dir="${QUODEX_INSTALL_DIR}"
elif [ -w /Applications ]; then
    destination_dir="/Applications"
else
    destination_dir="${HOME}/Applications"
fi
destination_app="${destination_dir}/Quodex.app"
user_destination_app="${HOME}/Applications/Quodex.app"
install_work_dir="$(mktemp -d)"
previous_app="${install_work_dir}/Quodex.previous.app"
failed_app="${install_work_dir}/Quodex.failed.app"
trap 'rm -rf "${install_work_dir}"' EXIT

installed_process_ids() {
    /bin/ps -axo pid=,command= | /usr/bin/awk \
        -v current="${destination_app}/Contents/MacOS/Quodex" \
        -v user_copy="${user_destination_app}/Contents/MacOS/Quodex" \
        '$2 == current || $2 == user_copy { print $1 }'
}

installed_process_is_running() {
    [ -n "$(installed_process_ids)" ]
}

stop_installed_processes() {
    local process_id
    for process_id in $(installed_process_ids); do
        /bin/kill "${process_id}" >/dev/null 2>&1 || true
    done
}

"${project_dir}/Scripts/build-app.sh"
mkdir -p "${destination_dir}"

/usr/bin/osascript -e 'tell application id "com.quodex.Quodex" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
    if ! installed_process_is_running; then
        break
    fi
    sleep 1
done
if installed_process_is_running; then
    stop_installed_processes
    for _ in 1 2 3 4 5; do
        if ! installed_process_is_running; then
            break
        fi
        sleep 1
    done
fi
if installed_process_is_running; then
    printf 'Install failed: the running Quodex process did not stop.\n' >&2
    exit 1
fi

if [ -e "${destination_app}" ]; then
    mv "${destination_app}" "${previous_app}"
fi

if ! ditto "${built_app}" "${destination_app}"; then
    if [ -e "${previous_app}" ]; then
        mv "${previous_app}" "${destination_app}"
    fi
    exit 1
fi

if ! codesign --verify --deep --strict "${destination_app}"; then
    mv "${destination_app}" "${failed_app}"
    if [ -e "${previous_app}" ]; then
        mv "${previous_app}" "${destination_app}"
    fi
    exit 1
fi

if ! open "${destination_app}"; then
    mv "${destination_app}" "${failed_app}"
    if [ -e "${previous_app}" ]; then
        mv "${previous_app}" "${destination_app}"
    fi
    exit 1
fi

launched=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if installed_process_is_running; then
        launched=true
        break
    fi
    sleep 1
done
if [ "${launched}" != true ]; then
    stop_installed_processes
    for _ in 1 2 3 4 5; do
        if ! installed_process_is_running; then
            break
        fi
        sleep 1
    done
    mv "${destination_app}" "${failed_app}"
    if [ -e "${previous_app}" ]; then
        mv "${previous_app}" "${destination_app}"
    fi
    exit 1
fi

printf 'Installed and launched %s\n' "${destination_app}"
