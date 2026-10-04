#!/bin/bash
set -euo pipefail

ENTITY_UPDATE_INTERVAL=60   # seconds
MQTT_RETRY_INTERVAL=10      # seconds between broker discovery/connect attempts
DISCOVERY_PREFIX="homeassistant"
BASE_TOPIC="native_mount"
AVAILABILITY_TOPIC="${BASE_TOPIC}/status"
PUBLISHED_IDS_FILE="/data/published_ids"
VERSION="${NATIVE_MOUNT_VERSION:-unknown}"

log_info()    { echo "[$(date '+%H:%M:%S')] [INFO]    native-mount: $*"; }
log_warning() { echo "[$(date '+%H:%M:%S')] [WARNING] native-mount: $*"; }
log_error()   { echo "[$(date '+%H:%M:%S')] [ERROR]   native-mount: $*" >&2; }

CONFIG="/data/options.json"
WILL_PID=""

# ── MQTT helpers ───────────────────────────────────────────────────────────────

# Populate MQTT_* from the Supervisor's mqtt service (requires `services: mqtt:want`).
# Returns non-zero until a broker has registered itself as the mqtt provider.
fetch_mqtt_service() {
    local svc
    svc=$(curl -sf -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "http://supervisor/services/mqtt" 2>/dev/null) || return 1
    MQTT_HOST=$(jq -r '.data.host // empty' <<<"${svc}")
    MQTT_PORT=$(jq -r '.data.port // 1883' <<<"${svc}")
    MQTT_USER=$(jq -r '.data.username // empty' <<<"${svc}")
    MQTT_PASS=$(jq -r '.data.password // empty' <<<"${svc}")
    MQTT_SSL=$(jq -r '.data.ssl // false' <<<"${svc}")
    [ -n "${MQTT_HOST}" ]
}

mqtt_args() {
    MQTT_ARGS=(-h "${MQTT_HOST}" -p "${MQTT_PORT}")
    [ -n "${MQTT_USER}" ] && MQTT_ARGS+=(-u "${MQTT_USER}" -P "${MQTT_PASS}")
    [ "${MQTT_SSL}" = "true" ] && MQTT_ARGS+=(--capath /etc/ssl/certs)
    return 0
}

# mqtt_pub <topic> <payload>   — always retained, so HA can rebuild state at any time.
# QoS 0: each call is a short-lived connection that ends in a clean DISCONNECT,
# so the broker has the message once we exit; QoS 1 only adds a ~1 s ack wait.
mqtt_pub() {
    mosquitto_pub "${MQTT_ARGS[@]}" -q 0 -i "native-mount-pub-$$" -r -t "$1" -m "$2"
}

# Block until the broker is known and reachable, then mark us online.
wait_for_mqtt() {
    local waited=0
    log_info "waiting for MQTT broker..."
    until fetch_mqtt_service && mqtt_args && mqtt_pub "${AVAILABILITY_TOPIC}" "online" 2>/dev/null; do
        if [ $((waited % 60)) -eq 0 ] && [ "${waited}" -gt 0 ]; then
            log_info "still waiting for MQTT broker (${waited}s) — is the Mosquitto broker app installed and running?"
        fi
        sleep "${MQTT_RETRY_INTERVAL}"
        waited=$((waited + MQTT_RETRY_INTERVAL))
    done
    log_info "connected to MQTT broker ${MQTT_HOST}:${MQTT_PORT} after ${waited}s"
}

# Hold one persistent connection whose last-will marks us offline if the
# container dies without a clean shutdown. mosquitto_sub reconnects on its own.
start_will_holder() {
    mosquitto_sub "${MQTT_ARGS[@]}" -q 1 -i "native-mount-will" \
        -t "${BASE_TOPIC}/will_holder" \
        --will-topic "${AVAILABILITY_TOPIC}" --will-payload "offline" --will-retain --will-qos 1 \
        >/dev/null 2>&1 &
    WILL_PID=$!
}

shutdown() {
    log_info "shutting down"
    if [ -n "${WILL_PID}" ]; then
        mqtt_pub "${AVAILABILITY_TOPIC}" "offline" 2>/dev/null || true
        kill "${WILL_PID}" 2>/dev/null || true
    fi
    exit 0
}
trap shutdown TERM INT

# ── Entity publishing ──────────────────────────────────────────────────────────

# Entity ID: sensor.native_mount_<first 8 hex chars of UUID>
short_id() { printf '%s' "$1" | tr -d '-' | cut -c1-8; }

# Retained discovery config: HA's MQTT integration creates a registry-backed
# entity (with a device) from this and recreates it after every Core restart.
publish_discovery() {
    local uuid="$1" mount_point="$2"
    local id; id=$(short_id "${uuid}")
    local label; label=$(basename "${mount_point}")

    local config
    config=$(jq -nc \
        --arg id "${id}" \
        --arg name "Native Mount: ${label}" \
        --arg base "${BASE_TOPIC}" \
        --arg avail "${AVAILABILITY_TOPIC}" \
        --arg ver "${VERSION}" \
        '{
            name: null,
            unique_id: "native_mount_\($id)",
            default_entity_id: "sensor.native_mount_\($id)",
            state_topic: "\($base)/\($id)/state",
            json_attributes_topic: "\($base)/\($id)/attributes",
            availability_topic: $avail,
            icon: "mdi:harddisk",
            device: {
                identifiers: ["native_mount_\($id)"],
                name: $name,
                manufacturer: "Native Mount",
                model: "External drive mount",
                sw_version: $ver
            },
            origin: {
                name: "Native Mount",
                sw_version: $ver,
                support_url: "https://github.com/kael-shipman/ha-addon-native-mount"
            }
        }')
    mqtt_pub "${DISCOVERY_PREFIX}/sensor/native_mount_${id}/config" "${config}"
}

