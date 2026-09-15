#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# inject-into-rootfs.sh - splice a prebuilt kernel-module overlay into an rsdk
# rootfs.tar, so that the following `rsdk build` bakes it into the image.
#
#   usage: inject-into-rootfs.sh <out-dir> <overlay-dir>
#   e.g.   inject-into-rootfs.sh out/rock-3a_bookworm_cli \
#                                drivers-src/drivers/rtl8822be/rootfs-overlay
#
# WHY THIS WORKS (RadxaOS-SDK/rsdk, src/libexec/rsdk/rsdk-build, main()):
#
#     if [[ ! -e "$OUTPUT/$RSDK_OPTION_ROOTFS" ]]; then
#         generate_rootfs          # <-- bdebstrap, the expensive part
#     fi
#     generate_image               # <-- unconditional
#
# So: run `rsdk build` once (produces rootfs.tar + image), append our members to
# rootfs.tar, run `rsdk build` a second time. The second run skips bdebstrap
# entirely and only regenerates the image from the patched tar. No rsdk patching,
# no change to the way pass 1 produces the rootfs.
#
# Run this INSIDE the rsdk devcontainer (it needs GNU tar with --concatenate and
# a rootfs.tar owned by the current user - rsdk chowns it at the end of pass 1).
# ---------------------------------------------------------------------------
set -euo pipefail

OUT="${1:?usage: inject-into-rootfs.sh <out-dir> <overlay-dir>}"
OVERLAY_RAW="${2:?usage: inject-into-rootfs.sh <out-dir> <overlay-dir>}"

die() { echo "inject: ERROR: $*" >&2; exit 1; }
say() { echo "inject: $*"; }

[[ -f ${OUT}/rootfs.tar ]] || die "no rootfs.tar under ${OUT} - run 'rsdk build' first"
[[ -d ${OVERLAY_RAW} ]] || die "overlay dir not found: ${OVERLAY_RAW}"
OVERLAY="$(cd "${OVERLAY_RAW}" && pwd)"
ROOTFS="${OUT}/rootfs.tar"

# ---------------------------------------------------------------------------
# 1. Kernel version gate.
#
#    A .ko only loads when its vermagic matches `uname -r` exactly. Baking in a
#    stale module produces an image that looks fine and silently has no WiFi.
#    Fail loudly instead: print the version this rootfs actually carries.
# ---------------------------------------------------------------------------
mapfile -t OVERLAY_KVERS < <(find "${OVERLAY}/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
(( ${#OVERLAY_KVERS[@]} == 1 )) ||
	die "expected exactly one kernel version under ${OVERLAY}/lib/modules, got: ${OVERLAY_KVERS[*]:-none}"
KVER="${OVERLAY_KVERS[0]}"
say "overlay was built for kernel: ${KVER}"

LIST="$(mktemp)"
trap 'rm -f "${LIST}" "${PAYLOAD:-}" "${FILELIST:-}"' EXIT
tar -tf "${ROOTFS}" >"${LIST}"
say "rootfs.tar has $(wc -l <"${LIST}") members"

if ! grep -qm1 "lib/modules/${KVER}/" "${LIST}"; then
	{
		echo "inject: ERROR: rootfs carries no lib/modules/${KVER}."
		echo "        Kernel version(s) actually present in this rootfs:"
		sed -nE 's#^\./?lib/modules/([^/]+)/.*#        - \1#p' "${LIST}" | sort -u
		echo "        The .ko files would never load (vermagic mismatch)."
		echo "        Re-extract the driver on a box running the new kernel"
		echo "        and update drivers/rtl8822be/ before building again."
	} >&2
	exit 1
fi
say "kernel version matches the rootfs"

# ---------------------------------------------------------------------------
# 2. Match the member-naming convention already used inside rootfs.tar.
#    bdebstrap writes "./lib/...", but do not assume it.
# ---------------------------------------------------------------------------
first="$(head -1 "${LIST}")"
case "${first}" in
./*) PREFIX="./" ;;
*) PREFIX="" ;;
esac
say "tar member prefix: '${PREFIX}' (first member: '${first}')"

# ---------------------------------------------------------------------------
# 3. Build the payload tar and concatenate it onto rootfs.tar.
#    Later members win on extraction, and every path here is new, so this is a
#    pure addition.
# ---------------------------------------------------------------------------
FILELIST="$(mktemp)"
(cd "${OVERLAY}" && find . -mindepth 1 -printf '%P\0' | sort -z) >"${FILELIST}"
PAYLOAD="$(mktemp /tmp/rtl8822be-payload.XXXXXX.tar)"
tar -cf "${PAYLOAD}" \
	-C "${OVERLAY}" \
	--owner=0 --group=0 --numeric-owner \
	--transform "s|^|${PREFIX}|" \
	--no-recursion --null -T "${FILELIST}"

before="$(stat -c %s "${ROOTFS}")"
tar --concatenate --file="${ROOTFS}" "${PAYLOAD}"
after="$(stat -c %s "${ROOTFS}")"
say "rootfs.tar: ${before} -> ${after} bytes (+$((after - before)))"

# ---------------------------------------------------------------------------
# 4. Report what actually went in (payload is tiny, listing it is cheap).
# ---------------------------------------------------------------------------
say "injected files:"
tar -tf "${PAYLOAD}" | sed 's/^/    /'

for m in rtw88_core rtw88_pci rtw88_8822b rtw88_8822be; do
	grep -q "/${m}\.ko\.xz$" "${LIST}" && continue
	tar -tf "${PAYLOAD}" | grep -q "/${m}\.ko\.xz$" ||
		die "module ${m}.ko.xz missing from the payload"
done
say "all four rtw88 modules present"
say "NOTE: no depmod runs at build time (cross-arch depmod is unreliable)."
say "      /etc/systemd/system/depmod-rtw8822be.service rebuilds modules.dep"
say "      on the target's first boot, before systemd-modules-load."
