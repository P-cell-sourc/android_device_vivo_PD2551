#
# Copyright (C) 2026 The Android Open Source Project
# Copyright (C) 2026 SebaUbuntu's TWRP device tree generator
#
# SPDX-License-Identifier: Apache-2.0
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/omni_PD2551.mk \
    $(LOCAL_DIR)/twrp_PD2551.mk

COMMON_LUNCH_CHOICES := \
    omni_PD2551-user \
    omni_PD2551-userdebug \
    omni_PD2551-eng \
    twrp_PD2551-user \
    twrp_PD2551-userdebug \
    twrp_PD2551-eng
