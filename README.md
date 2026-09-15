# ROCK 3A —— 去桌面 + GitHub Actions 云端编译

**仓库**：https://github.com/iorca/rock-3a-headless
**构建日志**：https://github.com/iorca/rock-3a-headless/actions/workflows/build-cli.yml

首次构建 run `#1` 已触发：`cli` edition / `bookworm` / 发布到 Release。

## 结论先行

原仓库 `radxa-build/rock-3a` 只有 workflow，**不出命令行镜像**，原因在产品清单里：

`RadxaOS-SDK/rsdk` → `src/share/rsdk/configs/products.json`：

```json
{
  "product": "rock-3a",
  "soc": ["rk3568"],
  "sector_size": [512],
  "supported_suite": ["bookworm"],
  "supported_edition": ["kde"]     // ← 只有 KDE 桌面
}
```

官方 `build.yaml` 的 matrix 是读这张表动态生成的（`.github/actions/query`），所以矩阵里永远只会出现 `kde`。

**但是——rsdk 本身完全支持 `cli` edition**，而且**不做白名单校验**。

`src/libexec/rsdk/rsdk-build` 里就一行：

```bash
SUITE="${2:-$(jq ...supported_suite[0] ...)}"
EDITION="${3:-$(jq ...supported_edition[0] ...)}"
```

edition 就是第 3 个位置参数，直接喂给 jsonnet，**没有任何 `supported_edition` 成员检查**。所以：

```bash
rsdk build rock-3a bookworm cli
```

是合法的。rsdk 里 `packages.libjsonnet` 已经内置 branches：`cli` / `kde` / `xfce` / `sway` / `i3` / `gnome` / `core`。全 rsdk 有 14 个产品的 `supported_edition` 里就有 `cli`，代码路径是被验证过的。

**唯一要改的就是把 `edition` 从 `kde` 换成 `cli`，绕过 matrix 查询。**

---

## 用法（三步）

### 1. Fork / 新建仓库

推荐**新建一个空私有仓库**（比如 `rock-3a-headless`），而不是 fork 官方仓库。
原因：fork `radxa-build/rock-3a` 会继承它那套 `prepare_release` job（`rbuild-changelog`、`tag` 冲突检查、`softprops/action-gh-release`），对你自建镜像全是负担。

### 2. 把 `build-cli.yml` 放进去

```
.github/workflows/build-cli.yml
```

本 workflow 完整的构建链路（对齐官方 build action 的实现）：

| 步骤 | 作用 |
| --- | --- |
| Free disk space | GH runner 只有 ~14GB，先删 dotnet/android/jvm 等预装 junk |
| `RadxaOS-SDK/rsdk/.github/actions/setup@main` | checkout rsdk(+子模块) / KVM 权限 / QEMU binfmt / devcontainer 预热 |
| `devcontainers/ci@v0.3` | 在 devcontainer 里跑 `rsdk build`，产出 `output_512.img` + `rootfs.tar` |
| Compress and checksum | `xz -vT 0`（GHA runner 默认无 `xz -T`，devcontainer 里有），生成 sha512 |
| Upload to Artifacts | 保留 7 天 |
| Publish to Release（可选） | 勾 `publish_release` 才跑 |

### 3. 手动触发

`Actions` → `Build ROCK 3A CLI image (headless, no desktop)` → `Run workflow`

参数：

- **suite**: `bookworm`（rock-3a 只支持这个）
- **edition**:
  - `cli`（推荐）= `core` 包 + `base` 包：ssh/tmux/vim/i2c-tools/spi-tools/gpiod/pipewire-audio/samba/htop… **无任何 X/Wayland**
  - `core` = 极简：`init` `sudo` `login` `ssh` `network-manager` `wpasupplicant` `bluetooth` + kernel/u-boot/radxa-firmware，其他全没有
- **no_vendor_packages**: 跳过 `task-rock-3a` 的 recommends，镜像更小
- **publish_release**: 是否额外发布会到 Release

产物在 `out/rock-3a_bookworm_cli/`：`output_512.img.xz`、`rootfs.tar.xz`、`sha512sum`。

> 注意：必须先去仓库 `Settings → Actions → General → Workflow permissions` 选 **Read and write**，否则 release 上传会 403。只传 Artifact 也需要该权限（默认已是 read-write 的话不用动）。

---

## 时间 / 成本诚实预期

- runner 是 x86 + QEMU 跑 arm64 rootfs，一次完整构建 **1.5–3 小时**。`timeout-minutes: 360` 已留足。
- 私有仓库免费额度 2000 分钟/月（且私有 Linux runner 每分钟计 2 分钟），**一次构建可能吃掉 1/3 额度**。
- `cli` 镜像 xz 后约 400–600 MB。免费账户 Artifact 总空间 500MB（Free）/ 更大（Pro），**retention 设 7 天，下完就删**。真要长期存就走 Release（单文件上限 2GB）。

---

## 进阶：进一步裁剪

`cli` 还是有 `samba`、`avahi-daemon`、`pipewire-audio`、`alsa-utils`、`exfat-fuse`、`ntfs-3g`、`python3-pip` 之类。要更狠：

