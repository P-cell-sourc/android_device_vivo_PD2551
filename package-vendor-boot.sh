#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# package-vendor-boot.sh  —  修复版 (v2: 自带 v4 打包器)
# vivo iQOO PD2551 (V2551A, MT6899 / GKI 6.6, vendor_boot header v4)
#
# 关键点:
#   1. vendor_cmdline 从构建产物的 header 里读回来(不依赖 unpack_bootimg),
#      再补 androidboot.selinux=permissive 等。原版硬编码覆盖掉了 permissive,
#      这是"卡住且抓不到 log"的根因。
#   2. 不再调用树里的 system/tools/mkbootimg/mkbootimg.py。
#      实测 OrangeFox 树里那份是旧版: --vendor_ramdisk 只收一个参数,
#      也没有 --ramdisk_type, 传多片段会直接
#          ValueError: Unrecognized arguments: [... '--ramdisk_type', 'platform', 'recovery']
#      本脚本改用自带 vendor_boot_v4.py 直接按 bootimg.h 写 v4 镜像,
#      已用原厂 vendor_boot.img 做克隆重打验证: 前 101,285,953 字节逐字节一致。
#   3. fragment type 显式写为 platform + recovery, 避免 normal boot 加载 TWRP 的 /init。
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
PACKER="$DEV_DIR/vendor_boot_v4.py"

# 必须与 BoardConfig 的 BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE 一致
PARTITION_SIZE=134217728

# 兜底 cmdline (仅在构建产物 header 里读不到时使用)
FALLBACK_CMDLINE="bootopt=64S3,32N2,64N2 erofs.reserved_pages=256 product.version=PD2551_A_16.0.17.1.W10 fingerprint.abbr=15/AP3A.240905.015.A2 region_ver=W10 product.solution=MTK"

# 原厂 vendor_boot 基底 (混合模式, 强烈推荐):
#   TWRP 构建产物里只有 recovery 片段, 直接刷会丢掉原厂 DLKM 片段
#   (含 first_stage_ramdisk/fstab.emmc), 导致 normal boot 找不到 fstab
#   -> logo 后无限重启。混合模式 = 原厂 vendor_boot 为基底, 只把 RECOVERY
#   片段换成 TWRP ramdisk, DLKM 原样保留, normal boot / recovery 两不误。
#   获取方式: bash fetch_stock_vendor_boot.sh <官方OTA.zip>  (生成 prebuilt/stock_vendor_boot.img)
STOCK_VENDOR_BOOT="$DEV_DIR/prebuilt/stock_vendor_boot.img"

for f in "$BUILT_IMG" "$PACKER"; do
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

# ---------- 1. 平台 ramdisk (默认不注入) ----------
# 实测: prebuilt/vendor_ramdisk_platform.cpio.zst 解包后是 675 个条目、60MB,
# 里面含 /init、init.recovery.*.rc、recovery_resources(TWRP 字体/开机动画),
# 也就是说它是一份 recovery ramdisk, 而不是 first-stage 平台片段。
# 把它当成 PLATFORM 类型塞进 vendor_boot, normal boot 也会解出这棵 rootfs,
# 既浪费 26MB 分区空间, 也可能让系统起不来。
# 原厂 PD2551 的 vendor_boot 本来就只有 RECOVERY + DLKM, 没有 PLATFORM,
# 所以默认保持原厂结构: 只用构建产物自带的片段。
# 需要试验时: PVB_ADD_PLATFORM=1 再跑。
PLATFORM_FRAG=""
if [ "${PVB_ADD_PLATFORM:-0}" = "1" ] && [ -f "$PLATFORM_ZST" ]; then
  echo "package-vendor-boot: PVB_ADD_PLATFORM=1, 注入平台片段"
  case "$(od -An -tx1 -N4 "$PLATFORM_ZST" | tr -d ' \n')" in
    28b52ffd)
      if command -v zstd >/dev/null 2>&1; then
        zstd -dc "$PLATFORM_ZST" > "$WORK/platform.cpio"
      elif python3 -c 'import zstandard' 2>/dev/null; then
        python3 - "$PLATFORM_ZST" "$WORK/platform.cpio" <<'PYEOF'
import sys, zstandard
src, dst = sys.argv[1], sys.argv[2]
d = zstandard.ZstdDecompressor()
with open(src, 'rb') as fi, open(dst, 'wb') as fo:
    d.copy_stream(fi, fo)
