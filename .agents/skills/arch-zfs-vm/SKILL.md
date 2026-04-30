---
name: arch-zfs-vm
description: Build and verify a pure Arch Linux VM with ZFS root, UEFI, and Limine.
---

# Arch ZFS VM

Use this skill to create a clean Arch Linux virtual machine with:

- UEFI boot via OVMF/EDK2 pflash firmware
- Limine bootloader
- `linux-lts` plus `zfs-linux-lts`
- ZFS root pool named `zroot`
- Serial console login for unattended install and verification
- No desktop environment or project-specific packages

Do not install host packages automatically. If a required host tool is missing, stop and ask the user to install it.

## Host Requirements

Required host commands:

```bash
qemu-system-x86_64
qemu-img
xorriso
expect
curl
sha512sum
```

Required host access:

```bash
test -r /dev/kvm && test -w /dev/kvm
```

Required firmware:

```bash
edk2-x86_64-code.fd
```

Use the firmware as a pflash drive. Do not use `-bios` for this file.

## Inputs

Use these defaults unless the user asks otherwise:

```bash
VM_NAME=arch-zfs
VM_ROOT="$HOME/.local/share/arch-zfs-vms/$VM_NAME"
ISO_DIR="$HOME/.local/share/arch-zfs-vms/isos"
DISK="$VM_ROOT/$VM_NAME.qcow2"
DISK_SIZE=80G
HOSTNAME=arch-zfs
USER_NAME=arch
USER_PASSWORD=arch
ROOT_PASSWORD=arch
POOL=zroot
SERIAL=arch-zfs-root
```

Use the ArchZFS live ISO because the regular Arch ISO does not contain ZFS tooling:

```bash
ARCHZFS_ISO_URL="https://github.com/stevleibelt/arch-linux-live-cd-iso-with-zfs/releases/download/20260401/archzfs-linux-20260401.iso"
ARCHZFS_ISO_SHA512="4870b8223e132fc7ffde14383230794731d880a6a1e91d621174b8bf412700275004ec16851052a523e334770912dfcce34cd7eec77256b36cf0ac1e83ea877a"
ARCHZFS_ISO_LABEL="Archzfs_20260401_2220"
ARCHZFS_REPO="https://github.com/archzfs/archzfs/releases/download/experimental"
```

Confirm with the user before downloading a third-party ISO.

## Bundled Scripts

This skill includes reusable scripts under `scripts/`:

- `scripts/install-arch-zfs-limine.sh`: guest-side Arch ZFS installer copied into the seed ISO.
- `scripts/preflight-live.expect`: verifies the live ISO can see the ArchZFS packages.
- `scripts/run-install.expect`: boots the live ISO and runs the seed installer unattended.
- `scripts/boot-verify.expect`: boots the installed disk and verifies ZFS plus Limine.
- `scripts/guest-command.expect`: boots the installed disk and runs an arbitrary command.

Use them directly when available instead of rewriting one-off harnesses. They accept paths and credentials as arguments, with safe defaults matching this document.

## Build Workflow

1. Create the VM directories.

```bash
mkdir -p "$VM_ROOT" "$ISO_DIR"
```

2. Download and verify the ArchZFS ISO.

```bash
ARCH_ISO="$ISO_DIR/archzfs-linux-20260401.iso"
curl -L "$ARCHZFS_ISO_URL" -o "$ARCH_ISO"
printf '%s  %s\n' "$ARCHZFS_ISO_SHA512" "$ARCH_ISO" | sha512sum -c -
```

3. Extract the live ISO kernel and initramfs.

```bash
xorriso -osirrox on -indev "$ARCH_ISO" -extract /arch/boot/x86_64/vmlinuz-linux "$VM_ROOT/vmlinuz-linux"
xorriso -osirrox on -indev "$ARCH_ISO" -extract /arch/boot/x86_64/initramfs-linux.img "$VM_ROOT/initramfs-linux.img"
```

4. Create the VM disk.

```bash
qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
```

5. Create a seed directory containing `install-arch-zfs-limine.sh`.

When using this skill from a checked-out repository, copy the bundled script into the seed directory:

```bash
mkdir -p "$VM_ROOT/seed"
cp ".agents/skills/arch-zfs-vm/scripts/install-arch-zfs-limine.sh" "$VM_ROOT/seed/"
chmod +x "$VM_ROOT/seed/install-arch-zfs-limine.sh"
```

Use this installer as the guest-side script:

