#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# package-vendor-boot.sh  —  修复版
# vivo iQOO PD2551 (V2551A, MT6899 / GKI 6.6, vendor_boot header v4)
#
# 相对原版的三个关键修改:
#   1. vendor_cmdline 不再硬编码, 而是从 build 产出的 vendor_boot.img 里读回来,
#      再补上 androidboot.selinux=permissive / loglevel=8。
#      —— 原版硬编码把 BoardConfig 里的 permissive 覆盖掉了, 这是"抓不到 log"的根因。
#   2. 不再用 python 把多段 cpio 二进制拼接成一个大 ramdisk, 而是交给 mkbootimg
#      生成正确的 vendor_ramdisk_table (多 fragment), 避免文件/inode 冲突。
#   3. 保留 build 产物里的 vendor_bootconfig (若有), 否则会丢失 androidboot.* 参数。
#
# 用法: package-vendor-boot.sh <ORANGEFOX_TOP> <output_image>

if [ -z "$BASH_VERSION" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

TOP="${1:?usage: package-vendor-boot.sh <ORANGEFOX_TOP> <output_image>}"
OUT="${2:?usage: package-vendor-boot.sh <ORANGEFOX_TOP> <output_image>}"

DEVICE="PD2551"
DEV_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT="$TOP/out/target/product/$DEVICE"
BUILT_IMG="$PRODUCT/vendor_boot.img"
PLATFORM_ZST="$DEV_DIR/prebuilt/vendor_ramdisk_platform.cpio.zst"
DTB="$DEV_DIR/prebuilt/dtb.img"

# 必须与 BoardConfig 的 BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE 一致
PARTITION_SIZE=134217728

BASE=$((0x40000000))
RAMDISK_OFFSET=$((0x26f00000))
DTB_OFFSET=$((0x01f08000))

# 兜底 cmdline (仅在无法从构建产物读取时使用)
FALLBACK_CMDLINE="bootopt=64S3,32N2,64N2 erofs.reserved_pages=256 product.version=PD2551_A_16.0.15.3.W10 fingerprint.abbr=15/AP3A.240905.015.A2 region_ver=W10 product.solution=MTK androidboot.selinux=permissive"

MKBOOTIMG_DIR="$TOP/system/tools/mkbootimg"
MKBOOTIMG="$MKBOOTIMG_DIR/mkbootimg.py"
UNPACK_BOOTIMG="$MKBOOTIMG_DIR/unpack_bootimg.py"

for f in "$BUILT_IMG" "$PLATFORM_ZST" "$DTB" "$MKBOOTIMG" "$UNPACK_BOOTIMG"; do
  [ -f "$f" ] || { echo "package-vendor-boot: 缺少 $f" >&2; exit 1; }
done

WORK="$(mktemp -d "$(dirname "$OUT")/pvboot.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

find_avbtool() {
  local c
  for c in "$TOP/out/soong/host/linux-x86/bin/avbtool" \
           "$TOP/out/host/linux-x86/bin/avbtool" \
           "$TOP/prebuilts/hostpack/linux/x86_64/bin/avbtool" \
           "$(command -v avbtool || true)"; do
    [ -n "${c:-}" ] && [ -e "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

run_avbtool() {
  local tool
  if tool="$(find_avbtool)"; then
    if head -c 2 "$tool" | grep -q '#!'; then python3 "$tool" "$@"; else "$tool" "$@"; fi
  elif [ -f "$DEV_DIR/prebuilt/avbtool.py" ]; then
    python3 "$DEV_DIR/prebuilt/avbtool.py" "$@"
  else
    return 1
  fi
}

decompress_ramdisk() {
  local src="$1" dst="$2" magic
  magic="$(od -An -tx1 -N4 "$src" | tr -d ' \n')"
  case "$magic" in
    1f8b*)      gzip -dc "$src" > "$dst" ;;
    04224d18)   lz4  -dc "$src" > "$dst" ;;
    28b52ffd)   zstd -dc "$src" > "$dst" ;;
    070701*)    cp "$src" "$dst" ;;
    02214c18)   # lz4 legacy
      if command -v lz4 >/dev/null 2>&1; then
        lz4 -dc "$src" > "$dst"
      else
        python3 - "$src" "$dst" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
out = bytearray(); i = 0
while i < len(data):
    token = data[i]; i += 1
    lit = token >> 4
    if lit == 15:
        while True:
            b = data[i]; i += 1
            lit += b
            if b != 255: break
    out += data[i:i + lit]; i += lit
    if i >= len(data): break
    off = (data[i] << 8) | data[i + 1]; i += 2
    mlen = (token & 0xf) + 4
    if mlen == 19:
        while True:
            b = data[i]; i += 1
            mlen += b
            if b != 255: break
    for _ in range(mlen):
        out.append(out[-off])
open(dst, 'wb').write(bytes(out))
PYEOF
      fi ;;
    *) echo "package-vendor-boot: 未知 ramdisk 魔数 $magic ($src)" >&2; exit 1 ;;
  esac
}

# ---------- 1. 平台 ramdisk (stock first-stage, 必须排第一) ----------
echo "package-vendor-boot: 解压平台 ramdisk"
zstd -dc "$PLATFORM_ZST" > "$WORK/platform.cpio"
# /first_stage_ramdisk 必须保留: first-stage init 依赖它做 system-as-root 切换。
# 但 recovery 模式下 force_normal_boot=0, init 不会切进去。
gzip -9 -c "$WORK/platform.cpio" > "$WORK/frag_00_platform.cpio.gz"

