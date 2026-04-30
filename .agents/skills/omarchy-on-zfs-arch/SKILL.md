---
name: omarchy-on-zfs-arch
description: Install Omarchy from the current checkout onto an existing Arch Linux ZFS VM.
---

# Omarchy On ZFS Arch

Use this skill to install Omarchy from the current repository checkout on top of a clean Arch Linux VM that already boots from ZFS root.

Start from a VM produced by the `arch-zfs-vm` skill, or any equivalent system with:

- Arch Linux
- UEFI boot
- Limine installed
- root filesystem mounted from `zroot/ROOT/default`
- `/` filesystem type `zfs`
- `linux-lts` and matching `zfs-linux-lts`
- a normal sudo-capable user
- serial console login available

Do not install directly into the clean base disk unless the user explicitly asks. Create a qcow2 overlay and run Omarchy in the overlay so the pure Arch ZFS base remains reusable.

Do not install host packages automatically. If a required host tool is missing, stop and ask the user to install it.

## Host Requirements

Required host commands:

```bash
qemu-system-x86_64
qemu-img
xorriso
tar
expect
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

Adjust these paths to the local machine and the VM created by `arch-zfs-vm`:

```bash
REPO="$PWD"
VM_NAME=arch-zfs
VM_ROOT="$HOME/.local/share/arch-zfs-vms/$VM_NAME"
BASE_DISK="$VM_ROOT/$VM_NAME.qcow2"
TEST_DISK="$VM_ROOT/$VM_NAME-omarchy-test.qcow2"
REPO_TAR="$VM_ROOT/omarchy-repo.tar"
REPO_ISO="$VM_ROOT/omarchy-repo.iso"
OVMF_CODE="/path/to/edk2-x86_64-code.fd"
QEMU="$(command -v qemu-system-x86_64)"
USER_NAME=arch
USER_PASSWORD=arch
HOSTNAME=arch-zfs
SERIAL=arch-zfs-root
OMARCHY_MIRROR=edge
```

Use `OMARCHY_MIRROR=edge` by default for ZFS VMs. ArchZFS follows rolling Arch kernel packages closely; `stable` can fail if it tries to downgrade `linux-lts` while `zfs-linux-lts` requires the newer kernel.

## Bundled Scripts

This skill includes reusable scripts under `scripts/`:

- `scripts/run-omarchy-install.expect`: boots the overlay with the repo ISO and runs the local Omarchy installer unattended.
- `scripts/guest-command.expect`: boots the installed overlay and runs an arbitrary verification command.

Use these scripts directly when available. They accept VM paths, credentials, mirror, hostname, and disk serial as arguments.

## Preserve The Base Disk

Create a fresh overlay for each destructive test run:

```bash
qemu-img create \
  -f qcow2 \
  -F qcow2 \
  -b "$BASE_DISK" \
  "$TEST_DISK"
```

If re-running after a failed install, create a new overlay rather than reusing the partially modified one.

## Package The Current Checkout

Package the current working tree and expose it to the VM as an ISO. This installs exactly the current checkout, including uncommitted changes, and does not clone from the network inside the VM.

```bash
tar \
  --exclude='./.git' \
  --exclude='./tmp' \
  -C "$REPO" \
  -cf "$REPO_TAR" \
  .

xorriso -as mkisofs \
  -quiet \
  -V OMARCHY_REPO \
  -o "$REPO_ISO" \
  "$REPO_TAR"
```

Rebuild this ISO after every local code change that should be tested in the guest.

## Boot The Overlay With The Repo ISO

Boot the overlay with the repository ISO attached as the first CD-ROM:

```bash
"$QEMU" \
  -enable-kvm \
  -machine q35 \
  -cpu host \
  -smp 4 \
  -m 8192 \
  -boot order=c,menu=off \
  -nographic \
  -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=none,id=vdisk,file="$TEST_DISK",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=vdisk,serial="$SERIAL",bootindex=0 \
  -drive if=none,id=repo,file="$REPO_ISO",format=raw,media=cdrom,readonly=on \
  -device ide-cd,drive=repo,bus=ide.0 \
  -nic user,model=virtio-net-pci
```

Log in on the serial console with the Arch ZFS VM user.

## Install From The Current Repo

Inside the VM, mount the repo ISO, extract it into the expected Omarchy location, and run the local installer:

```bash
set -e
sudo mkdir -p /mnt/omarchy-repo
sudo mount -o ro /dev/sr0 /mnt/omarchy-repo
rm -rf ~/.local/share/omarchy
mkdir -p ~/.local/share/omarchy
tar -xf /mnt/omarchy-repo/omarchy-repo.tar -C ~/.local/share/omarchy
cd ~/.local/share/omarchy
OMARCHY_MIRROR=edge OMARCHY_ONLINE_INSTALL=1 OMARCHY_CHROOT_INSTALL=1 bash install.sh
sudo reboot
```

`OMARCHY_ONLINE_INSTALL=1` makes the installer configure pacman and install packages from repositories.

`OMARCHY_CHROOT_INSTALL=1` makes the final installer prompt exit cleanly instead of rebooting immediately. Reboot manually after a zero exit.

If the installer stops, inspect the guest log:

```bash
sudo tail -n 260 /var/log/omarchy-install.log
```

## Optional Expect Automation

For unattended runs, create an expect harness that:

- boots QEMU with the overlay disk and repo ISO
- waits for the serial login prompt
- logs in as the configured user
- mounts `/dev/sr0`
- extracts `omarchy-repo.tar` into `~/.local/share/omarchy`
- runs `OMARCHY_MIRROR=edge OMARCHY_ONLINE_INSTALL=1 OMARCHY_CHROOT_INSTALL=1 bash install.sh`
- sends Enter when the final `Reboot Now` prompt appears
- waits for `__OMARCHY_INSTALL_EXIT:0__`
- sends `sudo reboot`

The guest command used by the harness should be:

```bash
(set -e; sudo mkdir -p /mnt/omarchy-repo; sudo mount -o ro /dev/sr0 /mnt/omarchy-repo; rm -rf ~/.local/share/omarchy; mkdir -p ~/.local/share/omarchy; tar -xf /mnt/omarchy-repo/omarchy-repo.tar -C ~/.local/share/omarchy; cd ~/.local/share/omarchy; set +e; OMARCHY_MIRROR=edge OMARCHY_ONLINE_INSTALL=1 OMARCHY_CHROOT_INSTALL=1 bash install.sh; rc=$?; set -e; printf '\n__OMARCHY_INSTALL_EXIT:%s__\n' $rc; exit $rc); rc=$?; printf '\n__OMARCHY_WRAPPER_EXIT:%s__\n' $rc
```

Treat `__OMARCHY_INSTALL_EXIT:0__` as success. If QEMU exits immediately after `sudo reboot`, that is acceptable when `-no-reboot` is present.

If the bundled harness is available, run:

```bash
expect ".agents/skills/omarchy-on-zfs-arch/scripts/run-omarchy-install.expect" \
  "$QEMU" \
  "$OVMF_CODE" \
  "$TEST_DISK" \
  "$REPO_ISO" \
  "$VM_ROOT/omarchy-install-console.log" \
  "$OMARCHY_MIRROR" \
  "$USER_NAME" \
  "$USER_PASSWORD" \
  "$HOSTNAME" \
  "$SERIAL"
