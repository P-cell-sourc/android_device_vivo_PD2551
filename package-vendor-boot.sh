#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# package-vendor-boot.sh — vivo iQOO PD2551 (V2551A, MT6899)
# 组装最终可刷的 vendor_boot 镜像:
#   平台 vendor_ramdisk 片段 (取自官方 OTA, 预置在 prebuilt/) + OrangeFox 构建
#   产出的 recovery vendor_ramdisk 片段 + DTB, 用 mkbootimg 重打 vendor_boot v4,
#   最后追加 AVB hash footer。
#
# 用法: package-vendor-boot.sh <ORANGEFOX_TOP> <output_image>
#   $1 = OrangeFox 源码树根目录
#   $2 = 最终镜像输出路径
#
# 被 OrangeFox CI 的 "Package vendor_boot image" 步骤调用; 也被
# check-boot-offsets.sh 读取 PARTITION_SIZE 做尺寸一致性校验。

# CI 用 `sh` 调起本脚本 (dash), dash 不支持 pipefail/bash 扩展;
# 若不在 bash 下运行则自动重_exec 为 bash。
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

# vendor_boot 分区大小, 必须与 BoardConfig 的 BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE 一致
PARTITION_SIZE=134217728

# 与 BoardConfig --base 一致
BASE=$((0x40000000))
RAMDISK_OFFSET=$((0x26f00000))   # 官方 vendor_boot ramdisk_addr 0x66f00000 - base
DTB_OFFSET=$((0x01f08000))
VENDOR_CMDLINE="bootopt=64S3,32N2,64N2 erofs.reserved_pages=256 product.version=PD2551_A_16.0.15.3.W10 fingerprint.abbr=15/AP3A.240905.015.A2 region_ver=W10 product.solution=MTK"

MKBOOTIMG_DIR="$TOP/system/tools/mkbootimg"
MKBOOTIMG="$MKBOOTIMG_DIR/mkbootimg.py"
UNPACK_BOOTIMG="$MKBOOTIMG_DIR/unpack_bootimg.py"

for f in "$BUILT_IMG" "$PLATFORM_ZST" "$DTB" "$MKBOOTIMG" "$UNPACK_BOOTIMG"; do
  if [[ ! -f "$f" ]]; then
    echo "package-vendor-boot: 缺少 $f" >&2
    exit 1
  fi
done

WORK="$(mktemp -d "$(dirname "$OUT")/pvboot.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------- 工具定位 ----------
find_avbtool() {
  local c
  for c in "$TOP/out/soong/host/linux-x86/bin/avbtool" \
           "$TOP/out/host/linux-x86/bin/avbtool" \
           "$TOP/prebuilts/hostpack/linux/x86_64/bin/avbtool" \
           "$(command -v avbtool || true)"; do
    if [[ -n "$c" && -e "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

run_avbtool() {
  local tool
  if tool="$(find_avbtool)"; then
    if head -c 2 "$tool" | grep -q '#!'; then
      python3 "$tool" "$@"
    else
      "$tool" "$@"
    fi
  elif [[ -f "$DEV_DIR/prebuilt/avbtool.py" ]]; then
    python3 "$DEV_DIR/prebuilt/avbtool.py" "$@"
  else
    return 1
  fi
}

# ---------- 解压 vendor_ramdisk 片段 (按魔数识别压缩格式) ----------
decompress_ramdisk() {
  local src="$1" dst="$2" magic
  magic="$(od -An -tx1 -N4 "$src" | tr -d ' \n')"
  case "$magic" in
    1f8b*)      gzip -dc "$src" > "$dst" ;;
    02214c18)   # lz4 legacy (vivo 官方 vendor_boot 用这个)
      if command -v lz4 >/dev/null 2>&1; then
        lz4 -dc "$src" > "$dst"
      else
        python3 - "$src" "$dst" <<'PYEOF'
import sys
# 纯 python LZ4 legacy 解压 (无外部依赖)
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
out = bytearray()
i = 0
while i < len(data):
    token = data[i]; i += 1
    lit = token >> 4
    if lit == 15:
        while True:
            b = data[i]; i += 1
            lit += b
            if b != 255:
                break
    out += data[i:i + lit]
    i += lit
    if i >= len(data):
        break
    off = (data[i] << 8) | data[i + 1]; i += 2
    mlen = (token & 0xf) + 4
    if mlen == 19:
        while True:
            b = data[i]; i += 1
            mlen += b
            if b != 255:
                break
    for _ in range(mlen):
        out.append(out[-off])
open(dst, 'wb').write(bytes(out))
PYEOF
      fi ;;
    04224d18)   # lz4 frame
      if command -v lz4 >/dev/null 2>&1; then
        lz4 -dc "$src" > "$dst"
      else
        echo "package-vendor-boot: 需要 lz4 解压 frame 格式但系统无 lz4" >&2
        exit 1
      fi ;;
    28b52ffd)   zstd -dc "$src" > "$dst" ;;
    070701)     cp "$src" "$dst" ;;  # 已经是 cpio
    *)
      echo "package-vendor-boot: 未知 ramdisk 魔数 $magic ($src)" >&2
      exit 1 ;;
  esac
}

