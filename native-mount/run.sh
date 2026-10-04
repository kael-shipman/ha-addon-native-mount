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

# Discovery object IDs published for each mount. Also drives orphan cleanup, so
# every entity a mount owns must be listed here.
#   ""            → sensor.native_mount_<id>             (mounted / unmounted)
#   _disk_used    → sensor.native_mount_<id>_disk_used   (GiB)
#   _disk_total   → sensor.native_mount_<id>_disk_total  (GiB)
#   _disk_usage   → sensor.native_mount_<id>_disk_usage  (%)
ENTITY_SUFFIXES=("" "_disk_used" "_disk_total" "_disk_usage")

# Retained discovery configs: HA's MQTT integration creates registry-backed
# entities (sharing one device per mount) from these and recreates them after
# every Core restart.
publish_discovery() {
    local uuid="$1" mount_point="$2"
    local id; id=$(short_id "${uuid}")
    local label; label=$(basename "${mount_point}")
    local state_topic="${BASE_TOPIC}/${id}/state"
    local usage_topic="${BASE_TOPIC}/${id}/usage"

    local common
    common=$(jq -nc \
        --arg id "${id}" \
        --arg name "Native Mount: ${label}" \
        --arg ver "${VERSION}" \
        '{
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

    # Mount state. Its name is null, so it takes the device name.
    local mount_config
    mount_config=$(jq -nc \
        --argjson common "${common}" \
        --arg id "${id}" \
        --arg state "${state_topic}" \
        --arg attrs "${BASE_TOPIC}/${id}/attributes" \
        --arg avail "${AVAILABILITY_TOPIC}" \
        '$common + {
            name: null,
            unique_id: "native_mount_\($id)",
            default_entity_id: "sensor.native_mount_\($id)",
            state_topic: $state,
            json_attributes_topic: $attrs,
            availability_topic: $avail,
            icon: "mdi:harddisk"
        }')
    mqtt_pub "${DISCOVERY_PREFIX}/sensor/native_mount_${id}/config" "${mount_config}" || return 1

    # Disk sensors. Available only while the add-on is online AND the drive is
    # mounted, so an unplugged drive reads "unavailable", never a stale number.
    local spec suffix name key unit device_class icon cfg
    for spec in \
        "_disk_used|Disk used|used|GiB|data_size|mdi:harddisk" \
        "_disk_total|Disk total|total|GiB|data_size|mdi:harddisk" \
        "_disk_usage|Disk usage|percent|%||mdi:gauge"; do
        IFS='|' read -r suffix name key unit device_class icon <<<"${spec}"
        cfg=$(jq -nc \
            --argjson common "${common}" \
            --arg id "${id}" \
            --arg suffix "${suffix}" \
            --arg name "${name}" \
            --arg key "${key}" \
            --arg unit "${unit}" \
            --arg dc "${device_class}" \
            --arg icon "${icon}" \
            --arg usage "${usage_topic}" \
            --arg state "${state_topic}" \
            --arg avail "${AVAILABILITY_TOPIC}" \
            '$common + {
                name: $name,
                unique_id: "native_mount_\($id)\($suffix)",
                default_entity_id: "sensor.native_mount_\($id)\($suffix)",
                state_topic: $usage,
                value_template: "{{ value_json.\($key) }}",
                unit_of_measurement: $unit,
                state_class: "measurement",
                suggested_display_precision: 1,
                icon: $icon,
                availability: [
                    { topic: $avail },
                    { topic: $state, payload_available: "mounted", payload_not_available: "unmounted" }
                ],
                availability_mode: "all"
            } + (if $dc == "" then {} else { device_class: $dc } end)')
        mqtt_pub "${DISCOVERY_PREFIX}/sensor/native_mount_${id}${suffix}/config" "${cfg}" || return 1
    done
}

# Empty retained payloads make HA delete the entities and the broker drop the data.
clear_mount_topics() {
    local id="$1" suffix topic
    for suffix in "${ENTITY_SUFFIXES[@]}"; do
        mqtt_pub "${DISCOVERY_PREFIX}/sensor/native_mount_${id}${suffix}/config" "" || return 1
    done
    for topic in state usage attributes; do
        mqtt_pub "${BASE_TOPIC}/${id}/${topic}" "" || return 1
    done
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
            log_info "removing entities for unconfigured mount ${id}"
            if ! clear_mount_topics "${id}"; then
                log_warning "failed to clear entities for ${id} — will retry next start"
                rc=1
            fi
        fi
    done <"${PUBLISHED_IDS_FILE}"
    return "${rc}"
}

# Publish mount state and disk usage.
update_entity() {
    local idx="$1" uuid="$2" mount_point="$3"
    local id; id=$(short_id "${uuid}")

    local state="unmounted"
    local device="" total_gib="" used_gib="" usage_pct=""

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
            # df -k reports KiB; / 1048576 gives GiB.
            total_gib=$(awk "BEGIN{printf \"%.2f\", ${tkb}/1048576}")
            used_gib=$(awk  "BEGIN{printf \"%.2f\", ${ukb}/1048576}")
            usage_pct=$(awk "BEGIN{printf \"%.1f\", ${ukb}*100/${tkb}}")
        fi
    fi

    # Build JSON with jq so all values are properly escaped and typed.
    local attributes
    attributes=$(jq -nc \
        --arg uuid  "${uuid}" \
        --arg mp    "${mount_point}" \
        --arg dev   "${device}" \
        --arg tgb   "${total_gib}" \
        --arg ugb   "${used_gib}" \
        --arg pct   "${usage_pct}" \
        '{
            uuid:           $uuid,
            mount_point:    $mp,
            device:         (if $dev == "" then null else $dev end),
            total_gb:       (if $tgb == "" then null else ($tgb | tonumber) end),
            used_gb:        (if $ugb == "" then null else ($ugb | tonumber) end),
            usage_percent:  (if $pct == "" then null else ($pct | tonumber) end)
        }')

    # Disk usage for the disk sensors, only while mounted (otherwise the sensors
    # are unavailable via the state topic and keep their last retained value).
    local publish_ok=true
    if [ "${state}" = "mounted" ] && [ -n "${usage_pct}" ]; then
        local usage
        usage=$(jq -nc --arg u "${used_gib}" --arg t "${total_gib}" --arg p "${usage_pct}" \
            '{used: ($u | tonumber), total: ($t | tonumber), percent: ($p | tonumber)}')
        mqtt_pub "${BASE_TOPIC}/${id}/usage" "${usage}" || publish_ok=false
    fi

    # Data before state, so anything reacting to "mounted" sees fresh values.
    if [ "${publish_ok}" = true ] \
        && mqtt_pub "${BASE_TOPIC}/${id}/attributes" "${attributes}" \
        && mqtt_pub "${BASE_TOPIC}/${id}/state" "${state}"; then
        local summary="${state}"
        [ "${state}" = "mounted" ] && summary="${state}, ${used_gib} / ${total_gib} GiB (${usage_pct}%)"
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
