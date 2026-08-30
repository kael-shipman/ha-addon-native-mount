#!/bin/bash
set -euo pipefail

# /proc/1 refers to the HOST's systemd (not the container init) because
# host_pid=true. This gives us:
#   /proc/1/ns/mnt  — the host's mount namespace (for nsenter)

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

CONFIG="/data/options.json"

log_info "starting"

mount_count=$(jq 'if .mounts then .mounts | length else 0 end' "${CONFIG}")
log_info "${mount_count} mount(s) configured"

for i in $(seq 0 $((mount_count - 1))); do
    uuid=$(jq -r ".mounts[${i}].device_uuid" "${CONFIG}")
    mount_point=$(jq -r ".mounts[${i}].mount_point" "${CONFIG}")
    fstype=$(jq -r ".mounts[${i}].fstype // \"auto\"" "${CONFIG}")
    wait_timeout=$(jq -r ".mounts[${i}].wait_timeout // 30" "${CONFIG}")

    if [ "${fstype}" = "auto" ]; then
        log_info "[${i}] Attempting to mount UUID=${uuid} -> ${mount_point} (Waiting up to ${wait_timeout}s for device to appear)"
    else
        log_info "[${i}] Attempting to mount UUID=${uuid} -> ${mount_point} as ${fstype} (Waiting up to ${wait_timeout}s for device to appear)"
    fi

    # Verify nsenter can open the host's mount namespace before polling.
    # Requires SYS_PTRACE to open /proc/1/ns/mnt. A failure here means a
    # capability or seccomp issue, not a missing device.
    nsenter_check=$(nsenter --mount=/proc/1/ns/mnt -- echo "ok" 2>&1) || true
    if [ "${nsenter_check}" != "ok" ]; then
        log_error "[${i}] nsenter cannot open host mount namespace: ${nsenter_check}"
        log_error "[${i}] Ensure SYS_PTRACE is listed in the add-on's privileged config"
        run_commands "[${i}] on_failure" ".mounts[${i}].on_failure"
        continue
    fi

    # Poll using blkid -U (reads device headers directly; does not depend on
    # udev having created /dev/disk/by-uuid/ symlinks).
    elapsed=0
    device_found=true
    until nsenter --mount=/proc/1/ns/mnt -- blkid -U "${uuid}" >/dev/null 2>&1; do
        if [ "${elapsed}" -ge "${wait_timeout}" ]; then
            log_error "[${i}] device UUID=${uuid} not found after ${wait_timeout}s — skipping"
            log_info "[${i}] Block devices visible in host namespace:"
            nsenter --mount=/proc/1/ns/mnt -- blkid 2>&1 | while IFS= read -r line; do
                log_info "[${i}]   ${line}"
            done
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
        mount_out=$(nsenter --mount=/proc/1/ns/mnt -- \
            mount "UUID=${uuid}" "${mount_point}" 2>&1) && mount_exit=0 || mount_exit=$?
    else
        mount_out=$(nsenter --mount=/proc/1/ns/mnt -- \
            mount -t "${fstype}" "UUID=${uuid}" "${mount_point}" 2>&1) && mount_exit=0 || mount_exit=$?
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
