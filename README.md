# Native Mount — Home Assistant Add-on

Mounts one or more external drives (USB, NVMe, etc.) directly into the host
filesystem at boot and publishes a mount-state entity for each one (via MQTT
discovery), so Home Assistant automations can start (and stop) anything that
depends on the drive.

> **Requires an MQTT broker** — see [Dependencies](#dependencies).

[![Add repository to Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fkael-shipman%2Fha-addon-native-mount)

---

## Why this exists

Home Assistant OS mounts add-on containers with restricted, read-only-from-the-
host mount namespaces. This means you cannot persistently mount an external drive
using `/etc/fstab` (read-only on HA OS), systemd unit files (also read-only), or
udev rules (which run in a separate, isolated mount namespace). Drives you mount
from inside an add-on container are invisible to the host and to other add-ons.

This add-on works around all of those restrictions by using `nsenter` to perform
mounts directly inside the host's mount namespace, making them visible system-wide
— exactly as if you had SSH'd into the box and run `mount` manually.

---

## The pattern: mount entity → dependent add-on

The add-on does exactly two things:

1. **Mounts** each configured drive at boot.
2. **Publishes** a `sensor.native_mount_<uuid8>` entity per mount, with state
   `mounted` or `unmounted`, through MQTT discovery.

Everything that *depends* on a drive — starting Frigate once its recording disk
is present, stopping it if the disk disappears, alerting on low space — is an
ordinary Home Assistant automation driven by that entity. The add-on itself
never starts, stops, or otherwise manages other add-ons.

Why not have the add-on start dependents directly? The Supervisor rejects
add-on start requests ("Supervisor is not ready") until it finishes its own
boot sequence, which happens *after* every startup stage has run — including
HA Core and `application`-stage add-ons. This add-on runs at the `initialize`
stage, so any start command it issued would land inside that window and fail,
with no good place to retry. An HA automation has the same constraint (Core,
and therefore the mount entity, also come up before the Supervisor is ready),
but automations can retry declaratively, report failures in traces, and keep
the dependency visible and editable in HA instead of buried in add-on options.

### Recommended setup for a dependent add-on

1. Set the dependent add-on (e.g. Frigate) to **`boot: manual`** (*Settings →
   Add-ons → Frigate → Start on boot: off*). This guarantees it never starts
   before its drive is mounted. Do **not** rely on `boot: auto` plus startup
   stage ordering — the Supervisor does not wait for `initialize`-stage add-ons
   to finish their work before starting later stages, so a slow-to-appear drive
   can lose that race.
2. Add an automation that starts the add-on when the drive is mounted (below).
3. Optionally, add an automation that stops it if the drive goes away.

---

## Common use case: Frigate NVR recordings on an external drive

If you run [Frigate](https://github.com/blakeblackshear/frigate) and your internal
storage fills up with recordings, the natural fix is to point Frigate at an
external USB or NVMe drive. Frigate reads its recordings from
`/media/frigate/recordings` (which maps to
`/mnt/data/supervisor/media/frigate/recordings` on the host).

**Add-on configuration:**

```yaml
mounts:
  - device_uuid: "f2f5ddc6-cc98-4bee-ab6e-664edf55c426"  # your drive's UUID
    mount_point: /mnt/data/supervisor/media/frigate
    fstype: ext4
    wait_timeout: 30
```

**Start Frigate once the drive is mounted** (Frigate set to `boot: manual`).
Both triggers matter: at boot the entity is often restored before automations
are armed, so only `homeassistant: start` catches it; the state trigger covers
a drive that mounts later. The entity also typically appears before the
Supervisor will accept start requests, so the start is retried every 30 s for
up to ~10 min:

```yaml
alias: Frigate – Start When Drive Mounted
mode: single
max_exceeded: silent
triggers:
  - trigger: homeassistant
    event: start
  - trigger: state
    entity_id: sensor.native_mount_f2f5ddc6
    to: mounted
conditions:
  - condition: state
    entity_id: sensor.native_mount_f2f5ddc6
    state: mounted
  - condition: state
    entity_id: switch.frigate
    state: "off"
actions:
  - repeat:
      sequence:
        - action: switch.turn_on
          target:
            entity_id: switch.frigate
          continue_on_error: true   # "Supervisor is not ready" during boot
        - delay: { seconds: 30 }
        # The Supervisor integration polls slowly; force a fresh read.
        - action: homeassistant.update_entity
          target:
            entity_id: switch.frigate
        - delay: { seconds: 10 }
      until:
        - condition: or
          conditions:
            - condition: state
              entity_id: switch.frigate
              state: "on"
            - "{{ repeat.index >= 15 }}"
```

**Stop Frigate if the drive goes away** (optional, but prevents Frigate from
silently writing recordings to the empty mount-point directory on your internal
disk):

```yaml
alias: Frigate – Stop When Drive Unmounted
mode: single
triggers:
  - trigger: state
    entity_id: sensor.native_mount_f2f5ddc6
    to: unmounted
actions:
  - action: switch.turn_off
    target:
      entity_id: switch.frigate
```

> **`switch.frigate`** is the Supervisor integration's per-add-on switch. It is
> **disabled by default** — enable it under *Settings → Devices & services →
> Supervisor → Frigate → entities*. Alternatively use the
> `hassio.addon_start` / `hassio.addon_stop` actions with
> `addon: ccab4aaf_frigate` (the slug is visible in the add-on store URL).

> **Tip:** Find your drive's UUID by SSH-ing into HA (`ssh -p 22222 root@<ha-ip>`)
> and running `blkid`. Look for your drive's label or size to identify it.

---

## Dependencies

| Dependency | Why | How to get it |
|---|---|---|
| **An MQTT broker** registered with the Supervisor | Entities are published via MQTT discovery; the add-on finds the broker and its credentials through the Supervisor's `mqtt` service | Install the official **Mosquitto broker** app (*Settings → Apps → App store → Mosquitto broker*), start it, and enable *Start on boot* |
| **The MQTT integration** in Home Assistant, with discovery enabled | Turns the add-on's discovery messages into entities | Installing the Mosquitto app prompts HA to set this up — accept it under *Settings → Devices & services*. Discovery is on by default with the `homeassistant` prefix; this add-on assumes that prefix |

No other add-ons, integrations, or HACS components are needed. Without a broker,
drives are still **mounted** normally — only the entities are missing — and the
add-on logs `waiting for MQTT broker...` once a minute until one appears.

---

## Installing

Install the [dependencies](#dependencies) first, then:

**Option A — one-click:**

Click the button at the top of this page to add the repository, then find
**Native Mount** in the add-on store and install it.

**Option B — manual:**

In Home Assistant go to **Settings → Add-ons → Add-on Store → ⋮ → Repositories**
and add:

```
https://github.com/kael-shipman/ha-addon-native-mount
```

Then find **Native Mount** in the store and install it.

---

## Configuration reference

```yaml
mounts:
  - device_uuid: "f2f5ddc6-cc98-4bee-ab6e-664edf55c426"
    mount_point: /mnt/data/supervisor/media/frigate
    fstype: ext4          # optional — omit for auto-detect
    wait_timeout: 30      # optional — seconds to wait for the device, default 30
```

### Option details

| Option | Required | Default | Description |
|---|---|---|---|
| `mounts` | Yes | `[]` | List of drives to mount. Each produces one entity. |
| `mounts[].device_uuid` | Yes | — | Filesystem UUID of the partition (`blkid` output). |
| `mounts[].mount_point` | Yes | — | Absolute host path to mount onto. Must exist before the add-on runs — create it once from a host SSH session. |
| `mounts[].fstype` | No | auto | Filesystem type (`ext4`, `exfat`, `ntfs`, etc.). Omit for auto-detection. |
| `mounts[].wait_timeout` | No | 30 | Seconds to wait for the device to appear. USB drives may take a few seconds on boot. |

### Upgrading from 3.x

Version 4.0.0 publishes entities via MQTT discovery instead of writing directly
to Home Assistant's state machine, so it now requires an MQTT broker (see
[Dependencies](#dependencies)). Entity IDs, state values and attribute names are
unchanged, so existing automations keep working — **provided the new entity
gets the same ID**. Because the old 3.x entity lingers in HA's state machine
until Core restarts, upgrade in this order:

1. Stop the Native Mount add-on (your drives stay mounted).
2. Restart Home Assistant Core (*Settings → System → Restart*). This clears the
   old entity.
3. Update Native Mount to 4.x and start it.

If you skip this and end up with `sensor.native_mount_<uuid8>_2`, restart Core
(to clear the old entity), then rename the new one back under
*Settings → Devices & services → Entities*.

### Upgrading from 2.x

Version 3.0.0 removes `mounts[].on_success`, `mounts[].on_failure` and
`post_mount_ha_commands`, along with the in-container `ha addons` wrapper they
relied on. Delete those keys from your add-on configuration and replace any
`ha addons start|stop` commands with automations as shown in
[The pattern](#the-pattern-mount-entity--dependent-add-on). The add-on also no
longer requests Supervisor `manager` API access.

### Finding your partition UUID

From a host SSH session (`ssh -p 22222 root@<your-ha-ip>`):

```bash
blkid
```

Look for your drive by label, size, or type. The `UUID=` value is what you need.

---

## Mount state entities

For each configured mount, the add-on publishes a `sensor` entity via MQTT
discovery and refreshes it every 60 seconds. Each mount also gets its own
device ("Native Mount: <mount-point name>"), so the entity is a normal,
registry-backed HA entity: you can rename it, assign it an area, and label it.

### Entity details

| Field | Value |
|---|---|
| **Entity ID** | `sensor.native_mount_<first 8 hex chars of UUID>` e.g. `sensor.native_mount_f2f5ddc6` |
| **Unique ID** | `native_mount_<first 8 hex chars of UUID>` |
| **State** | `mounted`, `unmounted`, or `unavailable` (add-on not running) |
| **Attributes** | `uuid`, `mount_point`, `device`, `total_gb`, `used_gb`, `usage_percent` |
| **Update interval** | Every 60 seconds (first publish as soon as the broker is reachable) |
| **Icon** | `mdi:harddisk` |

MQTT topics (all retained), for debugging with *Settings → Devices & services →
MQTT → Configure → Listen to a topic* (`native_mount/#`):

| Topic | Payload |
|---|---|
| `homeassistant/sensor/native_mount_<id>/config` | Discovery config |
| `native_mount/<id>/state` | `mounted` / `unmounted` |
| `native_mount/<id>/attributes` | JSON attributes |
| `native_mount/status` | `online` / `offline` (availability, shared by all mounts) |

### Timing semantics (important for automations)

- **Boot and Core restarts:** the entity reappears with its current state
  within a few seconds of HA's MQTT integration connecting (the broker replays
  the retained messages). This can happen **before automations are armed**, in
  which case a `to: mounted` state trigger never sees the change. Any
  automation that must act on the mount at startup therefore needs a
  `homeassistant: start` trigger plus a `state: mounted` condition (as in the
  [Frigate example](#common-use-case-frigate-nvr-recordings-on-an-external-drive)),
  with the state trigger covering mounts that appear later.
- **Add-on stopped or crashed:** the entity becomes `unavailable` (graceful
  shutdown publishes `offline`; a crash triggers the broker-held last will).
  When the add-on comes back, `unavailable` → `mounted` also fires `to: mounted`.
- **Detection latency:** an unplugged drive is reported as `unmounted` within
  60 seconds.
- **Repeat updates of an unchanged state do not re-fire state triggers.**

### Alert when storage is getting full

Replace `82` with your preferred threshold:

```yaml
alias: Frigate Drive – Storage High Warning
triggers:
  - trigger: numeric_state
    entity_id: sensor.native_mount_f2f5ddc6
    attribute: usage_percent
    above: 82
actions:
  - action: persistent_notification.create
    data:
      title: Drive Storage Warning
      message: >
        Frigate drive usage has reached
        {{ state_attr('sensor.native_mount_f2f5ddc6', 'usage_percent') }}%
        — consider freeing space or expanding storage.
```

---

## Startup ordering

This add-on runs at the `initialize` startup stage, the earliest one available
to add-ons:

| Stage | Examples |
|---|---|
| `initialize` | This add-on |
| `system` | DNS, audio, etc. |
| `services` | MQTT, databases |
| `application` | Frigate, Node-RED, custom add-ons |
| `once` | One-shot scripts |

Mounting starts before any later-stage add-on, but the Supervisor only waits for
this add-on's *container* to start, not for its mounts to finish. That is why
dependents should be `boot: manual` and started from the entity, as described
in [The pattern](#the-pattern-mount-entity--dependent-add-on).

Note also that the Supervisor integration's `switch.<addon>` entities poll
infrequently, and their first snapshot at boot is taken before
`application`-stage add-ons have started. Anything that reacts to those
switches right after boot (start retries, health alerts) should force a
refresh with `homeassistant.update_entity` before trusting an `off` state.

### Idempotency

The add-on is safe to run multiple times. If the mount point is already occupied
when the add-on runs (which can happen because the HA Supervisor runs
`initialize`-stage add-ons more than once during boot), the mount is skipped.

---

## How it works

HA OS runs add-on containers with private, isolated mount namespaces. Normally
this means mounts made inside a container are invisible to the host. This add-on
works around that by:

1. Using `host_pid: true` so `/proc/1` inside the container refers to the **host's
   PID 1** (systemd), giving access to `/proc/1/ns/mnt` — the host's mount
   namespace file descriptor.

2. Using `nsenter --mount=/proc/1/ns/mnt -- mount ...` to enter the host's mount
   namespace before running `mount`, so the result is visible to all host
   processes and other add-on containers.

3. Polling for the device using `blkid -U <uuid>` (reads device headers directly;
   does not depend on udev symlinks being created yet at `initialize` time).

### Security posture

This add-on requires elevated privileges in order to perform host-level mounts:

| Setting | Why |
|---|---|
| `host_pid: true` | Exposes host process tree so `/proc/1/ns/mnt` resolves to the host's mount namespace |
| `apparmor: false` | The default AppArmor profile blocks access to `/proc/PID/ns/` files; disabling it allows `nsenter` to work |
| `privileged: [SYS_ADMIN]` | Required to call `mount(2)` |
| `privileged: [SYS_PTRACE]` | Required to open `/proc/1/ns/mnt` (a ptrace-protected file) |
| `full_access: true` | Exposes host block devices (e.g. `/dev/sdb1`) inside the container for device detection |
| `services: [mqtt:want]` | Lets the add-on read the broker's address and credentials from the Supervisor's `mqtt` service |

These are the minimum permissions needed for the add-on to function. The add-on
talks only to the Supervisor's `mqtt` service endpoint and to the MQTT broker,
and only reads/writes the mount points you configure. It has no access to the
Home Assistant Core API, nor to the Supervisor API for managing other add-ons.

---

## Troubleshooting

**Device not found after timeout**

The add-on logs all visible block devices when a device times out. Check that your
drive's UUID in the config matches the `UUID=` value shown in the log output.
Also ensure the drive is physically connected and powered before HA boots.

**Mount failed: permission denied**

Verify that all required settings are present in the add-on configuration:
`host_pid: true`, `apparmor: false`, `privileged: [SYS_ADMIN, SYS_PTRACE]`. If
you installed from the repository these are set automatically.

**Mount failed: already mounted**

This should not occur in normal operation (the add-on checks for an existing mount
before trying). If it does, SSH into the host and run `findmnt <mount_point>` to
see what is already there.

**Entity missing or `unavailable`**

- Check this add-on's log. `waiting for MQTT broker...` means no broker is
  registered or reachable — see [Dependencies](#dependencies). A line like
  `sensor.native_mount_<id>: mounted, …` means publishing works.
- Confirm the MQTT integration is set up and loaded, and listen to
  `native_mount/#` (see [Mount state entities](#mount-state-entities)) to see
  what the broker holds.
- If the entity exists as `sensor.native_mount_<id>_2`, see
  [Upgrading from 3.x](#upgrading-from-3x).

**Dependent add-on (e.g. Frigate) not starting after boot**

Check that:
- The mount entity shows `mounted` (*Developer tools → States*). If not, see
  *Entity missing or `unavailable`* above.
- Your start automation exists, is enabled, and its trace shows it ran after
  boot.
- If you use the `switch.<addon>` entity, it is enabled (it is disabled by
  default).
- The dependent add-on is not in an error state for unrelated reasons (check
  its own logs).

---

## Limitations

- Mounts do not survive a reboot on their own — this add-on re-mounts on every
  boot, which is the intended behavior.
- The `mount_point` directory must already exist on the host before the add-on
  runs. Create it once via `mkdir -p <path>` from a host SSH session.
- The add-on does not manage other add-ons. Sequencing dependents is done with
  Home Assistant automations driven by the mount entities.
- Entities require an MQTT broker and HA's MQTT integration (see
  [Dependencies](#dependencies)). The MQTT discovery prefix is assumed to be the
  default, `homeassistant`.

---

## Design notes: why MQTT discovery

*Background for maintainers and the curious; nothing here is needed to use the
add-on.*

### The problem with writing states directly

Versions up to 3.x created entities by `POST`ing to Core's REST API
(`/api/states/<entity_id>`) through the Supervisor proxy. That call writes a
value into Core's in-memory **state machine** and nothing else: no integration
owns the entity, so it has no entity-registry entry, no unique ID, no device,
and — crucially — it isn't covered by HA's `RestoreEntity` mechanism, which
only restores state for integration-owned entities. A Core restart therefore
wiped the entity until the add-on's next push (up to 15 minutes later). It also
meant the entity couldn't be renamed, labelled or assigned an area in the UI,
and each proxied write produced a spurious "Login attempt with invalid
authentication" notification
([issue #1](https://github.com/kael-shipman/ha-addon-native-mount/issues/1)).

### Options considered

| Option | Survives Core restart | Real (registry) entity | New dependency | Verdict |
|---|---|---|---|---|
| Keep REST writes, republish when the entity goes missing | After a short gap (poll interval) | No | None | Treats the symptom; issue #1 remains |
| **MQTT discovery with retained messages** | **Immediately** | **Yes** | MQTT broker | **Chosen** |
| Ship a custom integration (via HACS) alongside the add-on | Yes | Yes | A second component to install and version in lock-step | Too heavy for one sensor per drive |

MQTT discovery is Home Assistant's standard way for an external process to
declare entities. Most installs that run add-ons already have the Mosquitto
broker, and the Supervisor exposes its credentials to add-ons through the
`mqtt` service, so no user configuration is needed.

### How the MQTT pieces fit together

- **Retained messages are the persistence layer.** Discovery config, state,
  attributes and availability are all published with the retain flag, so the
  broker always holds the latest values. When HA's MQTT integration (re)connects
  it receives them immediately and rebuilds the entity — no polling, no gap.
- **The registry entry is owned by HA's MQTT integration**, keyed by
  `unique_id`. `default_entity_id` asks HA for `sensor.native_mount_<id>`; HA
  honours it only if that ID is free, otherwise it appends a suffix (hence the
  [upgrade ordering](#upgrading-from-3x)).
- **One device per mount** (`name: null` on the entity) keeps the friendly name
  as "Native Mount: <mount-point name>" and gives each drive its own place in
  the device list.
- **Availability via last will.** `mosquitto_pub` is a one-shot client, so it
  can't carry a last-will message. The add-on therefore keeps one long-lived
  `mosquitto_sub` connection open purely to hold the will (`native_mount/status`
  → `offline`, retained). If the container dies, the broker publishes it; on a
  clean shutdown the add-on publishes `offline` itself. `mosquitto_sub`
  reconnects on its own after a broker restart, re-registering the will.
- **Self-healing.** Every 60-second cycle re-publishes availability, discovery
  config, state and attributes. If the broker loses its retained store (e.g.
  persistence disabled) or HA misses a message, everything is back within one
  cycle. HA ignores repeated identical discovery configs, so this is free.
- **QoS 0 for publishes.** Each publish is a short-lived connection ending in a
  clean MQTT `DISCONNECT`, so the broker has the message by the time the client
  exits; QoS 1 would only add a fixed ~1 s acknowledgement wait per message.
  The last will uses QoS 1.
- **Orphan cleanup.** The add-on records the mount IDs it published in
  `/data/published_ids`. On start, any ID no longer in the configuration has
  its retained topics cleared (empty payloads), which makes HA delete the
  entity instead of leaving an orphan. The record is only updated once the
  clearing succeeds.

### Why `mqtt:want` and not `mqtt:need`

The add-on must run at the `initialize` stage so drives are mounted before
anything else starts — but the Mosquitto broker is a `services`-stage add-on,
so it isn't running yet at that point. `need` declares a hard dependency that
the Supervisor may enforce by refusing to start this add-on when no broker is
registered — which would also block the mounts. `want` declares the same
access without the hard dependency: the add-on starts, mounts immediately, and
then waits (retrying every 10 s) for the broker before publishing. Mounting
never depends on MQTT.

### Why not the Core API at all any more

Dropping the REST writes removes the `homeassistant_api` permission, the
Core-readiness polling loop, and the spurious authentication notifications.
The add-on now touches only the Supervisor's `mqtt` service endpoint and the
broker.

---

## Contributing / development

The repository layout is standard for HA custom add-on repositories:

```
ha-addon-native-mount/
├── repository.yaml          # Repository metadata (name, URL, maintainer)
└── native-mount/
    ├── config.yaml          # Add-on configuration and schema
    ├── Dockerfile           # Container build definition
    └── run.sh               # Main add-on logic
```

To iterate locally: push a version bump to GitHub, then from a host SSH session
run `ha store reload && ha apps update <slug>` to pull and rebuild. The slug is
visible in the add-on store URL (e.g. `2e6ea408_native_mount` for this
repository).