1. 换 `core` edition —— 一步到位，代价是没有 `vim`/`htop`/`i2c-tools` 这些。
2. Fork `RadxaOS-SDK/rsdk`，改
   `src/share/rsdk/build/mod/packages/categories/base.libjsonnet`
   里的 `mmdebstrap.packages` 列表，删掉不要的；然后本 workflow 里的
   `RadxaOS-SDK/rsdk/.github/actions/setup@main` 改成你自己仓库路径
   （`${{ github.repository_owner }}/rsdk/.github/actions/setup@<branch>`）。
3. `rsdk build --no-vendor-packages` 关掉 `task-rock-3a` 的推荐依赖（已经在 input 里暴露）。

---

## 原仓库方案的最小 patch（不推荐，仅备查）

如果你坚持 fork `radxa-build/rock-3a` 并在原地改，两处：

`.github/workflows/build.yaml`：

```diff
     strategy:
       matrix:
-        edition: "${{ fromJSON(needs.prepare_release.outputs.editions )}}"
+        edition:
+        - "cli"
         product:
         - "rock-3a"
         suite: "${{ fromJSON(needs.prepare_release.outputs.suites )}}"
```

这样 `- uses: RadxaOS-SDK/rsdk/.github/actions/build@main` 拿到 `edition: cli`，
最终执行的就是 `rsdk build rock-3a bookworm cli`，**能编过**。

不推荐它的原因：`prepare_release` 依赖外部 `radxa-repo/rbuild-changelog@main`（第三方 action，随时可能挂），并且会占用 `rsdk-r<N>` tag 命名空间 —— 你不是 Radxa，没必要。

---

## 刷机：能不能直接跑

**能。** `output_512.img` 是整盘镜像，SD 卡写进去上电就走，**不需要 RKDevTool / maskrom**。

源码依据（均在 `RadxaOS-SDK/rsdk` 里）：

- `src/share/rsdk/configs/socs.json`：`rk3568` → `firmware_type: "u-boot"`、`partition_table_type: "gpt"`
- `build/mod/packages/categories/core.libjsonnet`：只有 `product_firmware_type(product) == "edk2"` 才装 systemd-boot —— rock-3a 命中 else 分支，跳过
- `build/rootfs.jsonnet`：`chroot "$1" sh -c "u-boot-update"` → U-Boot extlinux 引导

所以链路是 GPT 分区 + 镜像头部的 U-Boot idbloader + `/boot` 上的 extlinux.conf，`dd` 或 Etcher 整盘写即可。

**三个前提：**

1. **首次启动必须接串口（或 HDMI + 键盘）**。`core`/`cli` 镜像都带 `rsetup-config-first-boot`，首个 boot 走交互向导创建账号；走完之前**没有可用账号，SSH 连不上**。这是 headless 场景唯一的坑。
2. SD 卡 ≥ 16GB。`cloud-initramfs-growroot` 会在首启自动扩根分区。
3. 想直接写 eMMC：先用 SD 卡起系统，再 `rsetup` → Install to eMMC；或走 maskrom + RKDevTool。

---

## RTL8822BE：内核里没有这个驱动

**确定结论：刷完直接没网。**

我把 Radxa 的内核 deb 拉下来读了它的 config：

```
pool/main/l/linux-upstream/linux-image-6.1.84-17-rk2410-nocsf_6.1.84-17_arm64.deb
  ./boot/config-6.1.84-17-rk2410-nocsf

  # CONFIG_RTW88 is not set      ← rtw88 整个家族没编
  CONFIG_RTW89=m                  ← 只有更新的 RTW89 家族
```

RTL8822BE 属于 **rtw88** 家族（模块名 `rtw_8822be`），不是 RTW89，所以内核里没有这个模块。

| 需要的 | 状态 |
| --- | --- |
| WiFi / BT firmware（`rtw8822b_fw.bin`、`rtl8822b_fw.bin`） | ✅ 镜像里已有，`core` 包列表就含 `firmware-realtek` |
| 内核模块 `rtw_8822be` | ❌ 内核没编译 |
| Debian 现成 DKMS 包 | ❌ `sources.debian.org` 查无 `rtw88-dkms`（bookworm / trixie / sid 都没有） |

所以：**必须自己编译。**

### 板上编译（推荐，先验证硬件）

先插网线——WiFi 正是不能用的那个。然后：

```bash
sudo ./enable-rtl8822be.sh
```

脚本做的事：装 `linux-headers-$(uname -r)` → clone `lwfinger/rtw88` → `make KSRC=/lib/modules/$KVER/build` → `make install` → `depmod` → 拉黑会抢 USB 蓝牙端的 `rtl8xxxu` → `modprobe rtw_8822be` 并写进 `/etc/modules`。

跑完用 `nmtui` 配 WiFi、`bluetoothctl` 配蓝牙。

### 想把它做进镜像

rsdk 的 rootfs 包列表写在它自己的 jsonnet 里（`build/mod/packages/categories/base.libjsonnet`），`rsdk build` 命令行没有 `--include` 之类的口子。要进镜像只能 **fork rsdk、改 jsonnet**，再把 workflow 里的 `RadxaOS-SDK/rsdk/.github/actions/setup@main` 换成你的 fork。

代价：多维护一个 rsdk fork（要跟上游同步）。收益：刷完就有网。
