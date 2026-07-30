root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
[[ $root_fstype == "zfs" ]] || return 0

echo "Configuring ZFS root and encrypted homes"

root_dataset=$(findmnt -n -o SOURCE /)
pool=${root_dataset%%/*}
home_prefix="$pool/data/home"
zfs_helper_dir=/usr/share/omarchy/install/config/zfs

if [[ ! -f /usr/lib/security/pam_zfs_key.so ]]; then
  echo "Expected pam_zfs_key.so from zfs-utils" >&2
  exit 1
fi

mkdir -p /etc/mkinitcpio.conf.d /etc/zfs /etc/default
[[ -s /etc/hostid ]] || zgenhostid
zpool set cachefile=/etc/zfs/zpool.cache "$pool"

cat >/etc/mkinitcpio.conf.d/omarchy_hooks.conf <<'EOF'
MODULES+=(zfs)
HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block zfs filesystems)

if [[ -f /etc/vconsole.conf ]]; then
  case $(. /etc/vconsole.conf && echo "${XKBLAYOUT%%,*}") in
    af | am | ara | bd | bg | by | et | ge | gr | il | in | iq | ir | kg | kh | kz | la | lk | mk | mm | mn | mv | np | rs | ru | sy | th | tj | ua) ;;
    *) FILES+=(/etc/vconsole.conf) ;;
  esac
fi
EOF
printf '%s\n' 'FILES+=(/etc/hostid)' >/etc/mkinitcpio.conf.d/zfs_hostid.conf

cat >/etc/default/omarchy-zfs <<EOF
ZFS_HOME_DATASET_PREFIX=$home_prefix
EOF

for helper in zfs-pam-unlock-home zfs-home-cleanup zfs-pam-cleanup-home zfs-pam-home-exists zfs-pam-verify-home; do
  [[ -x $zfs_helper_dir/$helper ]] || {
    echo "Expected executable ZFS helper: $zfs_helper_dir/$helper" >&2
    exit 1
  }
done

cat >/etc/pam.d/zfs-key <<EOF
#%PAM-1.0
auth       [success=ignore default=4] pam_succeed_if.so service in sddm:login:sshd:su-l quiet
auth       [default=3 success=ignore] pam_succeed_if.so uid >= 1000 quiet
auth       [success=ignore default=2] pam_exec.so quiet $zfs_helper_dir/zfs-pam-home-exists
auth       required                   pam_exec.so expose_authtok seteuid quiet $zfs_helper_dir/zfs-pam-unlock-home
auth       required                   pam_zfs_key.so homes=$home_prefix runstatedir=/run/pam_zfs_key
session    [success=ignore default=4] pam_succeed_if.so service in sddm:login:sshd:su-l quiet
session    [default=3 success=ignore] pam_succeed_if.so uid >= 1000 quiet
session    [success=ignore default=2] pam_exec.so quiet $zfs_helper_dir/zfs-pam-home-exists
session    optional                   pam_zfs_key.so homes=$home_prefix runstatedir=/run/pam_zfs_key
session    required                   pam_exec.so quiet $zfs_helper_dir/zfs-pam-verify-home
session    [success=ignore default=3] pam_succeed_if.so service in sddm:login:sshd:su-l quiet
session    [default=2 success=ignore] pam_succeed_if.so uid >= 1000 quiet
session    [success=1 default=ignore] pam_succeed_if.so service = systemd-user quiet
session    optional                   pam_exec.so type=close_session seteuid quiet $zfs_helper_dir/zfs-pam-cleanup-home
password   [default=2 success=ignore] pam_succeed_if.so uid >= 1000 quiet
password   [success=ignore default=1] pam_exec.so quiet $zfs_helper_dir/zfs-pam-home-exists
password   required                   pam_zfs_key.so homes=$home_prefix runstatedir=/run/pam_zfs_key
EOF

grep -Eq '^auth[[:space:]]+include[[:space:]]+zfs-key' /etc/pam.d/system-login || sed -i '/^auth[[:space:]]\+include[[:space:]]\+system-auth/a auth       include    zfs-key' /etc/pam.d/system-login
grep -Eq '^session[[:space:]]+include[[:space:]]+zfs-key' /etc/pam.d/system-login || sed -i '/^session[[:space:]]\+include[[:space:]]\+system-auth/i session    include    zfs-key' /etc/pam.d/system-login
grep -Eq '^password[[:space:]]+include[[:space:]]+zfs-key' /etc/pam.d/system-auth || sed -i '1ipassword   include      zfs-key' /etc/pam.d/system-auth
grep -Eq '^auth[[:space:]]+include[[:space:]]+zfs-key' /etc/pam.d/su-l || sed -i '/^auth[[:space:]]\+required[[:space:]]\+pam_unix\.so/a auth            include         zfs-key' /etc/pam.d/su-l
grep -Eq '^session[[:space:]]+include[[:space:]]+zfs-key' /etc/pam.d/su-l || sed -i '1isession    include      zfs-key' /etc/pam.d/su-l

grep -Eq '^auth[[:space:]]+include[[:space:]]+zfs-key' /etc/pam.d/system-login
grep -Eq '^session[[:space:]]+include[[:space:]]+zfs-key' /etc/pam.d/system-login
grep -Eq '^password[[:space:]]+include[[:space:]]+zfs-key' /etc/pam.d/system-auth
grep -Eq '^auth[[:space:]]+include[[:space:]]+zfs-key' /etc/pam.d/su-l
grep -Eq '^session[[:space:]]+include[[:space:]]+zfs-key' /etc/pam.d/su-l

systemctl enable zfs-import-cache.service zfs-import.target zfs-mount.service zfs.target
systemctl disable snapper-timeline.timer snapper-cleanup.timer limine-snapper-sync.service >/dev/null 2>&1 || true
systemctl mask tmp.mount >/dev/null
[[ -L /etc/systemd/system/tmp.mount && $(readlink /etc/systemd/system/tmp.mount) == /dev/null ]]
chmod 1777 /tmp /var/tmp
