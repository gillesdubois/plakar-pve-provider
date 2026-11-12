# plakar-pve-provider

Proxmox VE backup provider for [Plakar](https://plakar.io).

It lets Plakar back up your QEMU VMs while they keep running. The provider stores nothing
itself: listing, retention and restore are done from Plakar.

For internals (backup flow, protocol, development), see [TECHNICAL.md](TECHNICAL.md).

## Requirements

- Proxmox VE 8.4 or later.
- The Plakar Proxmox integration (`proxmox+backup` importer).
- Only QEMU VMs go through the provider. Containers are backed up directly by the Plakar
  integration.

## Installation

1. Download the latest `.deb` from the
   [releases page](https://github.com/gillesdubois/plakar-pve-provider/releases).

2. On **every node** of the cluster, install it:

   ```sh
   apt install ./plakar-pve-provider_<version>_all.deb
   ```

3. Declare the storage **once** (the configuration is shared by the cluster):

   ```sh
   pvesm add plakar plakar --content backup
   ```

   This adds the following entry to `/etc/pve/storage.cfg`:

   ```
   plakar: plakar
       content backup
   ```

## Usage

Backups and restores are started from Plakar, not from Proxmox. Once the storage exists, point
the Plakar Proxmox integration at your node and use it as usual.
