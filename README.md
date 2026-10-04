# Native Mount — Home Assistant Add-on

Mounts one or more external drives (USB, NVMe, etc.) directly into the host
filesystem at boot and publishes a mount-state entity for each one, so Home
Assistant automations can start (and stop) anything that depends on the drive.

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
   `mounted` or `unmounted`.

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
At boot the mount entity typically appears 10–60 s before the Supervisor will
accept start requests, so the start is retried every 30 s for up to ~10 min:

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

## Installing

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

After mounting, the add-on publishes a `sensor` entity to HA for each configured
mount and keeps it updated every 15 minutes. No additional add-ons or
dependencies are required — entity state is written directly to the HA Core state
machine via the Supervisor API.

### Entity details

| Field | Value |
|---|---|
| **Entity ID** | `sensor.native_mount_<first 8 hex chars of UUID>` e.g. `sensor.native_mount_f2f5ddc6` |
| **State** | `mounted` or `unmounted` |
| **Attributes** | `uuid`, `mount_point`, `device`, `total_gb`, `used_gb`, `usage_percent` |
| **Update interval** | Every 15 minutes (first publish as soon as HA Core is ready) |
| **Icon** | `mdi:harddisk` |

### Timing semantics (important for automations)

- **First publish:** at boot, the entity appears as soon as HA Core is
  responding (the add-on polls Core every 15 s). Its first appearance as
  `mounted` is a state change, so a `to: mounted` trigger fires on every boot.
- **Not restored across Core restarts:** the entity is written directly to the
  state machine, not registered by an integration, so it is absent after a
  Core-only restart until the next 15-minute update. Automations should
  therefore trigger on the state *change* (as above) rather than assume the
  entity exists at `homeassistant: start`.
- **Detection latency:** an unplugged drive is reported as `unmounted` at the
  next update, i.e. within 15 minutes.
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
| `homeassistant_api: true` | Required to proxy entity state writes to the HA Core REST API |

These are the minimum permissions needed for the add-on to function. The add-on
performs no network access beyond the local Supervisor proxy to the Core API,
and only reads/writes the mount points you configure. It has no access to the
Supervisor API for managing other add-ons.

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

**Dependent add-on (e.g. Frigate) not starting after boot**

Check that:
- The mount entity shows `mounted` (*Developer tools → States*). If it is
  missing, check this add-on's log for the "HA Core ready" and entity update
  lines.
- Your start automation exists, is enabled, and its trace shows it ran after
  boot.
- If you use the `switch.<addon>` entity, it is enabled (it is disabled by
  default).
- The dependent add-on is not in an error state for unrelated reasons (check
  its own logs).

**"Login attempt with invalid authentication" notification**

After entity state updates, HA Core may show a notification about an invalid
authentication attempt from the add-on's container IP. This is a known audit
artifact of the Supervisor proxy mechanism — the entity state **is** published
correctly, and no security breach has occurred. See
[issue #1](https://github.com/kael-shipman/ha-addon-native-mount/issues/1) for
context and planned fixes.

---

## Limitations

- Mounts do not survive a reboot on their own — this add-on re-mounts on every
  boot, which is the intended behavior.
- The `mount_point` directory must already exist on the host before the add-on
  runs. Create it once via `mkdir -p <path>` from a host SSH session.
- The add-on does not manage other add-ons. Sequencing dependents is done with
  Home Assistant automations driven by the mount entities.
- Each entity state update generates a "Login attempt with invalid authentication"
  notification in HA Core. This is a cosmetic audit artifact of the Supervisor's
  Core API proxy mechanism — entity data is correct and no actual auth failure
  occurs. See [issue #1](https://github.com/kael-shipman/ha-addon-native-mount/issues/1).

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