echo "package-vendor-boot: 解压平台 ramdisk 片段"
zstd -dc "$PLATFORM_ZST" > "$WORK/platform.cpio"

echo "package-vendor-boot: 解压 OrangeFox 构建的 vendor_boot ($BUILT_IMG)"
python3 "$UNPACK_BOOTIMG" --boot_img "$BUILT_IMG" --out "$WORK/built"

shopt -s nullglob
recovery_blobs=("$WORK/built"/vendor_ramdisk*)
shopt -u nullglob
if [[ "${#recovery_blobs[@]}" -eq 0 ]]; then
  echo "package-vendor-boot: 构建产物中没有 vendor_ramdisk 片段" >&2
  exit 1
fi

echo "package-vendor-boot: 解压 ${#recovery_blobs[@]} 个 recovery 片段"
i=0
for blob in "${recovery_blobs[@]}"; do
  i=$((i + 1))
  decompress_ramdisk "$blob" "$WORK/rec_$i.cpio"
done

echo "package-vendor-boot: 合并 平台 + recovery 片段 (TRAILER 只保留最后一个)"
python3 - "$WORK" <<'PYEOF'
import glob, sys

w = sys.argv[1]

def strip_trailer(p):
    data = open(p, 'rb').read()
    i = data.rfind(b'TRAILER!!!')
    if i < 0:
        return data
    # 'TRAILER!!!' 位于 newc 记录的 name 字段 (记录头 110 字节的偏移 6),
    # 整条 TRAILER 记录从 i-6 开始, 一并去掉
    return data[:i - 6]

parts = [strip_trailer(w + '/platform.cpio')]
recs = sorted(glob.glob(w + '/rec_*.cpio'),
              key=lambda p: int(p.rsplit('_', 1)[1].split('.')[0]))
for p in recs[:-1]:
    parts.append(strip_trailer(p))
if recs:
    parts.append(open(recs[-1], 'rb').read())  # 最后一段保留 TRAILER
open(w + '/final.cpio', 'wb').write(b''.join(parts))
print('merge: platform %d B + %d recovery 段' % (len(parts[0]), len(recs)))
PYEOF

gzip -9 -c "$WORK/final.cpio" > "$WORK/vendor_ramdisk.cpio.gz"
echo "package-vendor-boot: 合并后 ramdisk $(du -h "$WORK/vendor_ramdisk.cpio.gz" | cut -f1)"

echo "package-vendor-boot: mkbootimg 重打 vendor_boot v4"
python3 "$MKBOOTIMG" \
  --vendor_boot "$WORK/vendor_boot.img" \
  --header_version 4 \
  --pagesize 4096 \
  --vendor_ramdisk "$WORK/vendor_ramdisk.cpio.gz" \
  --dtb "$DTB" \
  --vendor_cmdline "$VENDOR_CMDLINE" \
  --base 0x40000000 \
  --ramdisk_offset "$(printf '0x%08x' "$RAMDISK_OFFSET")" \
  --dtb_offset "$(printf '0x%08x' "$DTB_OFFSET")"

echo "package-vendor-boot: 追加 AVB hash footer (partition_size=$PARTITION_SIZE)"
if run_avbtool add_hash_footer \
      --image "$WORK/vendor_boot.img" \
      --partition_size "$PARTITION_SIZE" \
      --partition_name vendor_boot \
      --hash_algorithm sha256; then
  echo "package-vendor-boot: AVB footer 已写入"
else
  echo "::warning::未找到 avbtool, 跳过 AVB footer (解锁 Bootloader 下不影响启动)" >&2
fi

mkdir -p "$(dirname "$OUT")"
mv "$WORK/vendor_boot.img" "$OUT"
echo "package-vendor-boot: 完成 -> $OUT ($(du -h "$OUT" | cut -f1))"
