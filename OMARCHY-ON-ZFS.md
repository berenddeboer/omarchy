# Omarchy On ZFS

This branch adds and verifies initial support for installing Omarchy on an Arch Linux system whose root filesystem is ZFS instead of Btrfs.

## What Changed

- The installer preflight guard now accepts either `btrfs` or `zfs` as the root filesystem.
- Omarchy pacman configuration now preserves an existing `[archzfs]` repository when replacing `/etc/pacman.conf`.
- Limine setup now detects the root filesystem type:
  - On Btrfs, it keeps the existing Snapper integration and Btrfs mkinitcpio hook setup.
  - On ZFS, it installs only `limine-mkinitcpio-hook`, writes mkinitcpio hooks with `zfs`, and skips Snapper/Btrfs setup.
- Limine config detection now uses `sudo test` and `sudo grep`, because `/boot` may be mounted with restrictive permissions.
- Hibernation setup now exits cleanly on non-Btrfs roots instead of attempting to create a Btrfs swapfile/resume setup.
- Added reusable VM harnesses for building and verifying Arch Linux with ZFS root, UEFI, and Limine.
- Added reusable harnesses for installing the current Omarchy checkout onto a ZFS-root Arch VM overlay.
- Added a local GUI launcher for the verified Omarchy-on-ZFS VM overlay.

## What Was Tested

Testing was done in a real QEMU/KVM VM, not Docker or chroot-only emulation.

The base VM was built with:

- Arch Linux
- UEFI via OVMF/EDK2 pflash firmware
- Limine bootloader
- `linux-lts`
- `zfs-linux-lts`
- ZFS pool `zroot`
- root dataset `zroot/ROOT/default`
- serial console login for automation

The clean base disk is kept separate from destructive Omarchy tests. Omarchy was installed into qcow2 overlays.

Verified after Omarchy install:

- Omarchy install completed with exit code `0` using `OMARCHY_MIRROR=edge`.
- The installed system boots successfully from ZFS root.
- `/` reports filesystem type `zfs`.
- `zpool status zroot` reports the pool as `ONLINE`.
- `/boot/limine.conf` exists and contains generated Limine boot entries.
- Limine keeps `root=ZFS=zroot/ROOT/default` in the kernel command line.
- `/etc/mkinitcpio.conf.d/omarchy_hooks.conf` includes the `zfs` hook.
- `limine-mkinitcpio-hook` is installed.
- `zfs-linux-lts` is installed.
- `sddm.service` is enabled.
- `/etc/pacman.conf` still contains `[archzfs]` after Omarchy pacman configuration.
- No `/swap/swapfile` entry is added to `/etc/fstab`.
- No `/etc/mkinitcpio.conf.d/omarchy_resume.conf` is created on ZFS.
- `systemctl --failed --no-legend` returns no failed units.

The verified overlay also has `timeout: 10` in `/boot/limine.conf` so the Limine menu is visible when booting the GUI launcher.

## Important Test Notes

- `OMARCHY_MIRROR=edge` was used for ZFS VM installs. The stable mirror attempted to downgrade `linux-lts` below the version required by `zfs-linux-lts` during testing.
- The ArchZFS live ISO used for the base VM came from `stevleibelt/arch-linux-live-cd-iso-with-zfs` release `20260401` and was checksum verified before use.
- UEFI boot required using the EDK2 firmware as a pflash drive. Using it with `-bios` failed.
- Some QEMU/EDK2 output labels the virtio disk as `UEFI Misc Device`; that was expected and still booted Limine.
- QEMU boot ordering had to be explicit with `-boot order=c,menu=off` and `bootindex=0` on the virtio disk to avoid falling into the UEFI shell.
- GTK OpenGL display failed on the tested host with a DMABUF-related error, so the GUI launcher defaults to non-GL GTK and exposes `--gl` as an opt-in.

## Manual Install From An ArchZFS USB

There is not yet a polished end-user installer for the base Arch/ZFS system. The tested path uses the bundled VM installer script as the source of truth for how the base system is created:

- `.agents/skills/arch-zfs-vm/scripts/install-arch-zfs-limine.sh`

If you boot the stevleibelt ArchZFS ISO from USB, the manual equivalent is:

1. Boot the ArchZFS live USB in UEFI mode.
2. Confirm ZFS tools are available:

```bash
modprobe zfs
zpool version
```

3. Partition the target disk with an EFI system partition and a ZFS partition.

Example for `/dev/nvme0n1`, destroying all existing data on that disk:

```bash
DISK=/dev/nvme0n1
BOOT_PART=/dev/nvme0n1p1
ZFS_PART=/dev/nvme0n1p2

sgdisk --zap-all "$DISK"
sgdisk \
  --new=1:1MiB:+1GiB --typecode=1:EF00 --change-name=1:EFI \
  --new=2:0:0 --typecode=2:BF00 --change-name=2:zroot \
  "$DISK"
mkfs.fat -F32 -n EFI "$BOOT_PART"
```

4. Create the ZFS pool and datasets using the tested layout:

