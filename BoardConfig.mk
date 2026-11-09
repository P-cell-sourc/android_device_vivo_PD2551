#
# Copyright (C) 2026 The Android Open Source Project
# Copyright (C) 2026 SebaUbuntu's TWRP device tree generator
#
# SPDX-License-Identifier: Apache-2.0
#

DEVICE_PATH := device/vivo/PD2551

# ==========================================================================
# 1. Build options
# ==========================================================================

# For building with minimal manifest
ALLOW_MISSING_DEPENDENCIES := true

# Ported from PD2183 tree: build workarounds
BUILD_BROKEN_DUP_RULES := true
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true

# ==========================================================================
# 2. Architecture
# ==========================================================================

TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-2a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 :=
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := cortex-a55

# Second arch (32-bit userspace needed by some vendor tools)
TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-2a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := generic
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a55

# ==========================================================================
# 3. Platform / Bootloader
# ==========================================================================

TARGET_BOARD_PLATFORM := mt6899
TARGET_NO_BOOTLOADER := true

# ==========================================================================
# 4. Kernel (prebuilt from official OTA payload)
# ==========================================================================

BOARD_BOOTIMG_HEADER_VERSION := 4
# Build-system variable (AOSP 14 board_config.mk derives BUILDING_VENDOR_BOOT_IMAGE from it)
BOARD_BOOT_HEADER_VERSION := 4
BOARD_KERNEL_BASE := 0x40000000
BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2 erofs.reserved_pages=256 product.version=PD2551_A_16.0.15.3.W10 fingerprint.abbr=15/AP3A.240905.015.A2 region_ver=W10 product.solution=MTK
BOARD_KERNEL_CMDLINE += androidboot.selinux=permissive
# GKI: vendor_boot 使用独立的 vendor_cmdline，必须显式继承，否则 permissive 不会生效
BOARD_VENDOR_CMDLINE := $(BOARD_KERNEL_CMDLINE) loglevel=8 ignore_loglevel
BOARD_KERNEL_PAGESIZE := 4096
BOARD_KERNEL_OFFSET := 0x00008000
BOARD_RAMDISK_OFFSET := 0x07c08000
BOARD_SECOND_OFFSET := 0x00e88000
BOARD_KERNEL_TAGS_OFFSET := 0x07808000
BOARD_DTB_OFFSET := 0x01f08000
# 单条 := 赋值 (CI check-boot-offsets.sh 只解析 :=/= 形式, 不解析 +=)
BOARD_MKBOOTIMG_ARGS := \
    --header_version 4 \
    --base 0x40000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x07c08000 \
    --second_offset 0x00e88000 \
    --tags_offset 0x07808000 \
    --dtb_offset 0x01f08000
BOARD_KERNEL_IMAGE_NAME := Image

TARGET_FORCE_PREBUILT_KERNEL := true
ifeq ($(TARGET_FORCE_PREBUILT_KERNEL),true)
TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/prebuilt/kernel
TARGET_PREBUILT_DTB := $(DEVICE_PATH)/prebuilt/dtb.img
BOARD_PREBUILT_DTBOIMAGE := $(DEVICE_PATH)/prebuilt/dtbo.img
BOARD_MKBOOTIMG_ARGS += --dtb $(TARGET_PREBUILT_DTB)
BOARD_INCLUDE_DTB_IN_BOOTIMG :=
endif

# GKI / vendor_boot (align PD2415 virtual A/B layout):
# recovery ramdisk is packed into vendor_boot, no standalone recovery.img.
TARGET_NO_RECOVERY := true
BOARD_USES_GENERIC_KERNEL_IMAGE := true
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true
BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE :=
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 134217728


# ==========================================================================
# 5. Partitions / Filesystem
# ==========================================================================

BOARD_FLASH_BLOCK_SIZE := 262144 # (BOARD_KERNEL_PAGESIZE * 64)
BOARD_BOOTIMAGE_PARTITION_SIZE := 134217728
BOARD_HAS_LARGE_FILESYSTEM := true
BOARD_SUPER_PARTITION_SIZE := 9126805504 # TODO: Fix hardcoded value
BOARD_SUPER_PARTITION_GROUPS := vivo_dynamic_partitions
BOARD_VIVO_DYNAMIC_PARTITIONS_PARTITION_LIST := system system system_ext system_ext vendor vendor product product odm odm vendor_dlkm vendor_dlkm odm_dlkm odm_dlkm system_dlkm system_dlkm cust vgc
BOARD_VIVO_DYNAMIC_PARTITIONS_SIZE := 9122611200 # TODO: Fix hardcoded value

# Filesystem: stock dynamic partitions are EROFS (matches official payload)
TARGET_COPY_OUT_VENDOR := vendor
TARGET_COPY_OUT_PRODUCT := product
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
TARGET_COPY_OUT_ODM := odm
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
TARGET_USERIMAGES_USE_EROFS := true
BOARD_SYSTEMIMAGE_PARTITION_TYPE := erofs
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_ODMIMAGE_FILE_SYSTEM_TYPE := erofs

# Suppress secure erase on data (ported from PD2183)
BOARD_SUPPRESS_SECURE_ERASE := true

# Metadata partition (required for FBE metadata decryption)
BOARD_USES_METADATA_PARTITION := true
BOARD_ROOT_EXTRA_FOLDERS += metadata

