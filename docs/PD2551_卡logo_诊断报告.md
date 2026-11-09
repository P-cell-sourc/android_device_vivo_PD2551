# PD2551（iQOO V2551A）OrangeFox 卡第二屏 logo 诊断报告

> 对比对象：`P-cell-sourc/PD2551`（你现在的树） vs `rtyutechstudio/PD2183-twrp`（第三方可用的 X80 树）
> 依据：两仓库 main 分支源码 + `prebuilt/` 二进制实测拆解（kernel、dtb、124 个 .ko、平台 vendor_ramdisk）

---

## 一、结论先行

**不是分辨率或主题问题。按证据强度排序：**

| 优先级 | 问题 | 性质 | 后果 |
|---|---|---|---|
| **P0** | 重打包 vendor_boot 时**丢掉了 `androidboot.selinux=permissive`** | 已证实 | SELinux enforcing → adbd/logd/服务被拒 → **卡住 + 抓不到 log** |
| **P0** | 手写 `TW_SCREEN_BLANK_ON_BOOT := true`（PD2183 是注释掉的） | 已证实（与可用树相反） | 启动即关背光，新 panel 写回亮度失效 → **黑屏假死** |
| ~~P1~~ | ~~kernel 与 124 个 .ko 来自两次不同构建~~ | **已排除（见第四节）** | 拿官方全量 OTA 逐字节比对，二者本就同源，差异是 GKI 正常现象 |
| **P1** | 二进制拼接 cpio，且 fragment 全部按 `platform` 打包 | 已用原厂结构证实 | init 覆盖冲突；TWRP rootfs 在 normal boot 也被加载，顶掉 Android |
| P2 | `BGRA_8888` / `armv8-a` / A/B 与 recovery 分区语义混用 | 配置瑕疵 | 颜色异常、性能、build 告警 |

**先做 P0 两项**，大概率就能进主界面，并且在进不去时也能抓到日志。

---

## 二、P0-1：`permissive` 根本没进 vendor_boot（这是"抓不到 log"的答案）

`BoardConfig.mk:55-56`：

```make
BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2 erofs.reserved_pages=256 ...
BOARD_KERNEL_CMDLINE += androidboot.selinux=permissive
```

`BOARD_KERNEL_CMDLINE` **只作用于 `boot.img`**。

而 `package-vendor-boot.sh:42` 在重打 vendor_boot 时，用的是自己写死的一段字符串：

```bash
VENDOR_CMDLINE="bootopt=64S3,32N2,64N2 erofs.reserved_pages=256 product.version=... region_ver=W10 product.solution=MTK"
```

→ 没有 `androidboot.selinux=permissive`，也没有引用 `BOARD_VENDOR_CMDLINE`。

**而你刷的是 vendor_boot，boot.img 还是原厂的**（README 写的就是 "flash the built vendor_boot.img"）。原厂 boot.img 的 cmdline 里当然没有 permissive。

所以设备实际以 **SELinux enforcing** 启动 recovery。TWRP 的 `recovery` domain 只带 system sepolicy，不认 `u:r:update_engine:s0`、`vendor.keymint-trustonic`、以及去 exec `/vendor/bin/hw/*` 这些规则：

- `adbd` 起不来 → `adb devices` 空白 → **没 log**
- `logd` 写 `/dev/socket/logd` 被拒 → `/tmp/recovery.log` 可能是空的
- `init.recovery.mt6899.rc` 里 `exec u:r:update_engine:s0 .../mtk_plpath_utils` 直接失败
- vold / keymint / gatekeeper 这条解密链全部起不来

**为什么 PD2183 没事**：它是 header v2 + 独立 recovery 分区，`recovery.img` 的 cmdline 本来就等于 `BOARD_KERNEL_CMDLINE`，permissive 自动带上。换成 GKI 的 vendor_boot 后这条链路断了 —— 这是"照抄"最容易踩的坑，也是你现在这棵树最要命的一处。

修复见第八节第 2 步。

---

## 三、P0-2：`TW_SCREEN_BLANK_ON_BOOT`

