#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

zfs_setup="$ROOT/install/config/zfs.sh"
snapper_setup="$ROOT/install/config/snapper.sh"
snapshot="$ROOT/bin/omarchy-snapshot"
hibernation="$ROOT/bin/omarchy-hibernation-setup"
refresh_limine="$ROOT/bin/omarchy-refresh-limine"
pacman_helper="$ROOT/install/helpers/pacman.sh"

for script in \
  "$zfs_setup" "$snapper_setup" "$snapshot" "$hibernation" \
  "$refresh_limine" "$pacman_helper" \
  "$ROOT/install/config/zfs/zfs-pam-unlock-home" \
  "$ROOT/install/config/zfs/zfs-home-cleanup" \
  "$ROOT/install/config/zfs/zfs-pam-cleanup-home" \
  "$ROOT/install/config/zfs/zfs-pam-home-exists" \
  "$ROOT/install/config/zfs/zfs-pam-verify-home"; do
  bash -n "$script"
done
pass "ZFS setup and lifecycle scripts have valid shell syntax"

grep -F 'config/zfs.sh' "$ROOT/install/config/all.sh" >/dev/null || fail "system setup runs ZFS configuration"
grep -F 'HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block zfs filesystems)' "$zfs_setup" >/dev/null || fail "ZFS initramfs excludes fsck and Btrfs hooks"
grep -F 'FILES+=(/etc/hostid)' "$zfs_setup" >/dev/null || fail "ZFS hostid is embedded in initramfs"
grep -F 'systemctl mask tmp.mount' "$zfs_setup" >/dev/null || fail "RAM-backed tmp.mount is masked"
grep -F 'chmod 1777 /tmp /var/tmp' "$zfs_setup" >/dev/null || fail "disk-backed temporary directories keep sticky permissions"
grep -F 'pam_exec.so expose_authtok' "$zfs_setup" >/dev/null || fail "PAM unlock receives the login password"
grep -F 'service in sddm:login:sshd:su-l' "$zfs_setup" >/dev/null || fail "ZFS PAM hooks are login-service scoped"
grep -F 'zfs_helper_dir=/usr/share/omarchy/install/config/zfs' "$zfs_setup" >/dev/null || fail "PAM uses package-owned ZFS helpers"
pass "ZFS setup configures boot, PAM, services, and disk-backed temporary directories"

grep -F 'requires Btrfs root filesystem' "$snapper_setup" >/dev/null || fail "Snapper setup skips non-Btrfs roots"
grep -F 'requires Btrfs root filesystem' "$hibernation" >/dev/null || fail "hibernation skips non-Btrfs roots"
grep -F 'Restoring ZFS snapshots from the boot menu is not supported' "$snapshot" >/dev/null || fail "ZFS restore limitation is explicit"
grep -F 'zfs snapshot' "$snapshot" >/dev/null || fail "updates can create native ZFS snapshots"
grep -F '== "btrfs"' "$refresh_limine" >/dev/null || fail "Limine refresh only syncs Snapper on Btrfs"
grep -F 'archzfs_repo' "$pacman_helper" >/dev/null || fail "pacman refresh preserves ArchZFS"
grep -F '[omarchy-zfs]' "$ROOT/default/pacman/pacman-edge.conf" >/dev/null || fail "edge pacman config includes omarchy-zfs"
grep -F 'omarchy-zfs-pkgs/releases/download/zfs' "$ROOT/default/pacman/pacman-stable.conf" >/dev/null || fail "stable pacman config points at the ZFS package repo"
pass "runtime commands remain filesystem-aware after installation"
