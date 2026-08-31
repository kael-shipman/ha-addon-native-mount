# Native Mount — Home Assistant Add-on

Mounts one or more external drives (USB, NVMe, etc.) directly into the host
filesystem at boot — before application-stage add-ons start — and optionally
runs commands after each mount succeeds or fails.

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

## Common use case: Frigate NVR recordings on an external drive

If you run [Frigate](https://github.com/blakeblackshear/frigate) and your internal
storage fills up with recordings, the natural fix is to point Frigate at an
external USB or NVMe drive. Frigate reads its recordings from
`/media/frigate/recordings` (which maps to
`/mnt/data/supervisor/media/frigate/recordings` on the host). The problem is that
Home Assistant OS provides no built-in, persistent way to mount an external drive
there before Frigate starts.

Native Mount solves this. Configure it with your drive's UUID and the mount point,
and it will mount the drive at the `initialize` startup stage — before Frigate
(which starts at the `application` stage) ever runs.

**Example configuration for Frigate:**

```yaml
mounts:
  - device_uuid: "f2f5ddc6-cc98-4bee-ab6e-664edf55c426"  # your drive's UUID
    mount_point: /mnt/data/supervisor/media/frigate
    fstype: ext4
    wait_timeout: 30
    on_success:
      - ha addons start ccab4aaf_frigate
post_mount_ha_commands: []
```

With this config, on every boot Native Mount will:
1. Wait up to 30 seconds for the drive to appear
2. Mount it at `/mnt/data/supervisor/media/frigate` in the host namespace
3. Start Frigate

> **Tip:** Find your drive's UUID by SSH-ing into HA (`ssh -p 22222 root@<ha-ip>`)
> and running `blkid`. Look for your drive's label or size to identify it.

> **Frigate add-on slug:** The slug in `ha addons start <slug>` is visible in the
> add-on store URL or in the Supervisor logs. For the community Frigate add-on it
> is typically `ccab4aaf_frigate`.

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
    on_success:           # optional — commands to run if mount succeeds
      - ha addons start ccab4aaf_frigate
    on_failure:           # optional — commands to run if mount fails or times out
      - ha addons stop ccab4aaf_frigate
post_mount_ha_commands:   # optional — commands to run after all mounts complete
  - ha addons restart core_mosquitto
```

### Option details

| Option | Required | Default | Description |
|---|---|---|---|
| `mounts` | Yes | `[]` | List of drives to mount. |
| `mounts[].device_uuid` | Yes | — | Filesystem UUID of the partition (`blkid` output). |
| `mounts[].mount_point` | Yes | — | Absolute host path to mount onto. Must exist before the add-on runs — create it once from a host SSH session. |
| `mounts[].fstype` | No | auto | Filesystem type (`ext4`, `exfat`, `ntfs`, etc.). Omit for auto-detection. |
| `mounts[].wait_timeout` | No | 30 | Seconds to wait for the device to appear. USB drives may take a few seconds on boot. |
| `mounts[].on_success` | No | `[]` | Shell commands to run if the mount succeeds (or was already mounted). Executed in order; a non-zero exit is logged as a warning and does not stop subsequent commands. |
| `mounts[].on_failure` | No | `[]` | Shell commands to run if the device is not found or the mount fails. |
| `post_mount_ha_commands` | No | `[]` | Commands to run after all mounts complete, regardless of individual mount outcomes. |

### Available commands

Commands run inside the add-on container. A thin `ha` wrapper is provided that
translates `ha addons start|stop|restart <slug>` into Supervisor API calls, so
you can use the same syntax you would from a host SSH session.

**Examples:**
```
ha addons start ccab4aaf_frigate
ha addons stop ccab4aaf_frigate
ha addons restart core_mosquitto
```

No other host-level commands are available from inside the container. If you need
to run arbitrary host commands, do so from a host SSH session or a separate
automation.

### Finding your partition UUID

From a host SSH session (`ssh -p 22222 root@<your-ha-ip>`):

```bash
blkid
```

Look for your drive by label, size, or type. The `UUID=` value is what you need.

---

## Startup ordering

This add-on runs at the `initialize` startup stage. Home Assistant add-ons run in
this order:

| Stage | Examples |
|---|---|
| `initialize` | This add-on |
| `system` | DNS, audio, etc. |
| `services` | MQTT, databases |
| `application` | Frigate, Node-RED, custom add-ons |
| `once` | One-shot scripts |

This means the drive will be mounted before Frigate (or any other `application`-
stage add-on) starts. If you set Frigate to `boot: auto`, it will already find
the drive mounted when it comes up — no `on_success` command needed. Use
`on_success` only if you want strict sequencing (e.g. you've set Frigate to
`boot: manual` and want this add-on to start it explicitly).

### Idempotency

The add-on is safe to run multiple times. If the mount point is already occupied
when the add-on runs (which can happen because the HA Supervisor runs
`initialize`-stage add-ons more than once during boot), the mount is skipped and
`on_success` commands are still executed.

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
| `hassio_role: manager` | Required to call the Supervisor API for `ha addons start/stop` |

These are the minimum permissions needed for the add-on to function. The add-on
performs no network access and only reads/writes the mount points you configure.

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

**Frigate not starting**

Check that:
- The `on_success` command uses the correct add-on slug (visible in the store URL
  or Supervisor logs).
- Frigate itself is not in an error state for unrelated reasons (check its own
  logs).
- The mount point directory exists on the host at the path you configured.

---

## Limitations

- Mounts do not survive a reboot on their own — this add-on re-mounts on every
  boot, which is the intended behavior.
- The `mount_point` directory must already exist on the host before the add-on
  runs. Create it once via `mkdir -p <path>` from a host SSH session.
- Commands in `on_success`, `on_failure`, and `post_mount_ha_commands` run inside
  the add-on container. Only `ha addons start|stop|restart <slug>` is supported;
  arbitrary host shell commands will not work.
- There is no native HA mechanism to declare add-on dependencies, so if a command
  references another add-on (e.g. Mosquitto for a future MQTT feature), that
  add-on must be installed separately. The add-on will log a clear error if a
  required add-on is not available.

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
run `ha store reload && ha apps update native_mount` to pull and rebuild.
