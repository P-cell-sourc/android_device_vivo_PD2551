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

```
#
# Copyright (C) 2026 The Android Open Source Project
# Copyright (C) 2026 SebaUbuntu's TWRP device tree generator
#
# SPDX-License-Identifier: Apache-2.0
#
```
