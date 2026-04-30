#!/bin/bash
set -euo pipefail

DISK=${DISK:-/dev/vda}
BOOT_PART=${BOOT_PART:-/dev/vda1}
ZFS_PART=${ZFS_PART:-/dev/vda2}
POOL=${POOL:-zroot}
HOSTNAME=${HOSTNAME:-arch-zfs}
USER_NAME=${USER_NAME:-arch}
USER_PASSWORD=${USER_PASSWORD:-arch}
ROOT_PASSWORD=${ROOT_PASSWORD:-arch}
SERIAL=${SERIAL:-arch-zfs-root}
ARCHZFS_REPO=${ARCHZFS_REPO:-https://github.com/archzfs/archzfs/releases/download/experimental}

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