```bash
#!/bin/bash
set -euo pipefail

DISK=/dev/vda
BOOT_PART=/dev/vda1
ZFS_PART=/dev/vda2
POOL=zroot
HOSTNAME=arch-zfs
USER_NAME=arch
USER_PASSWORD=arch
ROOT_PASSWORD=arch
SERIAL=arch-zfs-root
ARCHZFS_REPO="https://github.com/archzfs/archzfs/releases/download/experimental"

log() {
  printf '\n==> %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command in live ISO: %s\n' "$1" >&2
    exit 1
  fi
}

for cmd in sgdisk mkfs.fat modprobe zpool zfs pacman pacstrap arch-chroot blkid wipefs; do
  require_cmd "$cmd"
done

if [[ ! -b $DISK ]]; then
  printf 'Expected VM disk %s was not found.\n' "$DISK" >&2
  exit 1
fi

log "Loading ZFS"
modprobe zfs

log "Preparing GPT disk on $DISK"
if zpool import -N -f "$POOL" >/dev/null 2>&1; then
  zpool destroy -f "$POOL"
fi
zpool export "$POOL" >/dev/null 2>&1 || true
for dev in $DISK ${DISK}?*; do
  [[ -b $dev ]] && wipefs -af "$dev" >/dev/null 2>&1 || true
done
sgdisk --zap-all "$DISK"
sgdisk \
  --new=1:1MiB:+1GiB --typecode=1:EF00 --change-name=1:EFI \
  --new=2:0:0 --typecode=2:BF00 --change-name=2:zroot \
  "$DISK"
partprobe "$DISK" >/dev/null 2>&1 || true
udevadm settle

log "Formatting EFI system partition"
mkfs.fat -F32 -n EFI "$BOOT_PART"

ZFS_DEVICE="/dev/disk/by-id/virtio-${SERIAL}-part2"
if [[ ! -e $ZFS_DEVICE ]]; then
  ZFS_DEVICE=$ZFS_PART
fi

log "Creating ZFS pool on $ZFS_DEVICE"
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
  "$POOL" "$ZFS_DEVICE"

log "Creating ZFS datasets"
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

log "Mounting target filesystems"
zfs mount "$POOL/ROOT/default"
zfs mount -a
mkdir -p /mnt/boot /mnt/etc/zfs
mount "$BOOT_PART" /mnt/boot
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

log "Configuring ArchZFS repository in live environment"
if ! grep -q '^\[archzfs\]' /etc/pacman.conf; then
  cat >> /etc/pacman.conf <<EOF

[archzfs]
SigLevel = Never
Server = $ARCHZFS_REPO
EOF
fi

log "Syncing package databases"
pacman -Sy --noconfirm

if ! pacman -Si zfs-linux-lts >/dev/null 2>&1; then
  printf 'Required ArchZFS package zfs-linux-lts is unavailable.\n' >&2
  exit 1
fi

log "Installing base Arch system"
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
  git \
  vim

BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
cat > /mnt/etc/fstab <<EOF
UUID=$BOOT_UUID /boot vfat umask=0077 0 2
EOF

cat >> /mnt/etc/pacman.conf <<EOF

[archzfs]
SigLevel = Never
Server = $ARCHZFS_REPO
EOF

cat > /mnt/root/configure-target.sh <<EOF
#!/bin/bash
set -euo pipefail

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf
printf '$HOSTNAME\n' > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
HOSTS

printf 'root:$ROOT_PASSWORD\n' | chpasswd
useradd -m -G wheel -s /bin/bash '$USER_NAME'
install -d -m 700 -o '$USER_NAME' -g '$USER_NAME' '/home/$USER_NAME'
printf '$USER_NAME:$USER_PASSWORD\n' | chpasswd
cat > /etc/tmpfiles.d/$USER_NAME-home.conf <<TMPFILES
d /home/$USER_NAME 0700 $USER_NAME $USER_NAME -
TMPFILES
printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/99-wheel-nopasswd
chmod 0440 /etc/sudoers.d/99-wheel-nopasswd

chmod 1777 /var/tmp
zgenhostid deadbeef
zpool set cachefile=/etc/zfs/zpool.cache $POOL

sed -i 's/^MODULES=.*/MODULES=(zfs)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block zfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

mkdir -p /boot/EFI/BOOT /boot/EFI/arch-limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/arch-limine/BOOTX64.EFI

cat > /boot/EFI/BOOT/limine.conf <<LIMINE
timeout: 3

/+Arch Linux ZFS
    protocol: linux
    path: boot():/vmlinuz-linux-lts
    cmdline: root=ZFS=$POOL/ROOT/default rw console=ttyS0,115200n8
    module_path: boot():/initramfs-linux-lts.img

/+Arch Linux ZFS fallback
    protocol: linux
    path: boot():/vmlinuz-linux-lts
    cmdline: root=ZFS=$POOL/ROOT/default rw console=ttyS0,115200n8
    module_path: boot():/initramfs-linux-lts-fallback.img
LIMINE

cp /boot/EFI/BOOT/limine.conf /boot/EFI/arch-limine/limine.conf

systemctl enable NetworkManager.service
systemctl enable sshd.service
systemctl enable serial-getty@ttyS0.service
systemctl enable zfs-import-cache.service
systemctl enable zfs-import.target
systemctl enable zfs-mount.service
systemctl enable zfs.target
EOF

chmod +x /mnt/root/configure-target.sh

log "Configuring target system"
arch-chroot /mnt /root/configure-target.sh
rm /mnt/root/configure-target.sh

log "Final ZFS cache copy"
cp /mnt/etc/zfs/zpool.cache /etc/zfs/zpool.cache
sync

log "Unmounting and exporting ZFS pool"
umount -R /mnt >/dev/null 2>&1 || true
if ! zpool export "$POOL"; then
  zfs umount -a || true
  zpool export -f "$POOL"
fi

log "INSTALL COMPLETE"
```

