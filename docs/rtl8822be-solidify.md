name: Solidify RTL8822BE into the headless image
status: DONE - 阶段 1/2/3 已于 2026-09-15 落地，见下方「现状」

---

## 现状（2026-09-15）

| 项 | 结果 |
| --- | --- |
| 源机 | 刷好 cli 镜像的开发板 `192.168.1.103`，`uname-r = 6.1.84-**17**-rk2410-nocsf` |
| 版本对齐 | **已对齐**。源机就是目标镜像本身，第 0 节的 -15/-17 地雷已经不存在 |
| 提取产物 | `drivers/rtl8822be/rootfs-overlay/`（4 个 `.ko.xz` + 3 个 firmware + 3 个配置） |
| 入库 | `drivers/rtl8822be/inject-into-rootfs.sh` |
| CI | `.github/workflows/build-cli.yml` 增加 `rtl8822be` input（默认 true），二段构建注入 |

踩过的坑（都已修，别再踩）：
1. `find -name 'rtw*.ko*'` 会把无关的 **rtw89** 家族一起收进来（板上有 DKMS 装的 `updates/dkms/rtw89_*_git.ko.xz`），一度收了 20 个模块。改成从 `lsmod` 取 `^rtw88` 前缀作种子。
2. lwfinger/rtw88 的顶层模块叫 **`rtw88_8822be`**，不是主线内核里的 `rtw_8822be`。写成后者 `modules-load.d` 会永久加载失败。

---

# 0. 先读这一节，否则后面全是白工

**源机箱的内核必须和目标镜像的内核是同一个构建。**

| | 版本 |
| --- | --- |
| 源机（用户提供） | `6.1.84-**15**-rk2410-nocsf` |
| 目标 cli 镜像（云端构建） | `6.1.84-**17**-rk2410-nocsf` |

**这两个不匹配。** 而且不只是"现在这台机不匹配" —— 我把 Radxa 的 apt 索引（`https://radxa-repo.github.io/rk3568-bookworm/`）整个翻过了，`linux-image-*-rk2410-nocsf` 只剩：

```
linux-image-6.1.84-17-rk2410-nocsf   6.1.84-17   pool/main/l/linux-upstream/...
linux-headers-6.1.84-17-rk2410-nocsf 6.1.84-17   pool/main/l/linux-upstream/...
```

`-15` **已经下架**。所以只要云上一重跑，得到的就一定是 -17。在 -15 上编出来的 `.ko` 搬过去，`modprobe` 会直接给：

```
rtw_8822be: disagrees about version of symbol module_layout
```

没有 workaround。`--force` 也不行，那是 ABI 校验不是版本建议。

## 结论：先把内核对齐，再谈提取

三条路，按推荐顺序：

### 路线 A（推荐）—— 刷新镜像，在板上重编一次

1. 等当前 CI 把 `cli` 镜像跑出来（-17 内核）
2. 烧到 SD 卡，**插网线**
3. `sudo ./enable-rtl8822be.sh` —— 此时编出来的就是贴着 -17 的模块
4. 确认 WiFi 真的能用
5. 再执行下面的阶段 1 提取

好处：版本天然对齐、零猜测、编完当场验证硬件能吃。代价：要刷一次卡。

### 路线 B —— 不刷板，用 -17 的 headers 包在别处编

我用 deb 验证过，`linux-headers-6.1.84-17-rk2410-nocsf_6.1.84-17_arm64.deb`（8.5 MB）里面有：

```
OK  ./usr/src/linux-headers-6.1.84-17-rk2410-nocsf/Makefile
OK  ./usr/src/linux-headers-6.1.84-17-rk2410-nocsf/Module.symvers
OK  ./usr/src/linux-headers-6.1.84-17-rk2410-nocsf/.config
    scripts/...（32 个条目，含 basic/fixdep、mod）
```

标准 Debian headers 布局，**足以编译外部模块**，而且**不需要真的运行这个内核**。

