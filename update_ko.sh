#!/usr/bin/env bash
#
# build-install-cp210x.sh
#   ONE-SHOT: install headers -> build cp210x.ko against the RUNNING kernel ->
#   live-swap it (coordinating gpsd) -> PERSIST robustly for next boot.
#
# Usage:  ./build-install-cp210x.sh [SOURCE_DIR]
#         SOURCE_DIR defaults to the directory this script lives in; it must
#         contain the Makefile + cp210x.c. Self-elevates with sudo.
#
# WHY THE EARLIER VERSION "WORKED ON RE-RUN BUT NOT AFTER REBOOT":
#   The live load used `insmod <file>` (always YOUR module). Boot-time loading
#   uses `modprobe cp210x`, which resolves via depmod precedence -- and the
#   stock in-tree cp210x can win. This version writes a depmod.d override so
#   the updates/ copy deterministically wins, rebuilds the initramfs if cp210x
#   lives there, verifies the resolution, and WARNS if root is overlay/RO
#   (in which case persistence is impossible -- see the printed note).
#
# Headers package note: 'linux-headers-`uname -r`-generic' is an UBUNTU name.
# On Debian / Raspberry Pi OS uname -r already carries the flavour
# (e.g. ...+rpt-rpi-2712); the correct package is 'linux-headers-$(uname -r)'.

set -euo pipefail

KREL="$(uname -r)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRCDIR="${1:-$SCRIPT_DIR}"
KO="$SRCDIR/cp210x.ko"
MODULE_NAME="cp210x"

if [[ $EUID -ne 0 ]]; then
    echo "Re-running under sudo..." >&2
    exec sudo -- "$0" "$SRCDIR"
fi

[[ -f "$SRCDIR/Makefile" ]] || { echo "ERROR: no Makefile in $SRCDIR" >&2; exit 1; }

# === 0. Persistence pre-check: is the root FS volatile? ====================
# This is the #1 reason a reboot "loses" the module. Detect and warn LOUDLY.
root_fstype="$(findmnt -no FSTYPE / 2>/dev/null || true)"
root_opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
if [[ "$root_fstype" == overlay* ]] || [[ ",$root_opts," == *,ro,* ]]; then
    echo "############################################################" >&2
    echo "WARN: root fs = '$root_fstype' opts='$root_opts'." >&2
    echo "      Writes to /lib/modules and /etc are likely VOLATILE and" >&2
    echo "      will be DISCARDED on reboot. This fully explains 'works" >&2
    echo "      until reboot'. Disable the overlay (raspi-config / DietPi" >&2
    echo "      overlay setting) or write to the underlying RW layer." >&2
    echo "############################################################" >&2
fi

# === 1. Install kernel headers for the RUNNING kernel ======================
echo ">> Installing headers: linux-headers-$KREL"
apt-get update
if ! apt-get install -y "linux-headers-$KREL"; then
    echo "WARN: 'linux-headers-$KREL' not installable (old header versions get" >&2
    echo "      purged from the repo index). Fallbacks: 'apt install linux-headers-rpi-2712'" >&2
    echo "      installs headers for the LATEST kernel -> reboot so uname -r matches;" >&2
    echo "      or use rpi-source for the exact running kernel." >&2
fi
# Hard gate: cannot build without the build tree for THIS kernel.
if [[ ! -e "/lib/modules/$KREL/build/Makefile" ]]; then
    echo "ERROR: /lib/modules/$KREL/build missing -> no headers for running kernel $KREL. Aborting." >&2
    exit 1
fi

# === 2. Build against the running kernel ===================================
# cd in a subshell so the Makefile's path resolves to $SRCDIR regardless of
# whether it uses $(CURDIR) or $(PWD).
echo ">> Building ${MODULE_NAME}.ko in $SRCDIR"
( cd "$SRCDIR" && make clean && make )
[[ -f "$KO" ]] || { echo "ERROR: build produced no $KO" >&2; exit 1; }

# === 3. Pre-flight: vermagic must match the running kernel =================
vm="$(modinfo -F vermagic "$KO" 2>/dev/null || true)"
case "$vm" in
    "$KREL "*|"$KREL") echo ">> vermagic OK: $vm" ;;
    *) echo "ERROR: vermagic mismatch -> module='$vm' running='$KREL'. Aborting; gpsd untouched." >&2
       exit 1 ;;
esac

# === 4. Persist FIRST, deterministically, then verify ======================
# 4a. depmod override so the updates/ copy beats the in-tree cp210x for every
#     kernel. Syntax: `override <module> <kernelver|*> <subdir>` (man depmod.d).
install -d /etc/depmod.d
cat > /etc/depmod.d/cp210x.conf <<'EOF'
# Make the custom updates/cp210x win over the in-tree kernel/.../cp210x.
override cp210x * updates
search updates extra built-in weak-updates kernel
EOF

# 4b. Stage the module and rebuild dep/alias data for THIS kernel.
install -D -m 0644 "$KO" "/lib/modules/$KREL/updates/${MODULE_NAME}.ko"
depmod -a "$KREL"

# 4c. VERIFY what modprobe would actually load at boot. This is the check
#     that would have caught the original bug.
resolved="$(modinfo -F filename "$MODULE_NAME" 2>/dev/null || true)"
echo ">> modprobe would load: ${resolved:-<none>}"
case "$resolved" in
    *"/updates/"*) echo ">> precedence OK (updates/ wins)";;
    *) echo "WARN: resolves to '${resolved}', NOT updates/. Boot may load the stock module." >&2
       echo "      Inspect ordering in /lib/depmod.d and /etc/depmod.d." >&2;;
esac

# 4d. If cp210x is baked into the initramfs, refresh it so the early copy
#     matches. Best-effort; only acts if an initrd exists AND contains cp210x.
initrd="/boot/initrd.img-$KREL"
if command -v update-initramfs >/dev/null 2>&1 && [[ -f "$initrd" ]]; then
    if lsinitramfs "$initrd" 2>/dev/null | grep -qE "(^|/)${MODULE_NAME}\.ko(\.xz)?$"; then
        echo ">> cp210x found in initramfs; rebuilding $initrd"
        update-initramfs -u -k "$KREL"
    fi
fi

# 4e. Force-load at boot. With the override above, this (and udev autoload)
#     now resolve to the updates/ copy. Redundant for hotplug but harmless.
echo "$MODULE_NAME" > /etc/modules-load.d/cp210x.conf

# === 5. Live swap on the running kernel (coordinating gpsd) =================
trap 'echo "FAILED -- restarting gpsd" >&2; systemctl start gpsd.socket gpsd.service 2>/dev/null || true' ERR

systemctl stop gpsd.socket
systemctl stop gpsd.service

rmmod "$MODULE_NAME" 2>/dev/null || echo "note: ${MODULE_NAME} not loaded (or built-in) -- continuing"
modprobe usbserial
modprobe "$MODULE_NAME"            # now resolves to updates/ via the override
# (was: insmod "$KO" -- using modprobe here exercises the SAME path as boot,
#  so a success here proves the boot path will also work.)

systemctl restart gpsd.service
systemctl start  gpsd.socket
systemctl restart chrony          # [REVIEW] often unnecessary/harmful to discipline

trap - ERR

# === 6. Final confirmation =================================================
echo ">> Loaded module file: $(modinfo -F filename "$MODULE_NAME" 2>/dev/null || echo '<none>')"
echo ">> Done. If root is NOT overlay/RO, this now persists across reboot."
echo ">>   Verify after reboot: modinfo -F filename cp210x   (expect .../updates/...)"