```make
# PD2183（能用）
#TW_SCREEN_BLANK_ON_BOOT := true     ← 注释掉的

# PD2551（卡住）
TW_SCREEN_BLANK_ON_BOOT := true       ← 打开的
```

这个开关让 TWRP 在 UI 初始化后立刻把背光写到 0。新面板（尤其 LTPO/高刷 OLED）在 recovery 下 often 无法通过 sysfs 重新点亮，表现就是**屏幕停在最后一帧 splash，触摸点了没反应** —— 和你描述完全一致。

先注释掉，成本最低。

另外 `TARGET_RECOVERY_PIXEL_FORMAT` PD2183 是 `RGBX_8888`，你写 `BGRA_8888`，若面板是 RGB 排列会偏色，一并改回。

---

## 四、P1-1（已排除）：vermagic 前缀不同是 GKI 的正常状态

> 2026-11-09 用你提供的官方全量 OTA（`PD2551_A_16.0.15.3.W10`，9.16 GB）做了交叉验证，**本项不成立，已从阻断项中移除**。

### 原始疑点

```
prebuilt/kernel  : ...-gb57af212129c-abogki457297774-4k
124 个 .ko       : ...-g131232aa79fe-4k
```

### OTA 实测结果

从 `payload.bin` 解出 `boot.img`，再拆出 kernel 逐字节比对：

| 比对项 | 结果 |
|---|---|
| OTA `boot.img` 的 kernel vs 仓库 `prebuilt/kernel` | **SHA256 完全相同**：`c20c28965f97239d1f37a384537f88415351564ec7019ecb05b402fc57e7b511`（36,657,664 B） |
| OTA `vendor_dlkm.img` 里 12 个同名 `.ko` vs 仓库同名文件 | **12/12 字节一致** |
| OTA 自带的 `.ko` vermagic | `6.6.89-android15-8-g131232aa79fe-4k`，与仓库一字不差 |

**结论：仓库里的 kernel 和模块就是从这份官方 OTA 原样提出来的，本就同源。不存在"两次不同构建"。**

### 为什么两边 vermagic 不一样

这是 GKI 的标准行为：

- kernel 是 Google 的 GKI 通用内核，串里带 `-abogki<id>`，hash 指向 GKI 分支；
- vendor 模块由厂商在自己分支编译，hash 指向厂商 commit；
- `CONFIG_MODVERSIONS` 下 `same_magic()` **不比较 `-g<hash>` 这一段**，真正决定加载的是 **KMI（`6.6.89-android15-8`）+ 符号 CRC**。

两者的 KMI 完全一致，所以这套组合在原厂就是这么跑的，出厂即如此。

> 上一版报告把这条列为 P1 并建议「从同一份 OTA 重取料」，是误判。已修正 `check-vendor-fit.sh`：改为只比较 KMI，hash 后缀差异不再报阻断。

### 什么情况才真的会挂

只有在下面两种情形，模块才会 `invalid module format` / `disagrees about version of symbol`：

1. **KMI 不同**（例如 6.6.89-android15-**8** 的模块装进 android15-**11** 的内核）——自检脚本现在会直接报出来；
2. 用了**别的机型/别的版本**提取的模块，私有符号 CRC 对不上。

真遇到时的判据（拿到 adb 后一条命令）：

```bash
adb shell dmesg | grep -E "version magic|disagrees about|Unknown symbol"
```

---

## 五、P1-2：`package-vendor-boot.sh` 的拼接方式不符合 v4 语义

脚本 167-193 行：把 stock 平台 ramdisk 和 TWRP 的 recovery ramdisk **去掉 `TRAILER!!!` 后首尾相接**，gzip 成**一个** `vendor_ramdisk`。

问题：

