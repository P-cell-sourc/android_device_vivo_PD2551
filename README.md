# Android device tree for vivo V2551A (PD2551)

Detected Android API level: 36 (Android )
This device ships with Android 13 or newer: the TWRP build **must** include APEX and FBE crypto support (already enabled in this tree).

## How to build

1. Sync the TWRP sources (use the `twrp-16.1` branch for Android 15/16 devices, `twrp-12.1` otherwise):

```
repo init -u https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp -b twrp-16.1
repo sync
```

2. Add this tree to `device/vivo/PD2551`, then:

```
source build/envsetup.sh
lunch twrp_PD2551-eng
mka recoveryimage -j$(nproc)
```

> Note: this device uses boot image header v4 (GKI).
> The generated recovery ramdisk is packed into `vendor_boot`; flash the
> built `vendor_boot.img` (or use fastboot boot).
>
> **IMPORTANT (normal-boot bootloop fix):** TWRP 构建产物只有 recovery 片段，
> 直接刷入分区会丢掉原厂 DLKM 片段（fstab.emmc 等），normal boot 会无限重启。
> 构建后请先运行 `bash fetch_stock_vendor_boot.sh <官方OTA.zip>` 生成
> `prebuilt/stock_vendor_boot.img`，package-vendor-boot.sh 会自动切换到
> 混合模式（原厂 DLKM 保留 + TWRP 替换 RECOVERY 片段），刷分区/临时引导均安全。
>
> **IMPORTANT (empty vendor ramdisk fix):** 必须保留
> `BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true`。缺这一行时构建系统
> 会去 mkbootfs 一个从不存在的 `out/target/product/PD2551/vendor_ramdisk` 目录：
> `mkbootfs: cannot open directory ... No such file or directory`，结果 vendor_boot
> 里的 ramdisk 只有 20 字节（空 gzip），整镜像仅约 456KB。刷入后内核能起，但
> init 找不到 `/init` → panic → 无限重启，连 OrangeFox 界面都进不去（Run 19 即此问题）。

```
#
# Copyright (C) 2026 The Android Open Source Project
# Copyright (C) 2026 SebaUbuntu's TWRP device tree generator
#
# SPDX-License-Identifier: Apache-2.0
#
```