```

## Verify After Reboot

Boot the installed overlay without the repo ISO:

```bash
"$QEMU" \
  -enable-kvm \
  -machine q35 \
  -cpu host \
  -smp 4 \
  -m 8192 \
  -boot order=c,menu=off \
  -nographic \
  -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=none,id=vdisk,file="$TEST_DISK",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=vdisk,serial="$SERIAL",bootindex=0 \
  -nic user,model=virtio-net-pci
```

Log in and run:

Automated path using the bundled harness:

```bash
expect ".agents/skills/omarchy-on-zfs-arch/scripts/guest-command.expect" \
  "$QEMU" \
  "$OVMF_CODE" \
  "$TEST_DISK" \
  "set -e; printf '\n__POST_VERIFY_START__\n'; pwd; findmnt -n -o FSTYPE /; uname -r; sudo zpool status zroot; sudo test -f /boot/limine.conf; sudo grep -q '^/+' /boot/limine.conf; sudo grep -q 'root=ZFS=zroot/ROOT/default' /boot/limine.conf; sudo grep -q 'zfs' /etc/mkinitcpio.conf.d/omarchy_hooks.conf; pacman -Q limine-mkinitcpio-hook zfs-linux-lts; systemctl is-enabled sddm.service; grep -q '^\[archzfs\]' /etc/pacman.conf; ! grep -q '/swap/swapfile' /etc/fstab; ! sudo test -f /etc/mkinitcpio.conf.d/omarchy_resume.conf; test -z \"\$(systemctl --failed --no-legend)\"; printf '__POST_VERIFY_OK__\n'" \
  "$USER_NAME" \
  "$USER_PASSWORD" \
  "$HOSTNAME" \
  "$SERIAL"
```

Manual checks:

```bash
set -e
printf '\n__POST_VERIFY_START__\n'
pwd
findmnt -n -o FSTYPE /
uname -r
sudo zpool status zroot
sudo test -f /boot/limine.conf
sudo grep -q '^/+' /boot/limine.conf
sudo grep -q 'root=ZFS=zroot/ROOT/default' /boot/limine.conf
sudo grep -q 'zfs' /etc/mkinitcpio.conf.d/omarchy_hooks.conf
pacman -Q limine-mkinitcpio-hook zfs-linux-lts
systemctl is-enabled sddm.service
grep -q '^\[archzfs\]' /etc/pacman.conf
! grep -q '/swap/swapfile' /etc/fstab
! sudo test -f /etc/mkinitcpio.conf.d/omarchy_resume.conf
test -z "$(systemctl --failed --no-legend)"
printf '__POST_VERIFY_OK__\n'
```

Expected results:

- `/` filesystem type is `zfs`.
- `zroot` is `ONLINE`.
- `/boot/limine.conf` exists and contains generated entries.
- Limine cmdline keeps `root=ZFS=zroot/ROOT/default`.
- mkinitcpio Omarchy hooks include `zfs`.
- `limine-mkinitcpio-hook` and `zfs-linux-lts` are installed.
- `sddm.service` is enabled.
- `[archzfs]` remains in `/etc/pacman.conf`.
- no Btrfs hibernation swapfile or resume config was created.
- `systemctl --failed --no-legend` is empty.

Use `sudo test` and `sudo grep` for `/boot` files because the Arch ZFS VM mounts `/boot` with `umask=0077`.

## Known Failure Modes

- `stable` mirror can fail with a `linux-lts` downgrade that breaks `zfs-linux-lts`. Use `OMARCHY_MIRROR=edge` unless specifically testing stable repository compatibility.
- If the installer cannot find Limine config under `/boot`, ensure checks use `sudo`; `/boot` is root-only on this VM.
- If boot fails after install, verify `/boot/limine.conf` still has `root=ZFS=zroot/ROOT/default` and the generated initramfs contains the `zfs` hook.
- If a failed unit appears for `/swap/swapfile`, hibernation setup ran on non-Btrfs root. The ZFS path should skip Btrfs hibernation setup.
- If `[archzfs]` disappears from `/etc/pacman.conf`, pacman config replacement dropped the ZFS repository and future kernel/ZFS upgrades can break.