1. vendor_boot v4 的正确结构是 `vendor_ramdisk_table` **多 fragment**（PLATFORM / RECOVERY / DLKM 三种 type）。合并成一个后 type 恒为 PLATFORM，bootloader 无法按 recovery 模式选取。
2. 两个 rootfs 路径冲突：平台 ramdisk 有 `bin`/`etc`/`d`/`cache`/`bugreports` 等**符号链接**，TWRP rootfs 里同名条目类型可能不同，cpio 线性解包"后写覆盖先写"，会把文件写进上一段的符号链接目标。
3. inode 号重复：两段 cpio 各自从 1 开始编号，硬链接关系全乱。
4. 平台 ramdisk 的 `/first_stage_ramdisk/` 残留。我解包确认：这个目录下只有 **35 个条目**，`first_stage_ramdisk/system/bin/` 里只有 `e2fsck / fsck.f2fs / resize2fs / linker64`，**没有 `init`**。first-stage init 一旦切 root 进去就是死路。

### 原厂 vendor_boot 的真实结构（OTA 实测）

把 OTA 的 `vendor_boot`（header v4）拆开后，片段表是这样的：

| # | type | size | 内容 |
|---|---|---|---|
| 0 | **RECOVERY** | 47,407,968 | 标准 AOSP recovery ramdisk，984 条目：`first_stage_ramdisk/fstab.mt6899`、`e2fsck`、`fsck.f2fs`、`linker64`、`system/` |
| 1 | **DLKM** | 53,414,800 | vivo 定制：`init.recovery.{mt6899,platform,svc,touch,wifi}.rc`、`first_stage_ramdisk/fstab.emmc` |

`vendor_ramdisk_size = 100,822,768`（两者之和），`dtb = 451,872 B`，`bootconfig = 65 B`。

**没有 PLATFORM fragment。** 这很关键：

- 你仓库 `recovery/root/` 里的 `init.recovery.mt6899.rc`、`init.recovery.touch.rc` 与这个 **DLKM 片段字节完全一致**——它们本来就是从原厂 DLKM 里提出来的；
- 也就是说这个树的素材是对的，问题只在**重新打包时怎么摆回去**。

### 正确做法

```bash
mkbootimg --vendor_boot out.img --header_version 4 \
  --vendor_ramdisk "$PLATFORM_RD" "$TWRP_RD" \
  --ramdisk_type platform recovery \
  --dtb prebuilt/dtb.img \
  --vendor_cmdline "$(从构建产物读回 + permissive)"
```

两个要点：

1. **第一个必须是 `platform`**（first-stage 靠它拿 `fstab.mt6899` 挂 `/data`）；
2. **其余必须是 `recovery`**。如果全打 `platform`，正常开机也会加载 TWRP 的 `/init`，直接顶掉 Android——这是刷 vendor_boot 类移植最容易翻车的地方。

脚本已按这个改（先探测 `mkbootimg` 是否支持 `--ramdisk_type`，不支持会显式告警而不是静默降级）。

---

## 六、P2：照抄 PD2183 但方向反了的其它项

| 配置 | PD2183（可用） | PD2551（卡住） | 说明 |
|---|---|---|---|
| `TARGET_ARCH_VARIANT` | `armv8-2a` | `armv8-a` | mt6899 是 armv9 |
| `TARGET_RECOVERY_PIXEL_FORMAT` | `RGBX_8888` | `BGRA_8888` | 颜色通道 |
| `BOARD_BOOTIMG_HEADER_VERSION` | 2 | 4 | 换了 GKI，但 v2 的 offset/base 全保留了 |
| `BOARD_INCLUDE_RECOVERY_DTBO` | true | — | v4 下无意义 |
| `BOARD_RAMDISK_USE_LZ4` | true | — | v4 由 header 决定 |

`BoardConfig.mk:64-71` 还给 v4 的 boot.img 传了 `--dtb`、`--second_offset`。v4 的 boot.img 不允许带 dtb，mkbootimg 会丢弃，别指望它生效。

A/B 与 recovery 语义也混用了：

```make
AB_OTA_UPDATER := true                            # A/B，没有 recovery 分区
TARGET_NO_RECOVERY := true                        # 声明没有
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 134217728   # 又定义了大小
BOARD_USES_RECOVERY_AS_BOOT :=                    # 空赋值 = 没写
BOARD_BOOTIMG_HEADER_VERSION := 4                 # 重复
BOARD_BOOT_HEADER_VERSION := 4                    # 只有这个被 board_config.mk 认
```

