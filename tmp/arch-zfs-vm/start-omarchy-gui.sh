#!/bin/bash
set -euo pipefail

QEMU=${QEMU:-/home/berend/.nix-profile/bin/qemu-system-x86_64}
OVMF_CODE=${OVMF_CODE:-/nix/store/snb7g46xlgpg8zh4awxpwcri6z7brpsc-qemu-10.1.5/share/qemu/edk2-x86_64-code.fd}
DISK=${DISK:-/home/berend/.local/share/omarchy-vms/arch-zfs/arch-zfs-omarchy-edge-test3.qcow2}
SERIAL=${SERIAL:-omarchy-zfs-root}
CPUS=${CPUS:-4}
MEMORY=${MEMORY:-8192}

usage() {
  cat <<USAGE
Usage: $0 [--gl] [--serial]

Environment overrides:
  QEMU=$QEMU
  OVMF_CODE=$OVMF_CODE
  DISK=$DISK
  SERIAL=$SERIAL
  CPUS=$CPUS
  MEMORY=$MEMORY
USAGE
}

video_args=(-device virtio-vga -display gtk)
serial_console=0

while (($#)); do
  case "$1" in
    --gl)
      video_args=(-device virtio-vga-gl -display gtk,gl=on)
      ;;
    --serial)
      serial_console=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ ! -x $QEMU ]]; then
  printf 'QEMU executable not found or not executable: %s\n' "$QEMU" >&2
  exit 1
fi

if [[ ! -f $OVMF_CODE ]]; then
  printf 'UEFI firmware not found: %s\n' "$OVMF_CODE" >&2
  exit 1
fi

if [[ ! -f $DISK ]]; then
  printf 'VM disk not found: %s\n' "$DISK" >&2
  exit 1
fi

if ((serial_console)); then
  extra_args=(-serial stdio)
else
  extra_args=()
fi

exec "$QEMU" \
  -enable-kvm \
  -machine q35 \
  -cpu host \
  -smp "$CPUS" \
  -m "$MEMORY" \
  -boot order=c,menu=off \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=none,id=vdisk,file="$DISK",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=vdisk,serial="$SERIAL",bootindex=0 \
  "${video_args[@]}" \
  -device virtio-keyboard-pci \
  -device virtio-mouse-pci \
  -nic user,model=virtio-net-pci \
  "${extra_args[@]}"
