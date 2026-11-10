# plakar-pve-provider: technical details

Internals of the provider, for contributors and for the Plakar side of the integration.
To install and use the plugin, see the [README](README.md).

## What the package installs

- The Perl modules under `/usr/share/perl5/PVE/`:
  - `PVE/Storage/Custom/PlakarPlugin.pm`: the `plakar` storage type.
  - `PVE/BackupProvider/Plugin/Plakar.pm`: the backup provider.
- `/run/plakar` (root, 0700), recreated at every boot by a tmpfiles.d entry.
- On install, `pvedaemon`, `pveproxy`, `pvestatd` and `pvescheduler` are reloaded.

When `vzdump` targets the storage, QEMU exposes each VM disk as a consistent NBD export
(snapshot access with fleecing) and the provider hands those exports to Plakar.

## How a backup runs

1. Plakar listens on `/run/plakar/<session>.sock`. In SSH mode this is a remote Unix socket
   forward over the SSH connection. In local mode Plakar listens on it directly.
2. Plakar runs `PLAKAR_SESSION=<session> vzdump <vmid> --storage plakar`.
3. `job_init` fails immediately if `PLAKAR_SESSION` is missing or invalid, or if nobody listens
   on the socket.
4. `vzdump` freezes the guest, sets up snapshot access and exports each disk over NBD. The VM
   keeps running.
5. `backup_vm` connects to the socket, sends the manifest and blocks.
6. Plakar reads each disk through its NBD socket, stores it, then replies.
7. `backup_vm` returns on `ok` and dies on `error`, or if the connection closes without an
   answer. `vzdump` then tears down the snapshot.

### Protocol

One JSON line in each direction over the session socket.

Provider to Plakar:

```json
{
  "version": 2,
  "vmid": 100,
  "archive": "100/qemu-1730880000",
  "bandwidth-limit": 0,
  "guest-config": "<content of qemu-server/100.conf>",
  "firewall-config": "<content of firewall/100.fw>" | null,
  "devices": {
    "drive-scsi0": {
      "size": 34359738368,
      "nbd-path": "/run/qemu-server/100.backup-access.<id>/socket",
      "export": "drive-scsi0"
    }
  }
}
```

Plakar to provider:

```json
{"status": "ok"}
{"status": "error", "message": "..."}
```

`bandwidth-limit` is in bytes per second (0 means no limit). Plakar should discard
(NBD trim) the ranges it has read so the fleecing image does not grow.

## How a restore runs

Plakar prepares a session under `/run/plakar/<storeid>/restore/<vmid>-qemu-<time>/` with
`manifest.json`, `guest.conf`, an optional `firewall.conf` and one NBD socket per disk
(`<device>.sock`), then calls `qmrestore <storeid>:<vmid>/qemu-<time> <vmid>`. The provider
attaches each socket to a free `/dev/nbdX` with `qemu-nbd` and lets `qmrestore` copy it.

## Development

```sh
make test                    # Perl tests, PVE modules stubbed in t/lib
make deb VERSION=0.1.0       # builds plakar-pve-provider_0.1.0_all.deb
```

The tests need `perl` with core modules only. Building the package needs `dpkg-deb`.

CI (`.github/workflows/ci.yml`) runs the tests on every push and pull request. Only a `v*` tag
builds the `.deb` and publishes it in a GitHub release, with the version taken from the tag
(`v0.2.0` gives `0.2.0`).