但有个坑必须知道：Debian headers 包里 `scripts/` 下的 host 工具（`fixdep`、`modpost`）是**打包机架构**的二进制 —— 这里是 arm64。在 x86_64 机器上跑不动。所以别直接 `make CROSS_COMPILE=... ，先要有 host 工具重建这一步（`modules_prepare`）。

**稳妥做法是直接在 arm64 环境里原生编译：**

```bash
# 在任意有 docker + qemu binfmt 的机器上（CI runner 天然就有）
docker run --rm -it --platform linux/arm64 -v "$PWD:/work" debian:bookworm bash -c '
  set -e
  apt-get update
  apt-get install -y --no-install-recommends build-essential git bc ca-certificates curl
  cd /work
  curl -LO https://radxa-repo.github.io/rk3568-bookworm/pool/main/l/linux-upstream/linux-headers-6.1.84-17-rk2410-nocsf_6.1.84-17_arm64.deb
  dpkg -i linux-headers-6.1.84-17-rk2410-nocsf_6.1.84-17_arm64.deb
  git clone --depth=1 https://github.com/lwfinger/rtw88.git
  cd rtw88
  make -j"$(nproc)" KSRC=/usr/src/linux-headers-6.1.84-17-rk2410-nocsf
  make install KSRC=/usr/src/linux-headers-6.1.84-17-rk2410-nocsf
'
```

产出的 `.ko` 在 `/usr/src/...` 对应的 `/lib/modules/6.1.84-17-rk2410-nocsf/` 下。
QEMU 慢，预计 15–40 分钟，但一次编译，永久复用。

### 路线 C —— 在 devcontainer 里交叉编译

环境依赖最多，不推荐首先尝试。

---

# 阶段 1 —— 提取（在**跑着 -17 内核且驱动已工作**的那台机上）

## 1.0 验收前提，三条全绿才准继续

```bash
uname -r                                    # 必须是 6.1.84-17-rk2410-nocsf
lsmod | grep rtw                            # 必须有 rtw_8822be / rtw88_core 等
modinfo rtw_8822be | grep vermagic          # 必须含 6.1.84-17-rk2410-nocsf
ip link show wlan0 2>/dev/null              # WiFi 真的能用
```

`vermagic` 那一行是最终的判决书，它必须和目标镜像版本一字不差。

## 1.1 提取

```bash
git clone https://github.com/iorca/rock3a-headless
cd rock3a-headless
sudo ./extract-rtl8822be.sh --overlay
```

产出：

- `rtl8822be-bundle-6.1.84-17-rk2410-nocsf.tar.gz` —— 手工安装用
- `rootfs-overlay/` —— CI 用的绝对路径树：

```
rootfs-overlay/
  lib/modules/6.1.84-17-rk2410-nocsf/.../rtw_8822be.ko
                                          rtw88_8822b.ko
                                          rtw88_pci.ko
                                          rtw88_core.ko
  lib/firmware/rtw88/rtw8822b_fw.bin
  lib/firmware/rtl_bt/rtl8822b_fw.bin
  etc/modprobe.d/blacklist-rtl8xxxu.conf
  etc/modules-load.d/rtl8822be.conf
  etc/systemd/system/depmod-rtw8822be.service
```

## 1.2 验收

`.ko` 必须 ≥ 4 个，且四个名字都在。少一个上层依赖就会 `Unknown symbol`。
脚本已用 `modinfo -F depends` 递归收闭包，不要再手工挑一部分。

# 阶段 2 —— 入库

放到仓库里：

```
rock3a-cli/drivers/rtl8822be/rootfs-overlay/...
```

只带**普通文件**，不要 symlink。然后提交推送。

`.gitattributes` 已经锁了 `*.conf` / `*.service` / `*.sh` 为 LF，`*.ko` / `*.bin` 为 binary —— **别删它**。
Windows 上写出的 CRLF conf 文件会被 kmod 解析失败。

# 阶段 3 —— 改造 workflow

## 3.1 加 input

```yaml
      rtl8822be:
        description: "Inject extracted RTL8822BE modules into rootfs (needs drivers/rtl8822be/rootfs-overlay)"
        required: false
        default: false
        type: boolean
```

## 3.2 在「Build rootfs and image」之后插入

```yaml
      - name: "Inject RTL8822BE modules"
        if: "${{ inputs.rtl8822be }}"
        run: |
          set -euo pipefail
          sudo chown -R "$USER:$(id -gn)" out
          TUPLE="out/${{ env.PRODUCT }}_${{ inputs.suite }}_${{ inputs.edition }}"
          find "$TUPLE" -mindepth 1 ! -name 'rootfs.tar*' -exec rm -rf {} +
          STAGE="$(mktemp -d)"
          cp -a "drivers/rtl8822be/rootfs-overlay/." "$STAGE/"
          mkdir -p "$STAGE/etc/systemd/system/sysinit.target.wants"
          ln -s ../depmod-rtw8822be.service \
                "$STAGE/etc/systemd/system/sysinit.target.wants/depmod-rtw8822be.service"
          tar -C "$STAGE" -rf "$TUPLE/rootfs.tar" .
          echo "--- driver files now inside rootfs.tar ---"
          tar -tf "$TUPLE/rootfs.tar" | grep rtw_8822be