6. Create `seed.iso` from the seed directory.

```bash
xorriso -as mkisofs -quiet -V ARCH_ZFS_SEED -o "$VM_ROOT/seed.iso" "$VM_ROOT/seed"
```

7. Optionally preflight the live ISO package availability.

```bash
expect ".agents/skills/arch-zfs-vm/scripts/preflight-live.expect" \
  "$QEMU" \
  "$OVMF_CODE" \
  "$VM_ROOT/vmlinuz-linux" \
  "$VM_ROOT/initramfs-linux.img" \
  "$ARCH_ISO" \
  "$ARCHZFS_ISO_LABEL" \
  "$ARCHZFS_REPO"
```

8. Boot the live ISO kernel directly and run the installer through serial console.

Automated path using the bundled harness:

```bash
expect ".agents/skills/arch-zfs-vm/scripts/run-install.expect" \
  "$QEMU" \
  "$OVMF_CODE" \
  "$VM_ROOT/vmlinuz-linux" \
  "$VM_ROOT/initramfs-linux.img" \
  "$ARCH_ISO" \
  "$VM_ROOT/seed.iso" \
  "$DISK" \
  "$VM_ROOT/install-console.log" \
  "$ARCHZFS_ISO_LABEL" \
  "$SERIAL"
```

Manual path:

Use QEMU with UEFI pflash:

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -machine q35 \
  -cpu host \
  -smp 4 \
  -m 8192 \
  -nographic \
  -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=none,id=vdisk,file="$DISK",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=vdisk,serial="$SERIAL" \
  -drive if=none,id=archiso,file="$ARCH_ISO",format=raw,media=cdrom,readonly=on \
  -device ide-cd,drive=archiso,bus=ide.0 \
  -drive if=none,id=seed,file="$VM_ROOT/seed.iso",format=raw,media=cdrom,readonly=on \
  -device ide-cd,drive=seed,bus=ide.1 \
  -kernel "$VM_ROOT/vmlinuz-linux" \
  -initrd "$VM_ROOT/initramfs-linux.img" \
  -append "archisobasedir=arch archisolabel=$ARCHZFS_ISO_LABEL cow_spacesize=4G console=ttyS0,115200n8"
```

At the live ISO root prompt, run:

```bash
mkdir -p /mnt/seed
mount /dev/sr1 /mnt/seed
bash /mnt/seed/install-arch-zfs-limine.sh
poweroff
```

## Verification

Boot the installed disk without the ISO drives:

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -machine q35 \
  -cpu host \
  -smp 4 \
  -m 8192 \
  -nographic \
  -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=none,id=vdisk,file="$DISK",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=vdisk,serial="$SERIAL" \
  -nic user,model=virtio-net-pci
```

Log in with the configured user and password, then verify:

Automated path using the bundled harness:

```bash
expect ".agents/skills/arch-zfs-vm/scripts/boot-verify.expect" \
  "$QEMU" \
  "$OVMF_CODE" \
  "$DISK" \
  "$USER_NAME" \
  "$USER_PASSWORD" \
  "$HOSTNAME" \
  "$SERIAL"
```

Manual checks:

```bash
set -e
pwd
test -d "/home/$USER_NAME"
uname -r
findmnt -n -o FSTYPE /
sudo zpool status zroot
sudo zfs list -o name,mountpoint,canmount -r zroot
sudo test -f /boot/EFI/BOOT/BOOTX64.EFI
sudo test -f /boot/EFI/BOOT/limine.conf
```

Expected results:

- `findmnt -n -o FSTYPE /` prints `zfs`.
- `zpool status zroot` shows `state: ONLINE`.
- `zroot/ROOT/default` is mounted at `/` with `canmount=noauto`.
- `/boot/EFI/BOOT/BOOTX64.EFI` exists.
- `/boot/EFI/BOOT/limine.conf` exists.

Use `sudo test` for `/boot` files because `/boot` is mounted with `umask=0077`.

## Common Failures

- If QEMU says it cannot load the firmware, use `-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"`, not `-bios "$OVMF_CODE"`.
- If `zfs-linux-lts` is unavailable, the ArchZFS package repo is not configured or not synchronized.
- If `linux-lts` and `zfs-linux-lts` versions conflict, choose package repositories where the kernel and ZFS module versions match.
- If `/home/$USER_NAME` disappears after boot, the user was created before the separate `/home` dataset was mounted. Keep the tmpfiles rule that recreates the home directory on boot.
- If Limine boots but cannot find the root filesystem, verify the kernel cmdline is exactly `root=ZFS=zroot/ROOT/default rw` plus any console parameters.
