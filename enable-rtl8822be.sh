#!/usr/bin/env bash
# =============================================================================
# ROCK 3A + RadxaOS (bookworm, Radxa kernel 6.1.84-17-rk2410-nocsf)
# Bring up a Realtek RTL8822BE (M.2 E-key, PCIe WiFi + USB Bluetooth)
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# The Radxa kernel for rock-3a ships with:
#     # CONFIG_RTW88 is not set
# and no Debian package provides an out-of-tree rtw88 build
# (no `rtw88-dkms` in Debian bookworm/trixie/sid). So the module has to be
# built on the board. The *firmware* is already there: `firmware-realtek`
# ships /lib/firmware/rtw88/rtw8822b_fw.bin and rtl_bt/rtl8822b_fw.bin.
#
# PREREQUISITE: you need working networking first — plug in Ethernet,
# because WiFi is exactly what does not work yet.
#
# Usage:  sudo ./enable-rtl8822be.sh
# =============================================================================
set -euo pipefail

KVER="$(uname -r)"
WORKDIR="/usr/local/src"
RTW_DIR="${WORKDIR}/rtw88"
RTW_REPO="https://github.com/lwfinger/rtw88.git"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run me as root"
[[ -r /boot/config-${KVER} ]] || [[ -r /proc/config.gz ]] || true

say "kernel: ${KVER}"

# ---------------------------------------------------------------------------
# 1. Confirm the card is actually seen on PCIe
# ---------------------------------------------------------------------------
say "scanning PCIe for Realtek devices"
if command -v lspci >/dev/null 2>&1; then
    lspci -nn | grep -i realtek || true
fi
if lspci -nn 2>/dev/null | grep -qi 'RTL8822\|10ec:b822\|10ec:c822'; then
    echo "RTL8822BE detected on PCIe."
else
    echo "WARNING: no RTL8822BE visible on PCIe right now."
    echo "         Check the M.2 keying (A/E key slot) and that the card is seated."
    echo "         Continuing anyway - building the module is still safe."
fi

# ---------------------------------------------------------------------------
# 2. Build dependencies + kernel headers
# ---------------------------------------------------------------------------
say "installing build deps and kernel headers for ${KVER}"
apt-get update
apt-get install -y --no-install-recommends \
    "linux-headers-${KVER}" \
    bc \
    build-essential \
    ca-certificates \
    dkms \
    firmware-realtek \
    git \
    kmod \
    wireless-tools \
    wpasupplicant

# ---------------------------------------------------------------------------
# 3. rtw88 out-of-tree driver
# ---------------------------------------------------------------------------
say "fetching rtw88 source"
mkdir -p "${WORKDIR}"
if [[ -d ${RTW_DIR}/.git ]]; then
    git -C "${RTW_DIR}" pull --ff-only
else
    git clone --depth=1 "${RTW_REPO}" "${RTW_DIR}"
fi

say "building rtw88 against ${KVER} (a couple of minutes)"
cd "${RTW_DIR}"
make -j"$(nproc)" KSRC="/lib/modules/${KVER}/build" || {
    die "build failed. Check the log above; if it complains about missing symbols,
     verify 'linux-headers-${KVER}' really matches the running image package
     (apt policy linux-image-${KVER})."
}

say "installing modules"
make install KSRC="/lib/modules/${KVER}/build"
depmod -a "${KVER}"

# ---------------------------------------------------------------------------
# 4. Keep the in-tree rtl8xxxu driver from grabbing the Bluetooth part
# ---------------------------------------------------------------------------
say "blacklisting rtl8xxxu (it mis-handles Realtek combo cards)"
cat >/etc/modprobe.d/blacklist-rtl8xxxu.conf <<'EOF'
# RTL8822BE exposes its Bluetooth side over USB; the generic rtl8xxxu driver
# claims it and leaves a half-working adapter.
blacklist rtl8xxxu
EOF

# ---------------------------------------------------------------------------
# 5. Load now and make it stick
# ---------------------------------------------------------------------------
say "loading rtw_8822be"
modprobe rtw_8822be || die "modprobe failed: $(modprobe -v rtw_8822be 2>&1 | tail -3)"
grep -q '^rtw_8822be$' /etc/modules || echo 'rtw_8822be' >>/etc/modules

rfkill unblock all || true

say "result"
lsmod | grep -i rtw || echo "(no rtw module listed - something went wrong)"
echo
ip -brief link show || true
echo
echo "WiFi should now show as wlan0.Configure it with either:"
echo "  nmtui                       # NetworkManager TUI, easiest"
echo "  nmcli dev wifi connect <SSID> password <PSK>"
echo
echo "Bluetooth (USB side of the card):"
echo "  systemctl enable --now bluetooth"
echo "  bluetoothctl"
echo
echo "Full journal if something misbehaves:"
echo "  journalctl -k -b | grep -Ei 'rtw|realtek|firmware'"