```

## 3.3 紧随其后插入二次构建

```yaml
      - name: "Rebuild image from patched rootfs"
        if: "${{ inputs.rtl8822be }}"
        uses: "devcontainers/ci@v0.3"
        with:
          push: "never"
          runCmd: |
            set -euo pipefail
            src/bin/rsdk shell rsdk build --sector-size 512 \
              --image-name "output_512.img" \
              "${{ env.PRODUCT }}" "${{ inputs.suite }}" "${{ inputs.edition }}"
```

**为什么能这样**（源码依据，别改写成别的形式）：

- `src/libexec/rsdk/rsdk-build`：`if [[ ! -e "$OUTPUT/$RSDK_OPTION_ROOTFS" ]]; then generate_rootfs; fi`
  → rootfs.tar 还在 → 第二次调用**跳过 bdebstrap**，只重新出镜像。
- `src/share/rsdk/build/lib/image/deploy_rootfs.jsonnet`：rootfs.tar 走 `guestfish tar-in <rootfs> /`
  → tar 成员按绝对路径落进镜像根。
- **整条链路没有 depmod** → 必须靠 `depmod-rtw8822be.service` 首启跑一次 `depmod -a` 补 `modules.dep`，
  否则 .ko 在盘上但 `modprobe` 看不见。这就是那个 unit 存在的全部理由。

# 阶段 4 —— 触发与验证

```python
api("POST", "/repos/iorca/rock-3a-headless/actions/workflows/build-cli.yml/dispatches",
    {"ref": "main", "inputs": {
        "suite": "bookworm", "edition": "cli",
        "no_vendor_packages": "false",
        "publish_release": "true",
        "rtl8822be": "true"}})
```

boolean input 传**字符串**。成功返回 **204**。
日志 API 在 run 结束前返回 **404**，中途只能用 `/jobs` 看 step 状态。

三级验证：

| 级别 | 判据 |
| --- | --- |
| CI 层 | 注入步骤里 `tar -tf … \| grep rtw_8822be` 至少打出一行；全流程 success |
| 产物层 | Release/Artifact 里 `output_512.img.xz` 存在且比不含驱动时略大 |
| 板级 | `lsmod \| grep rtw` 有输出；`ip link` 有 `wlan0`；`rfkill list` 无 blocked |

板级排查顺序：

```bash
journalctl -k -b | grep -Ei 'rtw|8822|firmware'
ls /lib/modules/$(uname -r)
depmod -a && modprobe -v rtw_8822be
modinfo rtw_8822be | grep vermagic     # 与 uname -r 比对
```

# 环境与陷阱

**本机 shell 是坏的**（Git Bash 缺 coreutils，`mkdir`/`ls`/`head`/`sleep` 全 `command not found`）。用：

```
C:/Users/orca/.workbuddy/binaries/python/versions/3.13.12/python.exe
```

git 在 `C:\Program Files\Git\cmd\git.exe`，无 `gh`、无 ssh key。推送走 HTTPS + PAT，认证头必须 **Basic**：

```python
basic = base64.b64encode(("x-access-token:" + TOK).encode()).decode()
subprocess.run([GIT, "-c", "http.extraHeader=Authorization: Basic " + basic] + args)
```

踩过的坑：

1. **别加 `docker system prune -a -f`** —— 它会删掉 buildx builder 的镜像，devcontainer 构建时 nix feature 报
   `opening lock file /nix/var/nix/db/big-lock: Permission denied`。第一次构建就是这么死的。只删路径，不碰 docker。
2. **别省掉 `docker/setup-buildx-action@v3`。**
3. **一次只改一个变量。** 先把最朴素的 `cli` 跑绿，再叠驱动注入。
4. `find … ! -name 'rootfs.tar*'` 那行别写错 —— 写错会把唯一的贵产物删了，第二次构建重新跑一遍 bdebstrap。
5. 别找 `--include` 之类的命令行口子，`rsdk build` 没有；rootfs 包列表在 rsdk 自己的 jsonnet 里。
   本方案刻意绕开 fork rsdk，别绕回去。
6. 不要在 Windows 上手工编辑 overlay 里的 `.conf` / `.service`（会写进 CRLF）。