# ---------- 2. 解 build 产物 ----------
echo "package-vendor-boot: 解包构建产物 $BUILT_IMG"
python3 "$UNPACK_BOOTIMG" --boot_img "$BUILT_IMG" --out "$WORK/built" >/dev/null

shopt -s nullglob
BLOS=("$WORK"/built/vendor_ramdisk*)
shopt -u nullglob
[ ${#BLOS[@]} -gt 0 ] || { echo "package-vendor-boot: 构建产物里没有 vendor_ramdisk" >&2; exit 1; }

# 按文件名排序保证顺序稳定
IFS=$'\n' SORTED=($(printf '%s\n' "${BLOS[@]}" | sort)); unset IFS

idx=1
FRAGS=("$WORK/frag_00_platform.cpio.gz")
for blob in "${SORTED[@]}"; do
  [ -f "$blob" ] || continue
  cpio_f="$WORK/rec_$idx.cpio"
  decompress_ramdisk "$blob" "$cpio_f"
  gzip -9 -c "$cpio_f" > "$WORK/frag_$(printf '%02d' $idx)_recovery.cpio.gz"
  FRAGS+=("$WORK/frag_$(printf '%02d' $idx)_recovery.cpio.gz")
  idx=$((idx + 1))
done
echo "package-vendor-boot: 共 ${#FRAGS[@]} 个 fragment (1 platform + $((idx-1)) recovery)"

# ---------- 3. 读回 vendor_cmdline ----------
VENDOR_CMDLINE="$(python3 "$UNPACK_BOOTIMG" --boot_img "$BUILT_IMG" --format=mkbootimg 2>/dev/null \
                  | sed -n 's/^ *--vendor_cmdline *//p' | head -1 | sed 's/^"//; s/"$//')"
if [ -z "${VENDOR_CMDLINE// /}" ]; then
  echo "package-vendor-boot: ::warning:: 读不到 vendor_cmdline, 使用兜底值"
  VENDOR_CMDLINE="$FALLBACK_CMDLINE"
fi

case " $VENDOR_CMDLINE " in
  *" androidboot.selinux="*) ;;
  *) VENDOR_CMDLINE="$VENDOR_CMDLINE androidboot.selinux=permissive" ;;
esac
case " $VENDOR_CMDLINE " in
  *" androidboot.hardware="*) ;;
  *) VENDOR_CMDLINE="$VENDOR_CMDLINE androidboot.hardware=mt6899" ;;
esac
case " $VENDOR_CMDLINE " in
  *" loglevel="*) ;;
  *) VENDOR_CMDLINE="$VENDOR_CMDLINE loglevel=8 ignore_loglevel" ;;
esac
echo "package-vendor-boot: vendor_cmdline = $VENDOR_CMDLINE"

BOOTCONFIG_ARGS=()
if [ -f "$WORK/built/vendor_bootconfig" ] && [ -s "$WORK/built/vendor_bootconfig" ]; then
  echo "package-vendor-boot: 保留 vendor_bootconfig"
  BOOTCONFIG_ARGS=(--vendor_bootconfig "$WORK/built/vendor_bootconfig")
fi

# ---------- 4. mkbootimg ----------
echo "package-vendor-boot: 重打 vendor_boot v4"
python3 "$MKBOOTIMG" \
  --vendor_boot "$WORK/vendor_boot.img" \
  --header_version 4 \
  --pagesize 4096 \
  --vendor_ramdisk "${FRAGS[@]}" \
  --dtb "$DTB" \
  --vendor_cmdline "$VENDOR_CMDLINE" \
  --base 0x40000000 \
  --ramdisk_offset "$(printf '0x%08x' "$RAMDISK_OFFSET")" \
  --dtb_offset "$(printf '0x%08x' "$DTB_OFFSET")" \
  "${BOOTCONFIG_ARGS[@]+"${BOOTCONFIG_ARGS[@]}"}"

# ---------- 5. 自检 ----------
SZ=$(stat -c %s "$WORK/vendor_boot.img")
if [ "$SZ" -gt "$PARTITION_SIZE" ]; then
  echo "package-vendor-boot: 镜像 ${SZ}B 超过分区 ${PARTITION_SIZE}B" >&2
  exit 1
fi
echo "package-vendor-boot: 镜像 ${SZ}B / 分区 ${PARTITION_SIZE}B"

# ---------- 6. AVB ----------
echo "package-vendor-boot: 追加 AVB hash footer"
AVB_KEY="$TOP/external/avb/test/data/testkey_rsa2048.pem"
if [ -f "$AVB_KEY" ] && run_avbtool add_hash_footer \
      --image "$WORK/vendor_boot.img" \
      --partition_size "$PARTITION_SIZE" \
      --partition_name vendor_boot \
      --algorithm SHA256_RSA2048 \
      --key "$AVB_KEY"; then
  echo "package-vendor-boot: AVB footer 已写入 (SHA256_RSA2048)"
elif run_avbtool add_hash_footer \
      --image "$WORK/vendor_boot.img" \
      --partition_size "$PARTITION_SIZE" \
      --partition_name vendor_boot \
      --hash_algorithm sha256; then
  echo "package-vendor-boot: AVB footer 已写入 (无签名)"
else
  echo "::warning::未找到 avbtool, 跳过 AVB footer, 补齐到分区大小" >&2
  truncate -s "$PARTITION_SIZE" "$WORK/vendor_boot.img" 2>/dev/null || true
fi

mkdir -p "$(dirname "$OUT")"
mv "$WORK/vendor_boot.img" "$OUT"
echo "package-vendor-boot: 完成 -> $OUT ($(du -h "$OUT" | cut -f1))"