PYEOF
      else
        echo "package-vendor-boot: 缺少 zstd 且无 python zstandard, 无法解压平台 ramdisk" >&2
        exit 1
      fi ;;
    *) cp "$PLATFORM_ZST" "$WORK/platform.cpio" ;;
  esac
  # 统一转成 gzip: 内核对各段 ramdisk 的解压支持里 gzip 最稳
  gzip -9 -c "$WORK/platform.cpio" > "$WORK/frag_platform.cpio.gz"
  PLATFORM_FRAG="$WORK/frag_platform.cpio.gz"
  echo "package-vendor-boot: 平台片段 $(du -h "$PLATFORM_FRAG" | cut -f1)"
else
  echo "package-vendor-boot: 不注入平台片段 (保持原厂 RECOVERY 结构)"
fi

# ---------- 2. 读构建产物基本信息 ----------
echo "package-vendor-boot: 解析构建产物 $BUILT_IMG"
python3 "$PACKER" dump --src "$BUILT_IMG" | sed 's/^/    /'

SRC_CMDLINE="$(python3 "$PACKER" dump --src "$BUILT_IMG" | sed -n 's/^cmdline *: //p' | head -1)"
CMD_ARGS=()
if [ -z "${SRC_CMDLINE// /}" ] || [ "${SRC_CMDLINE}" = "<空>" ]; then
  echo "package-vendor-boot: ::warning:: 构建产物 header 里没有 vendor_cmdline, 使用兜底值"
  CMD_ARGS=(--cmdline "$FALLBACK_CMDLINE")
else
  echo "package-vendor-boot: 原 vendor_cmdline = $SRC_CMDLINE"
  CMD_ARGS=(--cmdline "$SRC_CMDLINE")
fi

SRC_DTB_SIZE="$(python3 "$PACKER" dump --src "$BUILT_IMG" | sed -n 's/^dtb_size *: *\([0-9]*\).*/\1/p' | head -1)"
if [ "${SRC_DTB_SIZE:-0}" -gt 0 ]; then
  echo "package-vendor-boot: 沿用构建产物自带 dtb (${SRC_DTB_SIZE}B)"
  DTB_ARGS=()
elif [ -f "$DTB" ]; then
  echo "package-vendor-boot: 构建产物无 dtb, 补入 $DTB"
  DTB_ARGS=(--dtb "$DTB")
else
  echo "package-vendor-boot: ::warning:: 构建产物无 dtb 且缺少 $DTB" >&2
  DTB_ARGS=()
fi

# ---------- 3. 重打 v4 (自带打包器, 不依赖树内 mkbootimg) ----------
if [ -f "$STOCK_VENDOR_BOOT" ]; then
  # ===== 混合模式 (根治 normal boot 无限重启) =====
  echo "package-vendor-boot: 混合模式, 基底 = $STOCK_VENDOR_BOOT"
  # 从 TWRP 构建产物里提取 recovery ramdisk。
  # 不能用 vb.ramdisk (那是 vendor_ramdisk 主区 = platform 片段): 若设备树
  # 没设 BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT=true, 主区只有 20 字节
  # 空 gzip, 直接注入会得到一个"没有 rootfs"的镜像 -> init panic -> 无限重启。
  # 这里改为取**最大的片段**(优先 recovery 类型), 并做尺寸硬校验。
  python3 - "$DEV_DIR" "$BUILT_IMG" "$WORK/twrp_ramdisk.cpio.gz" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from vendor_boot_v4 import VendorBoot, TYPE_NAMES
vb = VendorBoot(open(sys.argv[2], 'rb').read())
cands = [(e['size'], i, e) for i, e in enumerate(vb.entries)]
if not cands:
    data, desc = vb.ramdisk, 'vendor_ramdisk 主区'
else:
    cands.sort(key=lambda t: (t[2]['type'] == 1, t[0]))  # recovery(type=1) 优先, 再比大小
    size, idx, e = cands[-1]
    data = vb.frag_bytes(idx)
    desc = 'fragment[%d] type=%s name=%r' % (idx, TYPE_NAMES.get(e['type'], e['type']), e['name'])
