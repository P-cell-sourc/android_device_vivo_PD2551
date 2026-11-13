# PD2551 OrangeFox 构建镜像"无限重启、进不去橙狐"诊断报告

- 时间：2026-11-13
- 镜像来源：RO_Twrp Actions Run #19（2026-11-12 15:32，success）
  产物 `PD2551-vendor-boot.img` sha256 `d3b0f191...e80664`
- 现象：刷入后无限重启，OrangeFox 界面完全不出现（已回退 A 槽官方 recovery）

## 结论（一句话）

**构建出的 vendor_boot 里 recovery ramdisk 是空的（20 字节 / 空 gzip），整个镜像实际内容只有 456KB。**
内核能起来，但 init 找不到 `/init`，直接 panic 重启 —— 不是显示问题、不是内核问题、不是 dtb 问题。

## 证据链

### 1. 产物结构（实测解析）

```
header_version : 4
dtb_size       : 451872  (正确)
vendor_ramdisk : 20      (at 0x1000)   <-- 应为 ~47MB
bootconfig     : 0 bytes                <-- 原厂为 65 bytes
fragments      : 1
  [0] recovery  size=20  name='recovery'
```

`vendor_ramdisk` 处 20 字节的内容是 `1f8b0800...0300` —— 一个 **空 gzip 流**（压缩了 0 字节）。

AVB footer 里 `original_image_size = 0x72000 (466944)`，即整镜像有效内容仅 **456KB**，
其余 127.5MB 全是填充。bootloader 校验能过（hash footer 与内容一致），但镜像里没有任何 rootfs。

### 2. 构建日志里的直接原因

```
[99%] build .../obj/PACKAGING/vendor_boot_intermediates/vendor_ramdisk.cpio.gz
mkbootfs: cannot open directory '.../out/target/product/PD2551/vendor_ramdisk': No such file or directory
RAMDISK_SZ      [20]
VND_RAMDISK     name=[] type=[platform] size=[20] fmt=[gzip]
```

同时 FOX_VENDOR_CMD 变量里可以看到：

```
BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT=      <-- 空，这就是根因
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT=true
```

### 3. 为什么这会导致空 ramdisk

build/make 的两条分支（core/Makefile）：

| 配置 | 行为 |
|---|---|
| `BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true` | 把 `TARGET_RECOVERY_ROOT_OUT` 打成**独立的 recovery 片段**（`--vendor_ramdisk_fragment ... --ramdisk_type RECOVERY`），与原厂 `[recovery][dlkm]` 结构一致 |
| 未设置（当前情况） | 只打包 `TARGET_VENDOR_RAMDISK_OUT`；该目录在本设备树里**从未被创建**（没有任何模块安装到 vendor ramdisk），mkbootfs 直接失败并输出空 gzip，recovery 资源根本没进镜像 |

也就是说：**recovery/root 里的 TWRP 全部内容（约 47MB）从头到尾没有被打进 vendor_boot**。
之前 `package-vendor-boot.sh` 又正好取 `vb.ramdisk`（= 这个 20 字节的空 platform 片段）作为
TWRP ramdisk 注入，于是"空 ramdisk"被原样搬进最终镜像，还附带了合法的 AVB footer ——
看起来像正常镜像，刷进去必然无限重启。

## 修复

### 1. `BoardConfig.mk`

```make
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true
BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true   # 新增，必须
```

`board_config.mk` 会校验：该开关要求 header v4 + MOVE_RECOVERY_RESOURCES 为 true（均满足）。

### 2. `package-vendor-boot.sh`（防止再产出砖头）

- ramdisk 来源改为**取最大的片段（recovery 类型优先）**，不再盲取 `vb.ramdisk`
- 新增硬校验：ramdisk < 4MB 直接失败，并打印检查项
  `TWRP ramdisk 只有 20B (正常应 >40MB) ... 拒绝产出会无限重启的镜像`
- 最终镜像再校验一次 recovery 片段实际大小（< 4MB 判失败）
- 缺少 `prebuilt/stock_vendor_boot.img` 时由 warning 改为 **error**（否则必丢 DLKM 片段），
  仅 `PVB_ALLOW_NO_STOCK=1` 可产出仅供 `fastboot boot` 的镜像

### 3. 验证（本地端到端）

模拟"修好之后"的构建产物（platform 空 + recovery 47MB）：

```
TWRP ramdisk 来源: fragment[1] type=recovery, 47402581 bytes
repack: 2 fragments, 101281857 bytes
  [0] recovery  size=47402581
  [1] dlkm      size=53415190
bootconfig : 65 bytes (保留)
镜像 101281857B / 分区 134217728B (余量 32935871B)
AVB footer 已写入
```

用 Run #19 的真实坏镜像回放：

```
TWRP ramdisk = 20B
::error:: TWRP ramdisk 只有 20B (正常应 >40MB)
退出码 = 1   (拒绝产出)
```

## 复现/验证步骤（下次构建）

1. 重新触发 CI（构建目标 `vendorbootimage`）
2. 构建日志里应**不再出现** `mkbootfs: cannot open directory`，且出现
   `--vendor_ramdisk_fragment ... recovery`
3. 产物自检：

```bash
python3 vendor_boot_v4.py dump --src PD2551-vendor-boot.img
# fragments 里 recovery 片段应 ≈ 47MB，vendor_ramdisk 应 ≈ 100MB
```

4. 首次验证一律用 `fastboot boot PD2551-vendor-boot.img`（不写分区），
   确认能进 OrangeFox 后再 `fastboot flash vendor_boot`。