# Clear retained discovery/state for mounts that were removed from the config,
# so HA deletes their entities instead of leaving orphans.
cleanup_removed_mounts() {
    local current="$1"
    [ -f "${PUBLISHED_IDS_FILE}" ] || return 0
    local id rc=0
    while IFS= read -r id; do
        [ -z "${id}" ] && continue
        if ! grep -qx "${id}" <<<"${current}"; then
            log_info "removing entity for unconfigured mount ${id}"
            mqtt_pub "${DISCOVERY_PREFIX}/sensor/native_mount_${id}/config" "" \
                && mqtt_pub "${BASE_TOPIC}/${id}/state" "" \
                && mqtt_pub "${BASE_TOPIC}/${id}/attributes" "" \
                || { log_warning "failed to clear entity for ${id} — will retry next start"; rc=1; }
        fi
    done <"${PUBLISHED_IDS_FILE}"
    return "${rc}"
}

# Publish mount state and disk usage.
update_entity() {
    local idx="$1" uuid="$2" mount_point="$3"
    local id; id=$(short_id "${uuid}")

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
    local attributes
    attributes=$(jq -nc \
        --arg uuid  "${uuid}" \
        --arg mp    "${mount_point}" \
        --arg dev   "${device}" \
        --arg tgb   "${total_gb}" \
        --arg ugb   "${used_gb}" \
        --arg pct   "${usage_pct}" \
        '{
            uuid:           $uuid,
            mount_point:    $mp,
            device:         (if $dev == "" then null else $dev end),
            total_gb:       (if $tgb == "" then null else ($tgb | tonumber) end),
            used_gb:        (if $ugb == "" then null else ($ugb | tonumber) end),
            usage_percent:  (if $pct == "" then null else ($pct | tonumber) end)
        }')

    # Attributes first, so a state-triggered automation sees fresh attributes.
    if mqtt_pub "${BASE_TOPIC}/${id}/attributes" "${attributes}" \
        && mqtt_pub "${BASE_TOPIC}/${id}/state" "${state}"; then
        local summary="${state}"
        [ "${state}" = "mounted" ] && summary="${state}, ${used_gb} / ${total_gb} GB (${usage_pct}%)"
        # Only log changes; a once-a-minute heartbeat would drown the log.
        if [ "${summary%%,*}" != "${LAST_STATE[${idx}]:-}" ]; then
            log_info "[${idx}] sensor.native_mount_${id}: ${summary}"
            LAST_STATE[${idx}]="${state}"
        fi
    else
        log_warning "[${idx}] failed to publish state for sensor.native_mount_${id} — broker unreachable?"
    fi
}

declare -a LAST_STATE=()

update_all_entities() {
    local count="$1"
    for i in $(seq 0 $((count - 1))); do
        update_entity "${i}" \
            "$(jq -r ".mounts[${i}].device_uuid" "${CONFIG}")" \
            "$(jq -r ".mounts[${i}].mount_point"  "${CONFIG}")"
    done
}

# ── Main ───────────────────────────────────────────────────────────────────────

log_info "starting (version ${VERSION})"

mount_count=$(jq 'if .mounts then .mounts | length else 0 end' "${CONFIG}")
log_info "${mount_count} mount(s) configured"

# ── Mount phase ────────────────────────────────────────────────────────────────
# Runs first and independently of MQTT: the add-on starts at the initialize
# stage, before the broker exists, and mounting must not wait on it.

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
        continue
    fi

    log_info "[${i}] device found after ${elapsed}s ($(blkid -U "${uuid}"))"

    if nsenter --mount=/proc/1/ns/mnt -- findmnt -n "${mount_point}" >/dev/null 2>&1; then
        log_info "[${i}] ${mount_point} is already mounted — skipping"
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
    else
        log_error "[${i}] mount failed (exit ${mount_exit}): ${mount_out}"
    fi
done

# ── Entity publishing (MQTT discovery) ─────────────────────────────────────────

wait_for_mqtt
start_will_holder

current_ids=""
for i in $(seq 0 $((mount_count - 1))); do
    current_ids+="$(short_id "$(jq -r ".mounts[${i}].device_uuid" "${CONFIG}")")"$'\n'
done
# Only forget old IDs once their entities are actually cleared.
if cleanup_removed_mounts "${current_ids}"; then
    printf '%s' "${current_ids}" >"${PUBLISHED_IDS_FILE}"
fi

publish_all_discovery() {
    local count="$1"
    for i in $(seq 0 $((count - 1))); do
        publish_discovery \
            "$(jq -r ".mounts[${i}].device_uuid" "${CONFIG}")" \
            "$(jq -r ".mounts[${i}].mount_point"  "${CONFIG}")" \
            || log_warning "[${i}] failed to publish discovery config — broker unreachable?"
    done
}

if [ "${mount_count}" -eq 0 ]; then
    log_info "no mounts configured — nothing to report"
else
    log_info "publishing discovery config for ${mount_count} mount(s)"
fi

log_info "entering update loop (every ${ENTITY_UPDATE_INTERVAL}s; state changes are logged)"
while true; do
    # Re-assert everything each cycle (all retained, QoS 0, cheap), so a broker
    # that lost its retained store — or an HA that missed it — self-heals within
    # one interval. HA ignores repeated identical discovery configs.
    mqtt_pub "${AVAILABILITY_TOPIC}" "online" 2>/dev/null || true
    if [ "${mount_count}" -gt 0 ]; then
        publish_all_discovery "${mount_count}"
        update_all_entities "${mount_count}"
    fi
    # sleep in the background so the TERM trap fires promptly.
    sleep "${ENTITY_UPDATE_INTERVAL}" & wait $!
done
