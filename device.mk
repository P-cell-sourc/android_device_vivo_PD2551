#
# Copyright (C) 2026 The Android Open Source Project
# Copyright (C) 2026 SebaUbuntu's TWRP device tree generator
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH := device/vivo/PD2551

# Dynamic partitions (ported from PD2183 tree)
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# Soong
PRODUCT_SOONG_NAMESPACES += \
    $(LOCAL_PATH)
# A/B
AB_OTA_POSTINSTALL_CONFIG += \
    RUN_POSTINSTALL_system=true \
    POSTINSTALL_PATH_system=system/bin/otapreopt_script \
    FILESYSTEM_TYPE_system=ext4 \
    POSTINSTALL_OPTIONAL_system=true

# Boot control HAL
PRODUCT_PACKAGES += \
    android.hardware.boot@1.0-impl \
    android.hardware.boot@1.0-service

PRODUCT_PACKAGES += \
    bootctrl.mt6899

PRODUCT_PACKAGES += \
    otapreopt_script \
    cppreopts.sh \
    update_engine \
    update_verifier \
    update_engine_sideload

# Fastbootd (ported from PD2183 tree)
PRODUCT_PACKAGES += \
    android.hardware.fastboot@1.1-impl-mock \
    fastbootd

# Health HAL (recovery, ported from PD2183 tree)
PRODUCT_PACKAGES += \
    android.hardware.health@2.1-impl \
    android.hardware.health@2.1-service

# NOTE: all TWRP/crypto build flags (TW_INCLUDE_CRYPTO*, TW_INCLUDE_FBE*,
# TW_EXCLUDE_APEX, security-patch anti-rollback overrides, etc.) live in
# BoardConfig.mk only — do not duplicate them here.
