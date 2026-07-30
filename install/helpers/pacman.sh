use_omarchy_pacman_config() {
  local mirror="${OMARCHY_MIRROR:-stable}"
  local archzfs_repo=""

  if [[ -f /etc/pacman.conf ]]; then
    archzfs_repo=$(awk '
      /^\[/ { in_archzfs = ($0 == "[archzfs]") }
      in_archzfs { print }
    ' /etc/pacman.conf)
  fi

  if [[ -z $archzfs_repo && $(findmnt -n -o FSTYPE / 2>/dev/null || true) == "zfs" ]]; then
    archzfs_repo=$'[archzfs]\nSigLevel = PackageRequired DatabaseNever\nServer = https://github.com/archzfs/archzfs/releases/download/experimental'
  fi

  sudo cp -f "$OMARCHY_PATH/default/pacman/pacman-$mirror.conf" /etc/pacman.conf
  sudo cp -f "$OMARCHY_PATH/default/pacman/mirrorlist-$mirror" /etc/pacman.d/mirrorlist

  if [[ -n $archzfs_repo ]] && ! grep -q '^\[archzfs\]$' /etc/pacman.conf; then
    printf '\n%s\n' "$archzfs_repo" | sudo tee -a /etc/pacman.conf >/dev/null
  fi
}

export -f use_omarchy_pacman_config
