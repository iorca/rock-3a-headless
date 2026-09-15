# RTL8822BE (rtw88) driver overlay

Prebuilt out-of-tree `rtw88` modules for the ROCK 3A headless (cli) image,
ready to be spliced into `rootfs.tar` at build time.

## Provenance

| | |
| --- | --- |
| Extracted from | ROCK 3A board `192.168.1.103`, running the cli image built by this repo |
| Kernel | `6.1.84-17-rk2410-nocsf` (aarch64) |
| Module vermagic | `6.1.84-17-rk2410-nocsf SMP mod_unload modversions aarch64` |
| Extracted | 2026-09-15 |
| Tool | `extract-rtl8822be.sh` (repo root) |

**This overlay is frozen to one kernel release.** A `.ko` only loads when its
vermagic matches `uname -r` byte for byte. If the CI ever builds a rootfs with a
different kernel, `inject-into-rootfs.sh` fails the build on purpose and prints
the version the rootfs actually carries. Do not "fix" that gate by forcing it —
re-extract on a box running the new kernel.

## Contents

```
rootfs-overlay/
  lib/modules/6.1.84-17-rk2410-nocsf/updates/dkms/
      rtw88_core.ko.xz          depends: -
      rtw88_pci.ko.xz           depends: rtw88_core
      rtw88_8822b.ko.xz         depends: rtw88_core
      rtw88_8822be.ko.xz        depends: rtw88_pci,rtw88_8822b   <- top level
  lib/firmware/rtw88/rtw8822b_fw.bin          WiFi firmware
  lib/firmware/rtl_bt/rtl8822b_fw.bin         BT firmware
  lib/firmware/rtl_bt/rtl8822b_config.bin     BT config
  etc/modprobe.d/blacklist-rtl8xxxu.conf      keep rtl8xxxu off the BT side
  etc/modules-load.d/rtl8822be.conf           "rtw88_8822be", autoload at boot
  etc/systemd/system/depmod-rtw8822be.service first-boot depmod
```

`updates/dkms/` has higher priority than `kernel/`, which is exactly what we
want. It is the same directory the driver already lives in on the source board.

### Why a first-boot depmod unit

Nothing in the rsdk pipeline runs `depmod` after the modules are dropped in
(`bdebstrap` -> `rootfs.tar` -> `guestfish tar-in` -> image). Without
`modules.dep`, `modprobe` cannot resolve `rtw88_8822be` -> `rtw88_pci` +
`rtw88_8822b` + `rtw88_core` and nothing loads.

Running `depmod` at build time is not an option: the CI runner is x86_64 and
cross-arch `depmod` against aarch64 `.ko` files is not reliable. So the unit
does it on the target, once, before `systemd-modules-load.service`:

```
Before=systemd-modules-load.service
ExecStart=/usr/sbin/depmod -a
```

## How it gets into the image

`.github/workflows/build-cli.yml` runs `rsdk build` twice when the `rtl8822be`
input is true:

1. pass 1 - normal build, produces `out/<tuple>/rootfs.tar` + `output_512.img`
2. `inject-into-rootfs.sh` appends this overlay's members to `rootfs.tar`
3. pass 2 - `rsdk build` again; `rsdk-build` skips `generate_rootfs` because
   `rootfs.tar` exists, and `generate_image` runs unconditionally

Source of that behaviour (`src/libexec/rsdk/rsdk-build`, `main()`):

```bash
if [[ ! -e "$OUTPUT/$RSDK_OPTION_ROOTFS" ]]; then
    generate_rootfs
fi

generate_image
```

## Manual install on a live board

`rtl8822be-bundle-6.1.84-17-rk2410-nocsf.tar.gz` is the same payload plus an
`install.sh` for machines that are already running. It refuses to install unless
`uname -r` matches.

```sh
tar xf rtl8822be-bundle-6.1.84-17-rk2410-nocsf.tar.gz
cd rtl8822be-bundle-6.1.84-17-rk2410-nocsf
sudo ./install.sh
```

## Re-extracting on a new kernel

```sh
# on a board running the new kernel, with the driver working:
scp extract-rtl8822be.sh radxa@<board>:/tmp/
ssh radxa@<board>  # sudo bash /tmp/extract-rtl8822be.sh
# then replace rootfs-overlay/lib/modules/<old-kver> with the new <kver> dir
```

## Verifying a built image

On the flashed board:

```sh
uname -r                       # must be 6.1.84-17-rk2410-nocsf
lsmod | grep rtw               # 4 modules, nothing else
ip -brief link                 # wlp1s0 present
dmesg | grep -i rtw            # firmware loaded, no "disagrees about version"
```

## Licensing note

`lib/firmware/rtl_bt/rtl8822b_fw.bin` and `lib/firmware/rtw88/rtw8822b_fw.bin`
are Realtek binary blobs redistributed here unmodified, the same way Debian's
`firmware-realtek` ships them. If you fork this repo and want to avoid carrying
blobs, drop the two files and add `firmware-realtek` to the image packages
instead — the `cli` edition may not install it by default, so test.
