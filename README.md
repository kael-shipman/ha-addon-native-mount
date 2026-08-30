# Native Mount — Home Assistant Add-on

Mounts one or more configured block devices (USB drives, NVMe, etc.) directly
into the host filesystem at boot, before application-stage add-ons start.
Optionally runs post-mount shell commands (e.g. to start a dependent add-on).

## Why this exists

Home Assistant OS runs add-ons in Docker containers with restricted mount
namespaces. Persistent external drive mounts that need to be visible to other
add-ons (like Frigate writing recordings to a USB drive) cannot be set up from
within a normal add-on or via `fstab` (which is read-only on HA OS). This
add-on uses `nsenter` to perform mounts inside the host's mount namespace,
making them visible system-wide, exactly as if you had run `mount` from a host
SSH session.

## Installing

Click the button below to add this repository to your Home Assistant instance:

[![Add repository to Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2FTODO%2Fha-addon-native-mount)

Or manually: **Settings → Add-ons → Add-on Store → ⋮ → Repositories**, then
add:

```
https://github.com/TODO/ha-addon-native-mount
```

Once the repository is added, find **Native Mount** in the store and install it.

## Configuration

```yaml
mounts:
  - device_uuid: "f2f5ddc6-cc98-4bee-ab6e-664edf55c426"
    mount_point: /mnt/data/supervisor/media/frigate/.data
    fstype: ext4          # optional, defaults to auto-detect
    wait_timeout: 30      # optional, seconds to wait for device, default 30
post_mount_ha_commands:   # optional
  - ha addons start ccab4aaf_frigate
```

### Options

| Option | Required | Default | Description |
|---|---|---|---|
| `mounts` | Yes | `[]` | List of drives to mount. |
| `mounts[].device_uuid` | Yes | — | UUID of the partition to mount. Find it with `ls -la /dev/disk/by-uuid/` from a host SSH session (`ssh -p 22222 root@<ha-ip>`). |
| `mounts[].mount_point` | Yes | — | Absolute host path to mount onto. Must exist before the add-on runs. |
| `mounts[].fstype` | No | auto | Filesystem type passed to `mount -t`. Omit for auto-detection. |
| `mounts[].wait_timeout` | No | `30` | Seconds to wait for the device to appear before skipping. |
| `post_mount_ha_commands` | No | `[]` | Shell commands to run after all mounts complete. Runs inside the add-on container (not host shell), so use `ha addons start <slug>` rather than raw `mount` calls. |

### Finding your partition UUID

From a host SSH session:

```bash
ssh -p 22222 root@<your-ha-ip>
ls -la /dev/disk/by-uuid/
```

### Startup ordering and Frigate

This add-on starts at the `initialize` stage — before Frigate (which starts at
`application`). If you just want the drive mounted before Frigate auto-starts,
no `post_mount_ha_commands` are needed; simply configure the mount and leave
Frigate on its default `boot: auto` setting.

Use `post_mount_ha_commands` only if you want strict sequencing — e.g. you have
set Frigate to `boot: manual` and want this add-on to start it explicitly after
confirming the mount succeeded.

## How it works

1. At the `initialize` boot stage, the add-on polls
   `/proc/1/root/dev/disk/by-uuid/<UUID>` (the host's device tree, visible
   because `host_pid: true`) until the drive appears or the timeout expires.
2. Once the device is present, it runs:
   ```
   nsenter --mount=/proc/1/ns/mnt -- mount [options] UUID=<uuid> <mount_point>
   ```
   This enters the host's mount namespace (PID 1's namespace), so the mount is
   visible to all host processes and add-on containers.
3. Any configured `post_mount_ha_commands` are then executed in order.
4. The add-on exits cleanly. The mounts persist until the next reboot.

## Limitations

- Mounts do not survive a reboot on their own — this add-on re-mounts on every
  boot, which is the intended behavior.
- The `mount_point` directory must already exist on the host before the add-on
  runs. Create it once from a host SSH session.
- `post_mount_ha_commands` run inside the add-on container. Commands that
  require the host shell (e.g. raw `mount`, `ls /dev`) won't work there; use
  the HA Supervisor CLI (`ha addons ...`, `ha host ...`) instead.
