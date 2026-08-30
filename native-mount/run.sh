#!/usr/bin/with-contenv bashio
# shellcheck shell=bash

# /proc/1 refers to the HOST's systemd (not the container init) because
# host_pid=true. This gives us:
#   /proc/1/ns/mnt  — the host's mount namespace (for nsenter)
#   /proc/1/root/   — the host's root fs view (for device detection)

CONFIG="/data/options.json"

bashio::log.info "native-mount: starting"

mount_count=$(jq 'if .mounts then .mounts | length else 0 end' "${CONFIG}")
bashio::log.info "native-mount: ${mount_count} mount(s) configured"

for i in $(seq 0 $((mount_count - 1))); do
    uuid=$(jq -r ".mounts[${i}].device_uuid" "${CONFIG}")
    mount_point=$(jq -r ".mounts[${i}].mount_point" "${CONFIG}")
    fstype=$(jq -r ".mounts[${i}].fstype // \"auto\"" "${CONFIG}")
    wait_timeout=$(jq -r ".mounts[${i}].wait_timeout // 30" "${CONFIG}")

    bashio::log.info "native-mount: [${i}] UUID=${uuid} → ${mount_point} (fstype=${fstype}, timeout=${wait_timeout}s)"

    # Detect device via the host's /proc since we share the host PID namespace.
    device="/proc/1/root/dev/disk/by-uuid/${uuid}"
    elapsed=0
    device_found=true
    until [ -e "${device}" ]; do
        if [ "${elapsed}" -ge "${wait_timeout}" ]; then
            bashio::log.error "native-mount: [${i}] device UUID=${uuid} not found after ${wait_timeout}s — skipping"
            device_found=false
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    [ "${device_found}" = "false" ] && continue

    bashio::log.info "native-mount: [${i}] device found after ${elapsed}s"

    # Mount inside the host's mount namespace so the result is visible
    # to all host processes (including Frigate).
    if [ "${fstype}" = "auto" ]; then
        mount_out=$(nsenter --mount=/proc/1/ns/mnt -- \
            mount "UUID=${uuid}" "${mount_point}" 2>&1)
    else
        mount_out=$(nsenter --mount=/proc/1/ns/mnt -- \
            mount -t "${fstype}" "UUID=${uuid}" "${mount_point}" 2>&1)
    fi
    mount_exit=$?

    if [ ${mount_exit} -eq 0 ]; then
        bashio::log.info "native-mount: [${i}] mounted successfully"
    else
        bashio::log.error "native-mount: [${i}] mount failed (exit ${mount_exit}): ${mount_out}"
    fi
done

# Optional post-mount commands — runs in the container (not host namespace),
# so use `ha addons start <slug>` rather than raw shell mount commands.
cmd_count=$(jq 'if .post_mount_ha_commands then .post_mount_ha_commands | length else 0 end' "${CONFIG}")
if [ "${cmd_count}" -gt 0 ]; then
    bashio::log.info "native-mount: running ${cmd_count} post-mount command(s)"
    for i in $(seq 0 $((cmd_count - 1))); do
        cmd=$(jq -r ".post_mount_ha_commands[${i}]" "${CONFIG}")
        bashio::log.info "native-mount: ${cmd}"
        if ! eval "${cmd}"; then
            bashio::log.warning "native-mount: command exited non-zero: ${cmd}"
        fi
    done
fi

bashio::log.info "native-mount: done"
