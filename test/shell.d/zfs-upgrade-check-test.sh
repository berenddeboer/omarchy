#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

check="$ROOT/bin/omarchy-upgrade-to-quattro-zfs-check"
bash -n "$check"
pass "ZFS upgrade preflight has valid shell syntax"

for expected in \
  'Root dataset is' \
  'Pool bootfs is' \
  'Pool capacity is' \
  'keyformat is' \
  '/etc/hostid' \
  'writable vfat ESP' \
  'Working Limine entry' \
  'The [archzfs] repository' \
  'ZFS module exists' \
  '.omarchy-zfs-recovery-tested' \
  'No system changes were made'; do
  grep -F "$expected" "$check" >/dev/null || fail "preflight covers $expected"
done
pass "ZFS upgrade preflight covers storage, recovery, packages, and boot"

if grep -Eq '(^|[[:space:]])(zfs snapshot|pacman -S|limine-update|limine-mkinitcpio)([[:space:]]|$)' "$check"; then
  fail "preflight remains read-only"
fi
pass "ZFS upgrade preflight does not snapshot, install, or rebuild boot files"

grep -F 'OMARCHY_ZFS_CHECK_ROOT' "$check" >/dev/null || fail "preflight supports isolated fixtures"
grep -F 'configuration.tar' "$check" >/dev/null || fail "preflight writes a configuration inventory"
grep -F 'packages-foreign.txt' "$check" >/dev/null || fail "preflight inventories foreign packages"
pass "ZFS upgrade preflight supports fixture tests and inventory export"