# ==========================================================================
# 6. AVB
# ==========================================================================

BOARD_AVB_ENABLE := true
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 0

# ==========================================================================
# 6b. OTA payload flashing (vivo / iQOO full OTA zip, payload.bin sideload)
# ==========================================================================

# Device assertion checked against ro.product.device / ro.product.name when
# an OTA zip with META-INF assertions is flashed (prevents cross-device
# flash). NOTE: upstream PD2183 tree spells this TARGET_OTA_ASSERT_DEVICEE
# (typo, no-op) — this is the correct variable.
TARGET_OTA_ASSERT_DEVICE := PD2551,V2551A,iQOO

# Flashing a full OTA payload (payload.bin) is handled by update_engine_sideload,
# which is already included in device.mk together with update_engine /
# update_verifier / otapreopt_script / cppreopts.sh, and the boot-control HAL
# (bootctrl.mt6899) used for slot switching during payload apply.
# --flags 0 in the AVB section above keeps vbmeta verification disabled so
# payload-flashed partitions boot with verification off.

# ==========================================================================
# 7. A/B
# ==========================================================================

AB_OTA_UPDATER := true
AB_OTA_PARTITIONS += \
    vbmeta_vendor \
    vendor_boot \
    init_boot \
    system_ext \
    system \
    odm_dlkm \
    vendor \
    vendor_dlkm \
    system_dlkm \
    odm \
    product \
    boot \
    vbmeta_system

# ==========================================================================
# 8. Display / Recovery UI
# ==========================================================================

TARGET_SCREEN_DENSITY := 560
TARGET_USES_VULKAN := true
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888

# APEX
DEXPREOPT_GENERATE_APEX_IMAGE := true

# ==========================================================================
# 9. TWRP Configuration
# ==========================================================================

TW_THEME := portrait_hdpi
TW_EXTRA_LANGUAGES := true
TW_DEFAULT_LANGUAGE := zh_CN
# TW_SCREEN_BLANK_ON_BOOT := true   # 新 panel 上关屏后写回亮度常失效，表现为卡 logo
TW_INPUT_BLACKLIST := "hbtp_vm"
TW_USE_TOOLBOX := true
TW_DEVICE_VERSION := vivo V2551A-OS6-PD2551

# UI / utilities
TW_INCLUDE_FASTBOOTD := true
TW_INCLUDE_REPACKTOOLS := true
TW_INCLUDE_RESETPROP := true
TW_INCLUDE_LIBRESETPROP := true
TW_INCLUDE_LPDUMP := true
TW_INCLUDE_LPTOOLS := true
TW_INCLUDE_FB2PNG := true
TARGET_USES_MKE2FS := true
TWRP_INCLUDE_LOGCAT := true
TARGET_USES_LOGD := true

# Storage / MTP
TW_HAS_MTP := true
RECOVERY_SDCARD_ON_DATA := true
TW_EXCLUDE_TWRPAPP := true
TW_INCLUDE_NTFS_3G := true
TW_INCLUDE_FUSE_EXFAT := true
TW_INCLUDE_FUSE_NTFS := true
TW_EXCLUDE_DEFAULT_USB_INIT := true

# Haptics / brightness / misc UI
TW_SUPPORT_INPUT_AIDL_HAPTICS := true
TW_BRIGHTNESS_PATH := "/sys/class/leds/lcd-backlight/brightness"
TW_MAX_BRIGHTNESS := 2047
TW_CUSTOM_CPU_TEMP_PATH := /sys/class/power_supply/battery/temp
TW_STATUS_ICONS_ALIGN := center
TW_CUSTOM_CLOCK_POS := 610
TW_NO_FASTBOOT_BOOT := true

TARGET_SYSTEM_PROP += $(DEVICE_PATH)/system.prop

# 注意：recovery 模块统一放在 recovery/root/lib/modules/，由 recovery rootfs 整体打包，
# 不要再通过 BOARD_VENDOR_RAMDISK_KERNEL_MODULES 注册，否则会在 ramdisk 里出现两份，
# 且第二份的 modules.load 会覆盖 modules.load.recovery。
# 若改用 AOSP 原生方式，则把上面目录里的 .ko 挪到 prebuilt/ 并启用：
# BOARD_VENDOR_RAMDISK_KERNEL_MODULES := $(wildcard $(DEVICE_PATH)/prebuilt/recovery_modules/*.ko)
# BOARD_VENDOR_RAMDISK_KERNEL_MODULES_LOAD := $(DEVICE_PATH)/prebuilt/recovery_modules/essential_modules.txt

# --- Data decryption (single source of truth; do not duplicate in device.mk) ---

# APEX support is mandatory to decrypt data on Android 13+ (API 36)
TW_EXCLUDE_APEX := false
TW_INCLUDE_CRYPTO := true
TW_INCLUDE_CRYPTO_FBE := true
TW_INCLUDE_FBE4 := true
# Ported from PD2183 (vivo X80) TWRP: FBE metadata decryption support
TW_INCLUDE_FBE_METADATA_DECRYPT := true
TW_PREPARE_DATA_MEDIA_EARLY := true

# ==========================================================================
# 10. Anti-rollback override (single definition)
# ==========================================================================

PLATFORM_SECURITY_PATCH := 2099-12-31
VENDOR_SECURITY_PATCH := 2099-12-31
PLATFORM_VERSION := 16.1.0
