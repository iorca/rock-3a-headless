#!/usr/bin/env bash
# =============================================================================
# Extract a working RTL8822BE driver off THIS machine, so it can be dropped
# into another RadxaOS install of the SAME kernel build.
#
# Run on the machine where WiFi already works.
# Produces:  rtl8822be-bundle-<KVER>.tar.gz
#
#   ./extract-rtl8822be.sh            -> bundle with an install.sh inside
#   ./extract-rtl8822be.sh --overlay  -> also emit ./rootfs-overlay/ for
#                                        stuffing into a rootfs.tar later
#
# HARD REQUIREMENT
#   The target must run the exact same kernel: compare `uname -r` on both
#   boxes. A mismatch (even 6.1.84-17 vs 6.1.84-18) means the .ko will be
#   rejected with "disagrees about version of symbol" / "invalid module format".
# =============================================================================
set -euo pipefail

KVER="$(uname -r)"
MODROOT="/lib/modules/${KVER}"
BUNDLE="rtl8822be-bundle-${KVER}"
OVERLAY=0
[[ ${1:-} == "--overlay" ]] && OVERLAY=1

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ -d ${MODROOT} ]] || die "no ${MODROOT}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/payload"

say "collecting modules for ${KVER}"

# Seed: every rtw88 family module for this kernel, whatever path it landed in.
mapfile -t SEEDS < <(find "${MODROOT}" -type f -name 'rtw*.ko*' -printf '%p\n' 2>/dev/null)
[[ ${#SEEDS[@]} -gt 0 ]] || die "no rtw*.ko* under ${MODROOT} - driver not installed?"

# Walk the dependency closure so we never ship a top-level module alone
# (rtw_8822be needs rtw88_8822b + rtw88_pci + rtw88_core).
declare -A SEEN=()
queue=("${SEEDS[@]}")
while [[ ${#queue[@]} -gt 0 ]]; do
    ko="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n ${SEEN[$ko]:-} ]] && continue
    SEEN[$ko]=1

    rel="${ko#${MODROOT}/}"
    dest="${BUNDLE}/payload/lib/modules/${KVER}/${rel}"
    install -Dm644 "${ko}" "${dest}"

    base="$(basename "${ko%.ko*}")"
    for dep in $(modinfo -F depends "${ko}" 2>/dev/null | tr ',' ' '); do
        dep="${dep%.ko}"
        found="$(find "${MODROOT}" -type f -name "${dep}.ko*" -print -quit 2>/dev/null || true)"
        [[ -n ${found} ]] && queue+=("${found}")
    done
done

printf 'modules collected: %s\n' "${#SEEN[@]}"
for ko in "${!SEEN[@]}"; do printf '  %s\n' "${ko#${MODROOT}/}"; done

# ---------------------------------------------------------------------------
# Firmware blobs - these are what actually get pushed into the silicon
# ---------------------------------------------------------------------------
say "collecting firmware"
for fw in \
    /lib/firmware/rtw88/rtw8822b_fw.bin \
    /lib/firmware/rtw88/rtw8822b_fw-2.bin \
    /lib/firmware/rtl_bt/rtl8822b_fw.bin \
    /lib/firmware/rtl_bt/rtl8822b_config.bin; do
    if [[ -f ${fw} ]]; then
        install -Dm644 "${fw}" "${BUNDLE}/payload${fw}"
        echo "  ${fw}"
    fi
done

# ---------------------------------------------------------------------------
# Modprobe config: keep the generic rtl8xxxu from claiming the BT side
# ---------------------------------------------------------------------------
install -Dm644 /dev/stdin "${BUNDLE}/payload/etc/modprobe.d/blacklist-rtl8xxxu.conf" <<'EOF'
# RTL8822BE exposes Bluetooth over USB; rtl8xxxu grabs it and half-breaks it.
blacklist rtl8xxxu
EOF
install -Dm644 /dev/stdin "${BUNDLE}/payload/etc/modules-load.d/rtl8822be.conf" <<'EOF'
rtw_8822be
EOF

# ---------------------------------------------------------------------------
# Bundle metadata + first-boot depmod unit (belt and braces: works even when
# somebody dropped the .ko straight into a rootfs tar without running depmod)
# ---------------------------------------------------------------------------
install -Dm644 /dev/stdin "${BUNDLE}/payload/etc/systemd/system/depmod-rtw8822be.service" <<'EOF'
[Unit]
Description=Rebuild module dependencies for RTL8822BE
Before=systemd-modules-load.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/depmod -a

[Install]
WantedBy=sysinit.target
EOF

cat >"${BUNDLE}/install.sh" <<'EOS'
#!/usr/bin/env bash
# Install the extracted RTL8822BE driver onto this machine.
# Must run as root, and `uname -r` MUST match the bundle's KVER.
set -euo pipefail
KVER="$(uname -r)"
HERE="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ ${HERE} == *"${KVER}"* ]] || {
    echo "WARNING: bundle is not for this kernel (${KVER})." >&2
    echo "         Refusing to install. Re-extract on a ${KVER} box." >&2
    exit 1
}

cp -a "${HERE}/payload/." /
depmod -a "${KVER}"
systemctl enable depmod-rtw8822be.service
modprobe rtw_8822be
rfkill unblock all 2>/dev/null || true

echo
echo "loaded modules:"
lsmod | grep -i rtw || true
echo
echo "WiFi interfaces:"
ip -brief link show 2>/dev/null | grep -E '^wlan|^wl' || echo "  (none yet - check: journalctl -k | grep rtw)"
EOS
chmod +x "${BUNDLE}/install.sh"

printf '%s\n' "${KVER}" >"${BUNDLE}/KVER"

say "packing"
tar czf "${BUNDLE}.tar.gz" "${BUNDLE}"
rm -rf "${BUNDLE}"

if [[ ${OVERLAY} -eq 1 ]]; then
    tar xzf "${BUNDLE}.tar.gz"
    cp -a "${BUNDLE}/payload/." ./rootfs-overlay/ 2>/dev/null || {
        mkdir -p rootfs-overlay && cp -a "${BUNDLE}/payload/." rootfs-overlay/
    }
    echo "rootfs-overlay/ ready (mirror absolute paths into a rootfs.tar)"
    rm -rf "${BUNDLE}"
fi

say "done"
echo "  ${BUNDLE}.tar.gz  ($(du -h "${BUNDLE}.tar.gz" | cut -f1))"
echo
echo "On the fresh cli box:"
echo "  tar xzf ${BUNDLE}.tar.gz"
echo "  cd ${BUNDLE} && sudo ./install.sh"
echo
echo "Kernel must match: $(cat /dev/null; uname -r)"