后三行建议删掉，只留 `BOARD_BOOT_HEADER_VERSION := 4`。

---

## 七、抓 log 的实际办法（按可行性排序）

> 前提：先修 P0-1 的 permissive，否则 ③④ 大概率都不通。

### ① 内核日志直接上屏（改一行就够）

vendor_cmdline 追加 `loglevel=8 ignore_loglevel`。

dtb 的 `chosen/bootargs` 里本来就有 `console=tty0`（我从 `prebuilt/dtb.img` 里读到了），加上 `ignore_loglevel` 后即使 UI 卡死，**最后几十行 kernel 日志也会滚在屏幕上**，拍照即可。

### ② pstore / ramoops（最可靠，不依赖 recovery 能起来）

卡死后强制重启，**回到 Android 用 root 读**：

```bash
su -c 'ls -l /sys/fs/pstore/'
su -c 'cat /sys/fs/pstore/console-ramoops-0' > /sdcard/kmsg.txt
su -c 'cat /sys/fs/pstore/dmesg-ramoops-0'  >> /sdcard/kmsg.txt
su -c 'cat /proc/last_kmsg'                  >> /sdcard/kmsg.txt   # 老 MTK 路径
```

重点搜 `version magic` / `disagrees about` / `avc: denied` / `init: cannot execve`。
这是最值得先做的：**它不需要 recovery 正常工作**，只要 pstore 没被下次启动覆盖。

### ③ adb（修完 P0-1 之后）

```bash
adb devices          # 期望出现 <serial>  recovery
adb shell dmesg | grep -E "version magic|disagrees|avc: denied"
adb pull /tmp/recovery.log
adb pull /sys/fs/pstore/console-ramoops-0
```

若 `adb devices` 仍空：临时删掉 `TW_EXCLUDE_DEFAULT_USB_INIT := true`，用 TWRP 自带的那份 usb rc 试试。当前两份 `init.recovery.usb.rc` 都只有 `on property:sys.usb.config=adb`，没有主动 `setprop sys.usb.config adb`，完全依赖 TWRP 主程序去设 —— UI 卡在内核态时它根本没机会执行。

### ④ fastboot 兜底

```bash
fastboot getvar all 2>&1 | tee getvar.txt    # 看 current-slot / 分区表 / unlocked
fastboot boot vendor_boot.img                # 交叉验证能否引导
```

---

## 八、修复步骤（按顺序做，别一次全改）

### 第 1 步：P0-2 一行（先排除黑屏假死）

```make
# BoardConfig.mk
# TW_SCREEN_BLANK_ON_BOOT := true
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
TARGET_ARCH_VARIANT := armv8-2a
TARGET_2ND_ARCH_VARIANT := armv8-2a
```

### 第 2 步：P0-1 cmdline（关键）

`BoardConfig.mk` 增加：

```make
BOARD_VENDOR_CMDLINE := $(BOARD_KERNEL_CMDLINE) loglevel=8 ignore_loglevel
```

`package-vendor-boot.sh` **不要硬编码**，从构建产物读回来再补：

```bash
VENDOR_CMDLINE="$(python3 "$UNPACK_BOOTIMG" --boot_img "$BUILT_IMG" --format=mkbootimg \
                 | sed -n 's/^ *--vendor_cmdline *//p' | head -1 | tr -d '"')"
case " $VENDOR_CMDLINE " in *" androidboot.selinux="*) ;; *) VENDOR_CMDLINE="$VENDOR_CMDLINE androidboot.selinux=permissive";; esac
case " $VENDOR_CMDLINE " in *" androidboot.hardware="*) ;; *) VENDOR_CMDLINE="$VENDOR_CMDLINE androidboot.hardware=mt6899";; esac
```

完整实现见 `package-vendor-boot-fixed.sh`。

### 第 3 步：确认模块 KMI（已用官方 OTA 验证通过）

```bash
bash check-vendor-fit.sh <设备树目录>
```

期望输出：

```
OK  KMI 一致: 6.6.89-android15-8
```

