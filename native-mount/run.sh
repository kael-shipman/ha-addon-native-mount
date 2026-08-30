#!/bin/bash
set -euo pipefail

log_info()    { echo "[$(date '+%H:%M:%S')] [INFO]    native-mount: $*"; }
log_warning() { echo "[$(date '+%H:%M:%S')] [WARNING] native-mount: $*"; }
log_error()   { echo "[$(date '+%H:%M:%S')] [ERROR]   native-mount: $*" >&2; }

# Thin wrapper so users can write `ha addons start <slug>` in commands.
# Calls the Supervisor REST API; requires hassio_api: true + hassio_role: manager.
ha() {
    local cmd="${1:-}" sub="${2:-}" slug="${3:-}"
    if [ "${cmd}" != "addons" ]; then
        log_error "ha wrapper: only 'addons' commands are supported (got: $*)"
        return 1
    fi
    case "${sub}" in
        start|stop|restart)
            curl -sf -X POST \
                -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                "http://supervisor/addons/${slug}/${sub}" >/dev/null
            ;;
        *)
            log_error "ha wrapper: unsupported subcommand '${sub}'"
            return 1
            ;;
    esac
}

run_commands() {
    local label="$1" config_path="$2"
    local count
    count=$(jq "if ${config_path} then ${config_path} | length else 0 end" "${CONFIG}")
    [ "${count}" -eq 0 ] && return 0
    log_info "${label}: running ${count} command(s)"
    for i in $(seq 0 $((count - 1))); do
        local cmd
        cmd=$(jq -r "${config_path}[${i}]" "${CONFIG}")
        log_info "${label}: $ ${cmd}"
        if ! eval "${cmd}"; then
            log_warning "${label}: command exited non-zero: ${cmd}"
        fi
    done
}

# Translate HA host-side paths to container-accessible paths.
# The HA Supervisor bind-mounts these with shared propagation, so mounts
# made here propagate to the host and other add-on containers.
#   /mnt/data/supervisor/media/ → /media/
#   /mnt/data/supervisor/share/ → /share/
# Paths that are already container paths, or unknown paths, pass through unchanged.
to_container_path() {
    local p="$1"
    case "${p}" in
        /mnt/data/supervisor/media/*)  printf '/media/%s'  "${p#/mnt/data/supervisor/media/}"  ;;
        /mnt/data/supervisor/share/*)  printf '/share/%s'  "${p#/mnt/data/supervisor/share/}"  ;;
        *)                             printf '%s'          "${p}"                               ;;
    esac
}

CONFIG="/data/options.json"

log_info "starting"

mount_count=$(jq 'if .mounts then .mounts | length else 0 end' "${CONFIG}")
log_info "${mount_count} mount(s) configured"

for i in $(seq 0 $((mount_count - 1))); do
    uuid=$(jq -r ".mounts[${i}].device_uuid" "${CONFIG}")
    mount_point=$(jq -r ".mounts[${i}].mount_point" "${CONFIG}")
    fstype=$(jq -r ".mounts[${i}].fstype // \"auto\"" "${CONFIG}")
    wait_timeout=$(jq -r ".mounts[${i}].wait_timeout // 30" "${CONFIG}")

    container_mount_point=$(to_container_path "${mount_point}")

    if [ "${fstype}" = "auto" ]; then
        log_info "[${i}] Attempting to mount UUID=${uuid} -> ${mount_point} (Waiting up to ${wait_timeout}s for device to appear)"
    else
        log_info "[${i}] Attempting to mount UUID=${uuid} -> ${mount_point} as ${fstype} (Waiting up to ${wait_timeout}s for device to appear)"
    fi
    [ "${container_mount_point}" != "${mount_point}" ] && \
        log_info "[${i}] Container path: ${container_mount_point}"

    # Poll for the device. full_access exposes all host block devices at /dev/
    # so we can check by-uuid symlinks directly without nsenter.
    elapsed=0
    device_found=true
    until [ -e "/dev/disk/by-uuid/${uuid}" ]; do
        if [ "${elapsed}" -ge "${wait_timeout}" ]; then
            log_error "[${i}] device UUID=${uuid} not found after ${wait_timeout}s — skipping"
            log_info "[${i}] Visible block devices:"
            blkid 2>&1 | while IFS= read -r line; do log_info "[${i}]   ${line}"; done
            device_found=false
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ "${device_found}" = "false" ]; then
        run_commands "[${i}] on_failure" ".mounts[${i}].on_failure"
        continue
    fi

    log_info "[${i}] device found after ${elapsed}s"

    if [ "${fstype}" = "auto" ]; then
        mount_out=$(mount "UUID=${uuid}" "${container_mount_point}" 2>&1) && mount_exit=0 || mount_exit=$?
    else
        mount_out=$(mount -t "${fstype}" "UUID=${uuid}" "${container_mount_point}" 2>&1) && mount_exit=0 || mount_exit=$?
    fi

    if [ "${mount_exit}" -eq 0 ]; then
        log_info "[${i}] mounted successfully"
        run_commands "[${i}] on_success" ".mounts[${i}].on_success"
    else
        log_error "[${i}] mount failed (exit ${mount_exit}): ${mount_out}"
        run_commands "[${i}] on_failure" ".mounts[${i}].on_failure"
    fi
done

run_commands "post_mount" ".post_mount_ha_commands"

log_info "done"