```bash
POOL=zroot

zpool create -f \
  -o ashift=12 \
  -o autotrim=on \
  -O acltype=posixacl \
  -O relatime=on \
  -O xattr=sa \
  -O dnodesize=auto \
  -O normalization=formD \
  -O mountpoint=none \
  -O canmount=off \
  -O devices=off \
  -O compression=zstd \
  -R /mnt \
  "$POOL" "$ZFS_PART"

zfs create -o mountpoint=none "$POOL/ROOT"
zfs create -o mountpoint=/ -o canmount=noauto "$POOL/ROOT/default"
zfs create -o mountpoint=none "$POOL/data"
zfs create -o mountpoint=/home "$POOL/data/home"
zfs create -o mountpoint=/root "$POOL/data/root"
zfs create -o mountpoint=/srv "$POOL/data/srv"
zfs create -o mountpoint=/var -o canmount=off "$POOL/var"
zfs create "$POOL/var/log"
zfs create -o mountpoint=/var/log/journal -o acltype=posixacl "$POOL/var/log/journal"
zfs create "$POOL/var/cache"
zfs create "$POOL/var/tmp"
zfs create -o mountpoint=/var/lib -o canmount=off "$POOL/var/lib"
zfs create "$POOL/var/lib/docker"
zfs create "$POOL/var/lib/libvirt"
zfs create "$POOL/var/lib/machines"
zpool set bootfs="$POOL/ROOT/default" "$POOL"
zpool set cachefile=/etc/zfs/zpool.cache "$POOL"
```

5. Mount the target filesystems:

```bash
zfs mount "$POOL/ROOT/default"
zfs mount -a
mkdir -p /mnt/boot /mnt/etc/zfs
mount "$BOOT_PART" /mnt/boot
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache
```

6. Add the ArchZFS repository in the live environment and install Arch:

```bash
cat >> /etc/pacman.conf <<'EOF'

[archzfs]
SigLevel = Never
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

pacman -Sy --noconfirm
pacstrap -K /mnt \
  base \
  linux-lts \
  linux-lts-headers \
  linux-firmware \
  zfs-utils \
  zfs-linux-lts \
  limine \
  sudo \
  networkmanager \
  openssh \
  git
```

7. Configure the installed system in `arch-chroot`:

```bash
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
printf 'UUID=%s /boot vfat umask=0077 0 2\n' "$BOOT_UUID" > /mnt/etc/fstab

cat >> /mnt/etc/pacman.conf <<'EOF'

[archzfs]
SigLevel = Never
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

arch-chroot /mnt
```

Inside the chroot:

```bash
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf
printf 'omarchy-zfs\n' > /etc/hostname

zgenhostid deadbeef
zpool set cachefile=/etc/zfs/zpool.cache zroot
sed -i 's/^MODULES=.*/MODULES=(zfs)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block zfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

mkdir -p /boot/EFI/BOOT /boot/EFI/arch-limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/arch-limine/BOOTX64.EFI
```

Create `/boot/EFI/BOOT/limine.conf`:

```text
timeout: 3

/+Arch Linux ZFS
    protocol: linux
    path: boot():/vmlinuz-linux-lts
    cmdline: root=ZFS=zroot/ROOT/default rw
    module_path: boot():/initramfs-linux-lts.img

/+Arch Linux ZFS fallback
    protocol: linux
    path: boot():/vmlinuz-linux-lts
    cmdline: root=ZFS=zroot/ROOT/default rw
    module_path: boot():/initramfs-linux-lts-fallback.img
```

Then finish base services and users as usual for an Arch install. At minimum, enable networking and ZFS services:

```bash
systemctl enable NetworkManager.service
systemctl enable zfs-import-cache.service
systemctl enable zfs-import.target
systemctl enable zfs-mount.service
systemctl enable zfs.target
```

8. Exit the chroot, export the pool, reboot, and confirm the installed system boots from ZFS:

```bash
exit
umount -R /mnt || true
zpool export zroot
reboot
```

9. After booting into the installed ZFS system, install Omarchy from this branch with the edge mirror:

```bash
OMARCHY_MIRROR=edge bash install.sh
```

The key requirements before running Omarchy are that `/` is mounted as `zfs`, Limine boots the system, `zfs-linux-lts` matches `linux-lts`, and `[archzfs]` is present in `/etc/pacman.conf`.

## Files Added

- `.agents/skills/arch-zfs-vm/SKILL.md`
- `.agents/skills/arch-zfs-vm/scripts/*`
- `.agents/skills/omarchy-on-zfs-arch/SKILL.md`
- `.agents/skills/omarchy-on-zfs-arch/scripts/*`
- `install/helpers/pacman.sh`
- `tmp/arch-zfs-vm/*`

## Files Changed

- `bin/omarchy-hibernation-setup`
- `install/helpers/all.sh`
- `install/login/limine-snapper.sh`
- `install/post-install/pacman.sh`
- `install/preflight/guard.sh`
- `install/preflight/pacman.sh`

## What Has Not Been Done

- No ZFS snapshot boot integration was added. Omarchy snapshot boot entries remain Btrfs/Snapper-specific.
- No ZFS-native snapshot management policy was added.
- No hibernation support was added for ZFS roots.
- No stable-mirror ZFS install path was made reliable. The tested path uses `OMARCHY_MIRROR=edge` to avoid kernel/ZFS package mismatch.
- No migration was added for existing installations.
- No automated CI job was added for ZFS VM installation.
- No broad hardware validation was done outside the tested QEMU/KVM UEFI VM.
- The `tmp/arch-zfs-vm` harnesses are local runnable scratch tools. Durable reusable copies also exist under `.agents/skills/.../scripts/`.

## Current Status

The branch has a verified end-to-end Omarchy install on an Arch Linux ZFS-root VM. The implementation intentionally skips Btrfs-only features on ZFS rather than attempting partial compatibility.