只有报 **KMI 不一致**（例如模块 `android15-8`、内核 `android15-11`）时才需要重取料：从同一份 OTA 的 `payload.bin` 同时取 `boot.img` 的 kernel 和 `vendor_dlkm.img` 的 `.ko`。当前这棵树已验证同源，**不用重取**。

### 第 4 步：换打包方式

用 `package-vendor-boot-fixed.sh` 替换原脚本（多 fragment + 读回 cmdline + 保留 vendor_bootconfig + AVB 带 key）。

### 第 5 步：清理 BoardConfig 矛盾项

删 `BOARD_RECOVERYIMAGE_PARTITION_SIZE`、空的 `BOARD_USES_RECOVERY_AS_BOOT`、`BOARD_BOOTIMG_HEADER_VERSION`（只留 `BOARD_BOOT_HEADER_VERSION`）。

---

## 九、验证顺序（避免又不知道是哪一步生效）

1. **只做第 1 步**（关 blank + 改 pixel format）→ 刷 → 若能看到 TWRP 界面，说明 P0-2 命中。
2. **只做第 2 步**（permissive）→ 刷 → `adb devices` 能连上就赢了一半；立刻 `dmesg | grep -E "version magic|disagrees"`。
3. 模块问题已排除（第四节），不要再花时间去重取 OTA。若触摸仍不工作，先看 `dmesg | grep -E "vivo_ts|avc: denied"`，是权限或供电问题，不是版本问题。
4. 最后再换打包方式（这一步是根治，不是急救）。

---

## 十、一句话总结

> 结构没大问题，坏在"链"：**重打包 vendor_boot 的脚本用一段手写 cmdline 覆盖掉了 `androidboot.selinux=permissive`**，系统 enforcing 起来，adbd/logd 全被拒，于是既进不去也抓不到 log。再加上 `TW_SCREEN_BLANK_ON_BOOT` 开着的黑屏假死。**模块同源问题已用官方 OTA 逐字节排除，不是原因，别再往那个方向查。**

---

### 附：本次分析已确认的实测数据

| 项 | 实测值 |
|---|---|
| kernel | `6.6.89-android15-8-gb57af212129c-abogki457297774-4k`，35 MB 未压缩 Image |
| 模块 | 124 个，vermagic 统一为 `6.6.89-android15-8-g131232aa79fe-4k` |
| `modules.load.recovery` | 122 条，引用缺失 0 个 |
| 平台 vendor_ramdisk | 35 条目，仅 `first_stage_ramdisk/{fstab.mt6899, system/bin/{e2fsck,fsck.f2fs,linker64,resize*}}`，**无 .ko、无 init** |
| dtb bootargs | `console=tty0 root=/dev/ram ... androidboot.hardware=mt6899 ...`，**无 selinux=permissive** |
| recovery.fstab / twrp.flags | 分区表完整，logical + slotselect 标注正确 |

### 附二：与官方全量 OTA 的交叉验证（2026-11-09）

OTA：`PD2551_A_16.0.15.3.W10`，zip 9,164,791,841 B，内含单个 `payload.bin` 9,159,941,848 B

| 项 | 实测 |
|---|---|
| payload 结构 | `CrAU` v2，manifest 27,144 B，39 个分区；数据区起点 = 61（zip local header）+ 27,435（header+manifest+sig） |
| operation 类型 | vivo 自定义 **`type=14 = ZSTD_REPLACE`**（zstd 帧 `28 b5 2f fd`），不是 AOSP 标准的 0/1/8 |
| `boot` | 3 ops，dst 96 MB，实下载 13.7 MB；解出 kernel 36,657,664 B |
| `vendor_dlkm` | EROFS（LZ4_0PADDING），解出 259 个 `.ko` |
| kernel SHA256 | `c20c2896…` **与仓库 `prebuilt/kernel` 完全一致** |
| 同名 `.ko` | 12/12 字节一致 |
| `boot.img` cmdline | **为空**（GKI 分离，cmdline 实际在 vendor_boot） |

> 提取方法：`payload` 的 `data_offset` 是相对 payload 文件起点，读取时需再加 zip local header 长度。用 HTTP Range 只取目标分区，全程下载约 27 MB，无需整包 9 GB。
