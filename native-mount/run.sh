#!/bin/bash
set -euo pipefail

# /proc/1 refers to the HOST's systemd (not the container init) because
# host_pid=true. This gives us:
#   /proc/1/ns/mnt  — the host's mount namespace (for nsenter)
#   /proc/1/root/   — the host's root fs view (for device detection)

log_info()    { echo "[INFO]    native-mount: $*"; }
log_warning() { echo "[WARNING] native-mount: $*"; }
log_error()   { echo "[ERROR]   native-mount: $*" >&2; }

CONFIG="/data/options.json"

log_info "starting"

mount_count=$(jq 'if .mounts then .mounts | length else 0 end' "${CONFIG}")
log_info "${mount_count} mount(s) configured"

for i in $(seq 0 $((mount_count - 1))); do
    uuid=$(jq -r ".mounts[${i}].device_uuid" "${CONFIG}")
    mount_point=$(jq -r ".mounts[${i}].mount_point" "${CONFIG}")
    fstype=$(jq -r ".mounts[${i}].fstype // \"auto\"" "${CONFIG}")
    wait_timeout=$(jq -r ".mounts[${i}].wait_timeout // 30" "${CONFIG}")

    log_info "[${i}] UUID=${uuid} -> ${mount_point} (fstype=${fstype}, timeout=${wait_timeout}s)"

    device="/proc/1/root/dev/disk/by-uuid/${uuid}"
    elapsed=0
    device_found=true
    until [ -e "${device}" ]; do
        if [ "${elapsed}" -ge "${wait_timeout}" ]; then
            log_error "[${i}] device UUID=${uuid} not found after ${wait_timeout}s — skipping"
            device_found=false
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    [ "${device_found}" = "false" ] && continue

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
    else
        log_error "[${i}] mount failed (exit ${mount_exit}): ${mount_out}"
    fi
done

cmd_count=$(jq 'if .post_mount_ha_commands then .post_mount_ha_commands | length else 0 end' "${CONFIG}")
if [ "${cmd_count}" -gt 0 ]; then
    log_info "running ${cmd_count} post-mount command(s)"
    for i in $(seq 0 $((cmd_count - 1))); do
        cmd=$(jq -r ".post_mount_ha_commands[${i}]" "${CONFIG}")
        log_info "$ ${cmd}"
        if ! eval "${cmd}"; then
            log_warning "command exited non-zero: ${cmd}"
        fi
    done
fi

log_info "done"
