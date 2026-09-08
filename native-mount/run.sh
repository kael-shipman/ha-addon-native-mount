#!/bin/bash
set -euo pipefail

ENTITY_UPDATE_INTERVAL=900  # 15 minutes

# homeassistant_api: true in config sets HOMEASSISTANT_TOKEN to Core's internal API token.
# Without that flag only SUPERVISOR_TOKEN is available, which the Core proxy rejects.
CORE_API_TOKEN="${HOMEASSISTANT_TOKEN:-${SUPERVISOR_TOKEN:-}}"

log_info()    { echo "[$(date '+%H:%M:%S')] [INFO]    native-mount: $*"; }
log_warning() { echo "[$(date '+%H:%M:%S')] [WARNING] native-mount: $*"; }
log_error()   { echo "[$(date '+%H:%M:%S')] [ERROR]   native-mount: $*" >&2; }

trap 'log_info "shutting down"; exit 0' TERM INT

# Thin `ha addons|addon start|stop|restart <slug>` wrapper over the Supervisor API.
ha() {
    local cmd="${1:-}" sub="${2:-}" slug="${3:-}"
    if [ "${cmd}" != "addons" ] && [ "${cmd}" != "addon" ]; then
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

# Push mount state and disk usage to the HA Core state machine.
# Entity ID: sensor.native_mount_<first 8 hex chars of UUID>
# No external dependencies — uses the Supervisor API proxy to Core.
update_entity() {
    local idx="$1" uuid="$2" mount_point="$3"
    local entity_id="sensor.native_mount_$(printf '%s' "${uuid}" | tr -d '-' | cut -c1-8)"
    local label; label=$(basename "${mount_point}")

    local state="unmounted"
    local device="" total_gb="" used_gb="" usage_pct=""

    if nsenter --mount=/proc/1/ns/mnt -- findmnt -n "${mount_point}" >/dev/null 2>&1; then
        state="mounted"
        device=$(blkid -U "${uuid}" 2>/dev/null || true)

        # df in the host namespace so we read the actual mounted volume.
        local df_line
        df_line=$(nsenter --mount=/proc/1/ns/mnt -- df -k "${mount_point}" 2>/dev/null | awk 'NR==2')
        if [ -n "${df_line}" ]; then
            local tkb ukb
            tkb=$(echo "${df_line}" | awk '{print $2}')
            ukb=$(echo "${df_line}" | awk '{print $3}')
            total_gb=$(awk "BEGIN{printf \"%.2f\", ${tkb}/1048576}")
            used_gb=$(awk  "BEGIN{printf \"%.2f\", ${ukb}/1048576}")
            usage_pct=$(awk "BEGIN{printf \"%.1f\", ${ukb}*100/${tkb}}")
        fi
    fi

    # Build JSON with jq so all values are properly escaped and typed.
    local payload
    payload=$(jq -n \
        --arg state "${state}" \
        --arg name  "Native Mount: ${label}" \
        --arg uuid  "${uuid}" \
        --arg mp    "${mount_point}" \
        --arg dev   "${device}" \
        --arg tgb   "${total_gb}" \
        --arg ugb   "${used_gb}" \
        --arg pct   "${usage_pct}" \
        '{
            state: $state,
            attributes: {
                friendly_name:  $name,
                uuid:           $uuid,
                mount_point:    $mp,
                device:         (if $dev == "" then null else $dev end),
                total_gb:       (if $tgb == "" then null else ($tgb | tonumber) end),
                used_gb:        (if $ugb == "" then null else ($ugb | tonumber) end),
                usage_percent:  (if $pct == "" then null else ($pct | tonumber) end),
                icon:           "mdi:harddisk"
            }
        }')

    if curl -sf -X POST \
        -H "Authorization: Bearer ${CORE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "http://supervisor/core/api/states/${entity_id}" >/dev/null; then
        if [ "${state}" = "mounted" ]; then
            log_info "[${idx}] entity ${entity_id}: ${state}, ${used_gb} / ${total_gb} GB (${usage_pct}%)"
        else
            log_info "[${idx}] entity ${entity_id}: ${state}"
        fi
    else
        log_warning "[${idx}] failed to update entity ${entity_id} — is HA Core running?"
    fi
}

update_all_entities() {
    local count="$1"
    for i in $(seq 0 $((count - 1))); do
        update_entity "${i}" \
            "$(jq -r ".mounts[${i}].device_uuid" "${CONFIG}")" \
            "$(jq -r ".mounts[${i}].mount_point"  "${CONFIG}")"
    done
}

CONFIG="/data/options.json"

log_info "starting"
if [ -z "${CORE_API_TOKEN}" ]; then
    log_error "no API token available — entity updates will not work"
fi

mount_count=$(jq 'if .mounts then .mounts | length else 0 end' "${CONFIG}")
log_info "${mount_count} mount(s) configured"

# ── Mount phase ────────────────────────────────────────────────────────────────

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

    if nsenter --mount=/proc/1/ns/mnt -- findmnt -n "${mount_point}" >/dev/null 2>&1; then
        log_info "[${i}] ${mount_point} is already mounted — skipping"
        run_commands "[${i}] on_success" ".mounts[${i}].on_success"
        continue
    fi

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

# ── Entity update loop ─────────────────────────────────────────────────────────

if [ "${mount_count}" -eq 0 ]; then
    log_info "no mounts configured — nothing to report"
    exit 0
fi

# The add-on runs at the initialize stage, before HA Core starts. Wait until
# Core is responding before publishing entities.
log_info "waiting for HA Core to be ready..."
core_wait=0
core_max=600  # 10 minutes
until curl -sf \
    -H "Authorization: Bearer ${CORE_API_TOKEN}" \
    "http://supervisor/core/api/" >/dev/null 2>&1; do
    if [ "${core_wait}" -ge "${core_max}" ]; then
        log_warning "HA Core did not become ready within ${core_max}s — entities will appear on next update cycle"
        break
    fi
    sleep 15
    core_wait=$((core_wait + 15))
done
[ "${core_wait}" -lt "${core_max}" ] && log_info "HA Core ready after ${core_wait}s"

log_info "publishing initial entity state(s)"
update_all_entities "${mount_count}"

log_info "entering entity update loop (every $((ENTITY_UPDATE_INTERVAL / 60)) min)"
while true; do
    sleep "${ENTITY_UPDATE_INTERVAL}"
    log_info "updating entity state(s)"
    update_all_entities "${mount_count}"
done