open(sys.argv[3], 'wb').write(data)
sys.stderr.write('TWRP ramdisk 来源: %s, %d bytes\n' % (desc, len(data)))
PYEOF
  TWRP_RD_SIZE=$(stat -c %s "$WORK/twrp_ramdisk.cpio.gz")
  echo "package-vendor-boot: TWRP ramdisk = ${TWRP_RD_SIZE}B"
  if [ "$TWRP_RD_SIZE" -lt 4194304 ]; then
    echo "package-vendor-boot: ::error:: TWRP ramdisk 只有 ${TWRP_RD_SIZE}B (正常应 >40MB)" >&2
    echo "    说明构建产物 vendor_boot 里没有真正的 recovery ramdisk。" >&2
    echo "    检查 BoardConfig.mk 是否有: BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true" >&2
    echo "    以及构建日志里有没有 'mkbootfs: cannot open directory ... vendor_ramdisk'。" >&2
    echo "    拒绝产出会无限重启的镜像。" >&2
    exit 1
  fi
  PACK_ARGS=(
    --src "$STOCK_VENDOR_BOOT"
    --out "$WORK/vendor_boot.img"
    --platform "$WORK/twrp_ramdisk.cpio.gz"
    --platform-type recovery
    --drop-type recovery
    --retag-recovery
    --add-cmdline "androidboot.selinux=permissive androidboot.hardware=mt6899 loglevel=8 ignore_loglevel"
    "${CMD_ARGS[@]}"
  )
else
  # ===== 无原厂基底: 产出会丢掉 DLKM 片段, normal boot 必挂 =====
  echo "package-vendor-boot: ::error:: 缺少 $STOCK_VENDOR_BOOT" >&2
  echo "    没有原厂基底就不可能有 DLKM 片段(normal boot 的 fstab 来源)," >&2
  echo "    刷入分区后 100% 无限重启。仅 fastboot boot 临时引导可用。" >&2
  echo "    先执行: bash fetch_stock_vendor_boot.sh <官方OTA.zip>" >&2
  echo "    确需产出仅临时引导的镜像: PVB_ALLOW_NO_STOCK=1" >&2
  if [ "${PVB_ALLOW_NO_STOCK:-0}" != "1" ]; then
    exit 1
  fi
  echo "package-vendor-boot: PVB_ALLOW_NO_STOCK=1, 继续产出 (禁止刷入分区)"
  PACK_ARGS=(
    --src "$BUILT_IMG"
    --out "$WORK/vendor_boot.img"
    --add-cmdline "androidboot.selinux=permissive androidboot.hardware=mt6899 loglevel=8 ignore_loglevel"
    --retag-recovery
    "${CMD_ARGS[@]}"
  )
fi
if [ -n "$PLATFORM_FRAG" ]; then
  PACK_ARGS+=(--platform "$PLATFORM_FRAG" --platform-if-missing)
fi
if [ ${#DTB_ARGS[@]} -gt 0 ]; then
  PACK_ARGS+=("${DTB_ARGS[@]}")
fi

python3 "$PACKER" repack "${PACK_ARGS[@]}"

# ---------- 4. 自检 ----------
SZ=$(stat -c %s "$WORK/vendor_boot.img")
if [ "$SZ" -gt "$PARTITION_SIZE" ]; then
  echo "package-vendor-boot: 镜像 ${SZ}B 超过分区 ${PARTITION_SIZE}B" >&2
  exit 1
fi
echo "package-vendor-boot: 镜像 ${SZ}B / 分区 ${PARTITION_SIZE}B (余量 $((PARTITION_SIZE - SZ))B)"

# 回读校验: fragment 类型必须带 platform + recovery
python3 "$PACKER" dump --src "$WORK/vendor_boot.img" | sed 's/^/    /'
if ! python3 "$PACKER" dump --src "$WORK/vendor_boot.img" | grep -q 'recovery'; then
  echo "package-vendor-boot: ::error:: 重打后的镜像里没有 recovery 片段" >&2
  exit 1
fi
# 混合模式下必须保留原厂 dlkm 片段 (normal boot 的 fstab 来源), 否则会无限重启
if [ -f "$STOCK_VENDOR_BOOT" ] && ! python3 "$PACKER" dump --src "$WORK/vendor_boot.img" | grep -q 'dlkm'; then
  echo "package-vendor-boot: ::error:: 混合模式下丢失了 dlkm 片段, normal boot 将无法启动!" >&2
  exit 1
fi
# recovery 片段必须有实际内容 (空 ramdisk = 刷入后 init 找不到 /init -> 无限重启)
python3 - "$DEV_DIR" "$WORK/vendor_boot.img" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from vendor_boot_v4 import VendorBoot
vb = VendorBoot(open(sys.argv[2], 'rb').read())
rec = [e for e in vb.entries if e['type'] == 1]
rec_sz = max([e['size'] for e in rec], default=vb.vendor_ramdisk_size)
print('package-vendor-boot: recovery 片段实际大小 = %d bytes' % rec_sz)
if rec_sz < 4194304:
    sys.exit('package-vendor-boot: ::error:: recovery 片段只有 %d 字节, 是空 ramdisk, 拒绝产出' % rec_sz)
PYEOF

# ---------- 5. AVB ----------
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
