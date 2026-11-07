#
# Copyright (C) 2026 The Android Open Source Project
# Copyright (C) 2026 SebaUbuntu's TWRP device tree generator
#
# SPDX-License-Identifier: Apache-2.0
#

# Inherit from those products. Most specific first.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Inherit some common Omni stuff.
$(call inherit-product, vendor/omni/config/common.mk)

# Inherit from PD2551 device
$(call inherit-product, device/vivo/PD2551/device.mk)

PRODUCT_DEVICE := PD2551
PRODUCT_NAME := omni_PD2551
PRODUCT_BRAND := vivo
PRODUCT_MODEL := V2551A
PRODUCT_MANUFACTURER := vivo

PRODUCT_GMS_CLIENTID_BASE := android-vivo

PRODUCT_BUILD_PROP_OVERRIDES += \
    PRIVATE_BUILD_DESC="sys_mssi_64_64only_cn_armv82-user 16 BP2A.250605.031.A3 compiler260714204008 release-keys"

BUILD_FINGERPRINT := vivo/PD2551/PD2551:16/BP2A.250605.031.A3/compiler260714204008:user/release-keys
