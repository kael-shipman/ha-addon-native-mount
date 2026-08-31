#!/bin/bash
set -euo pipefail

log_info()    { echo "[$(date '+%H:%M:%S')] [INFO]    native-mount: $*"; }
log_warning() { echo "[$(date '+%H:%M:%S')] [WARNING] native-mount: $*"; }
log_error()   { echo "[$(date '+%H:%M:%S')] [ERROR]   native-mount: $*" >&2; }

# Thin wrapper so users can write `ha addons start <slug>` in commands.
ha() {
    local cmd="${1:-}" sub="${2:-}" slug="${3:-}"
    if [ "${cmd}" != "addons" ]; then
        log_error "ha wrapper: only 'addons' commands are supported (got: $*)"; return 1
    fi
    case "${sub}" in
        start|stop|restart)
            curl -sf -X POST \
                -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                "http://supervisor/addons/${slug}/${sub}" >/dev/null
            ;;
        *) log_error "ha wrapper: unsupported subcommand '${sub}'"; return 1 ;;
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
        if ! eval "${cmd}"; then log_warning "${label}: command exited non-zero: ${cmd}"; fi
    done
}

to_container_path() {
    local p="$1"
    case "${p}" in
        /mnt/data/supervisor/media/*)  printf '/media/%s'  "${p#/mnt/data/supervisor/media/}"  ;;
        /mnt/data/supervisor/share/*)  printf '/share/%s'  "${p#/mnt/data/supervisor/share/}"  ;;
        *)                             printf '%s'          "${p}"                               ;;
    esac
}

CONFIG="/data/options.json"

log_info "=== DIAGNOSTIC v0.6.0 ==="

# --- Capability check ---
log_info "[diag] Effective capabilities (CapEff from /proc/self/status):"
grep CapEff /proc/self/status | while IFS= read -r line; do log_info "[diag]   ${line}"; done

# Decode key bits (SYS_ADMIN=21, SYS_PTRACE=19)
capeff=$(grep CapEff /proc/self/status | awk '{print $2}')
capeff_dec=$((16#${capeff}))
has_sys_admin=$(( (capeff_dec >> 21) & 1 ))
has_sys_ptrace=$(( (capeff_dec >> 19) & 1 ))
log_info "[diag] CAP_SYS_ADMIN (bit 21): ${has_sys_admin}"
log_info "[diag] CAP_SYS_PTRACE (bit 19): ${has_sys_ptrace}"

# --- host_pid check ---
proc1_exe=$(readlink /proc/1/exe 2>&1 || echo "(readlink failed)")
proc1_cmd=$(cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' || echo "(no cmdline)")
proc1_mnt=$(readlink /proc/1/ns/mnt 2>&1 || echo "(readlink ns/mnt failed)")
proc_self_mnt=$(readlink /proc/self/ns/mnt 2>&1 || echo "(readlink self ns/mnt failed)")
log_info "[diag] /proc/1/exe: ${proc1_exe}"
log_info "[diag] /proc/1/cmdline: ${proc1_cmd}"
log_info "[diag] /proc/1/ns/mnt: ${proc1_mnt}"
log_info "[diag] /proc/self/ns/mnt: ${proc_self_mnt}"
if [ "${proc1_mnt}" = "${proc_self_mnt}" ]; then
    log_info "[diag] WARNING: /proc/1 and /proc/self are in the SAME mount namespace (host_pid may not be working)"
else
    log_info "[diag] /proc/1 is in a DIFFERENT namespace — host_pid is working"
fi

# --- nsenter check ---
log_info "[diag] Testing nsenter (timeout 5s)..."
nsenter_out=$(timeout 5 nsenter --mount=/proc/1/ns/mnt -- echo "nsenter_ok" 2>&1) && nsenter_exit=0 || nsenter_exit=$?
log_info "[diag] nsenter exit=${nsenter_exit} out=${nsenter_out}"

# --- blkid device check ---
log_info "[diag] All block devices (blkid):"
blkid 2>&1 | while IFS= read -r line; do log_info "[diag]   ${line}"; done

log_info "=== END DIAGNOSTIC ==="
log_info ""
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

    # Poll for device using blkid (doesn't depend on udev by-uuid symlinks).
    elapsed=0
    device_found=true
    until blkid -U "${uuid}" >/dev/null 2>&1; do
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

    log_info "[${i}] device found after ${elapsed}s ($(blkid -U "${uuid}"))"

    # Try mount via nsenter first (preserves host namespace visibility).
    # Fall back to direct container mount (propagates if /media or /share bind is rshared).
    if nsenter --mount=/proc/1/ns/mnt -- echo "ok" >/dev/null 2>&1; then
        log_info "[${i}] Mounting via nsenter (host namespace)"
        if [ "${fstype}" = "auto" ]; then
            mount_out=$(nsenter --mount=/proc/1/ns/mnt -- \
                mount "UUID=${uuid}" "${mount_point}" 2>&1) && mount_exit=0 || mount_exit=$?
        else
            mount_out=$(nsenter --mount=/proc/1/ns/mnt -- \
                mount -t "${fstype}" "UUID=${uuid}" "${mount_point}" 2>&1) && mount_exit=0 || mount_exit=$?
        fi
    else
        log_info "[${i}] nsenter unavailable, trying direct container mount at ${container_mount_point}"
        if [ "${fstype}" = "auto" ]; then
            mount_out=$(mount "UUID=${uuid}" "${container_mount_point}" 2>&1) && mount_exit=0 || mount_exit=$?
        else
            mount_out=$(mount -t "${fstype}" "UUID=${uuid}" "${container_mount_point}" 2>&1) && mount_exit=0 || mount_exit=$?
        fi
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
