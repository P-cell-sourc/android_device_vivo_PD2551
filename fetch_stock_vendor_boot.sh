#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# fetch_stock_vendor_boot.sh — 从官方全量 OTA 中提取原厂 vendor_boot
# 生成 prebuilt/stock_vendor_boot.img, 供 package-vendor-boot.sh 混合模式使用。
#
# 用法: bash fetch_stock_vendor_boot.sh <官方OTA.zip>   (如 PD2551_A_16.0.17.1.W10.zip)
# 依赖: python3 + zstandard (pip install zstandard), unzip
#
# 原理: vivo OTA 的 payload.bin 用自定义 ZSTD_REPLACE (按 32MB 分块) 压缩,
#       通用 payload_dumper 会截断镜像; 本脚本按 manifest 的 dst_extents 逐 op 重组。

set -euo pipefail

OTA_ZIP="${1:?用法: fetch_stock_vendor_boot.sh <官方OTA.zip>}"
DEV_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 -c 'import zstandard' 2>/dev/null || { echo "缺少 python zstandard: pip install zstandard" >&2; exit 1; }

echo "[1/4] 解出 payload.bin ..."
unzip -o -q "$OTA_ZIP" payload.bin -d "$WORK"

echo "[2/4] 解析 manifest (按 dst_extents 重组 vivo ZSTD_REPLACE) ..."
python3 - "$WORK/payload.bin" "$WORK/vendor_boot.img" <<'PYEOF'
import sys, struct, os
sys.path.insert(0, '/usr/local/lib/python3.12/dist-packages')
try:
    from payload_dumper import update_metadata_pb2 as pb
except ImportError:
    sys.exit('缺少 payload_dumper: pip install payload_dumper')
import zstandard as zstd

payload, outpath = sys.argv[1], sys.argv[2]
with open(payload, 'rb') as f:
    hdr = f.read(24)
ver, manifest_len = struct.unpack('>QQ', hdr[4:20])
sig_size, = struct.unpack('>I', hdr[20:24])
with open(payload, 'rb') as f:
    f.seek(24)
    m = pb.DeltaArchiveManifest.FromString(f.read(manifest_len))
BASE = 24 + manifest_len + sig_size
BLOCK = m.block_size if m.block_size else 4096

part = next(p for p in m.partitions if p.partition_name == 'vendor_boot')
size = part.new_partition_info.size
buf = bytearray()
with open(payload, 'rb') as f:
    for i, op in enumerate(part.operations):
        if op.dst_extents:
            dst_off = op.dst_extents[0].start_block * BLOCK
            length = sum(e.num_blocks for e in op.dst_extents) * BLOCK
        else:
            dst_off, length = len(buf), op.dst_length
        if dst_off + length > len(buf):
            buf.extend(b'\x00' * (dst_off + length - len(buf)))
        if op.data_length == 0:
            continue
        f.seek(BASE + op.data_offset)
        data = f.read(op.data_length)
        if data[:4] == b'\x28\xb5\x2f\xfd':
            do = zstd.ZstdDecompressor().decompressobj()
            raw = do.decompress(data)
            while do.unused_data[:4] == b'\x28\xb5\x2f\xfd':
                do = zstd.ZstdDecompressor().decompressobj()
                raw += do.decompress(do.unused_data)
        else:
            raw = data
        buf[dst_off:dst_off+len(raw)] = raw
if len(buf) < size:
    buf.extend(b'\x00' * (size - len(buf)))
buf = buf[:size]
assert buf[:8] == b'VNDRBOOT', 'vendor_boot magic 校验失败'
open(outpath, 'wb').write(buf)
print(f'vendor_boot: {len(buf)} bytes, magic OK')
PYEOF

echo "[3/4] 结构自检 (应有 recovery + dlkm 双片段) ..."
python3 "$DEV_DIR/vendor_boot_v4.py" dump --src "$WORK/vendor_boot.img" | sed 's/^/    /'
if ! python3 "$DEV_DIR/vendor_boot_v4.py" dump --src "$WORK/vendor_boot.img" | grep -q dlkm; then
  echo "错误: 提取的 vendor_boot 没有 dlkm 片段, OTA 可能不匹配" >&2
  exit 1
fi

echo "[4/4] 写入 $DEV_DIR/prebuilt/stock_vendor_boot.img"
mkdir -p "$DEV_DIR/prebuilt"
mv "$WORK/vendor_boot.img" "$DEV_DIR/prebuilt/stock_vendor_boot.img"
echo "完成: bash package-vendor-boot.sh <构建TOP> <输出> 现在会自动使用混合模式"
