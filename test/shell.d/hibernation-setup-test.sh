#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

if [[ ! -f /sys/power/image_size ]]; then
  skip "hibernation is unavailable; skipping setup prompt test"
  exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"

cat >"$tmpdir/bin/omarchy-cmd-missing" <<'EOF'
#!/bin/bash
exit 1
EOF

cat >"$tmpdir/bin/grep" <<'EOF'
#!/bin/bash
exit 1
EOF

cat >"$tmpdir/bin/free" <<'EOF'
#!/bin/bash
if [[ ${LC_ALL:-} == "C" ]]; then
  printf 'Mem: 31Gi 1Gi 30Gi\n'
else
  printf '内存： 31Gi 1Gi 30Gi\n'
fi
EOF

cat >"$tmpdir/bin/gum" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$PROMPT_LOG"
exit 1
EOF

# The setup asks for hibernation only on a Btrfs root: a ZFS root has no
# swapfile to resume from, so the ZFS fork skips the whole thing. The stub
# reports the root filesystem the test asks for.
cat >"$tmpdir/bin/findmnt" <<'EOF'
#!/bin/bash
printf '%s\n' "${TEST_FSTYPE:-btrfs}"
EOF

chmod +x "$tmpdir/bin/"*

env -u LC_ALL PROMPT_LOG="$tmpdir/prompt" PATH="$tmpdir/bin:$PATH" \
  "$ROOT/bin/omarchy-hibernation-setup"

[[ $(<"$tmpdir/prompt") == "confirm Use 31Gi on boot drive to make hibernation available?" ]] ||
  fail "hibernation setup reads memory size independently of the user's locale"
pass "hibernation setup reads memory size independently of the user's locale"

rm -f "$tmpdir/prompt"
zfs_output=$(env -u LC_ALL PROMPT_LOG="$tmpdir/prompt" TEST_FSTYPE=zfs PATH="$tmpdir/bin:$PATH" \
  "$ROOT/bin/omarchy-hibernation-setup" 2>&1)
[[ $zfs_output == *"requires Btrfs root filesystem"* ]] ||
  fail "hibernation setup says why it skips a non-Btrfs root"
[[ ! -s $tmpdir/prompt ]] || fail "hibernation setup does not prompt on a non-Btrfs root"
pass "hibernation setup skips a root without a swapfile to resume from"
