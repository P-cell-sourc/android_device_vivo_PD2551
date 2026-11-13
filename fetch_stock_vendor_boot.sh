#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# fetch_stock_vendor_boot.sh — 从官方全量 OTA 中提取原厂 vendor_boot
# 生成 prebuilt/stock_vendor_boot.img, 供 package-vendor-boot.sh 混合模式使用。
#
# 用法: bash fetch_stock_vendor_boot.sh <官方OTA.zip>   (如 PD2551_A_16.0.17.1.W10.zip)
# 依赖: python3 + zstandard (pip install zstandard), unzip, openssl
#
# 签名校验开关 (默认全开):
#   VERIFY_PAYLOAD_SIG=0   关闭全部签名校验 (仅建议对自己改过的 OTA 使用)
#   PVB_PIN_CERT=<hex>     覆盖 OTA zip 签名证书指纹 (默认钉 vivo otacert,
#                          sha256: 973e2e8c...ca23958)
#   PVB_PIN_KEY=<hex>      钉死 payload 签名公钥指纹 (vivo payload 不内嵌公钥,
#                          拿到其 payload signer 公钥后可启用完整验签)
#   PVB_SIG_STRICT=1       payload 签名无可用公钥完成验签时按失败处理
#                          (默认仅结构校验即放行, 因为拿不到 vivo payload signer 公钥)
#
# 原理: vivo OTA 的 payload.bin 用自定义 ZSTD_REPLACE (按 32MB 分块) 压缩,
#       通用 payload_dumper 会截断镜像; 本脚本按 manifest 的 dst_extents 逐 op 重组。

set -euo pipefail

OTA_ZIP="${1:?用法: fetch_stock_vendor_boot.sh <官方OTA.zip>}"
DEV_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 -c 'import zstandard' 2>/dev/null || { echo "缺少 python zstandard: pip install zstandard" >&2; exit 1; }

echo "[1/6] 解出 payload.bin ..."
unzip -o -q "$OTA_ZIP" payload.bin -d "$WORK"

# ---- 签名校验开关 ----
# VERIFY_PAYLOAD_SIG=1 (默认) : 校验 zip 签名链 + payload 签名结构
# VERIFY_PAYLOAD_SIG=0        : 全部跳过 (只建议对自己改过的 OTA 使用)
# PVB_PIN_CERT=<sha256hex>    : 钉死 OTA zip 签名证书指纹 (默认钉 vivo otacert)
# PVB_SIG_STRICT=1            : payload 签名无法密码学验证时也算失败
if [ "${VERIFY_PAYLOAD_SIG:-1}" = "1" ]; then
  DEFAULT_CERT_FP="973e2e8ca844249ea94cda3015397547cdf41924b1fdec1690b3ee907ca23958"
  PIN_CERT_ARGS=()
  if [ "${PVB_PIN_CERT:-default}" = "default" ]; then
    PIN_CERT_ARGS=(--pin-cert "$DEFAULT_CERT_FP")
  elif [ -n "${PVB_PIN_CERT:-}" ]; then
    PIN_CERT_ARGS=(--pin-cert "$PVB_PIN_CERT")
  fi

  echo "[2/6] OTA zip 签名链校验 (CERT.RSA -> CERT.SF -> MANIFEST.MF -> payload.bin) ..."
  python3 "$DEV_DIR/verify_ota_zip.py" "$OTA_ZIP" "${PIN_CERT_ARGS[@]}"

  echo "[3/6] payload 签名校验 ..."
  SIG_ARGS=()
  [ -n "${PVB_PIN_KEY:-}" ] && SIG_ARGS+=(--pin-key "$PVB_PIN_KEY")
  [ "${PVB_SIG_STRICT:-0}" = "1" ] && SIG_ARGS+=(--strict)
  python3 "$DEV_DIR/verify_payload.py" "$WORK/payload.bin" --skip-payload-sig "${SIG_ARGS[@]}"
else
  echo "[2/6] 跳过 OTA zip 签名链校验 (VERIFY_PAYLOAD_SIG=0)"
  echo "[3/6] 跳过 payload 签名校验 (VERIFY_PAYLOAD_SIG=0)"
fi

echo "[4/6] 解析 manifest (按 dst_extents 重组 vivo ZSTD_REPLACE) ..."
# 自包含 proto 解析 (不依赖 payload_dumper):
#   DeltaArchiveManifest.partitions = 13 (repeated PartitionUpdate)
#   PartitionUpdate: partition_name=1, new_partition_info=7(PartitionInfo{size=1}),
#                    operations=8
#   InstallOperation: type=1, data_offset=2, data_length=3, dst_extents=6(Extent),
#                     dst_length=7
#   Extent: start_block=1, num_blocks=2
python3 - "$WORK/payload.bin" "$WORK/vendor_boot.img" <<'PYEOF'
import sys, struct
import zstandard as zstd

payload, outpath = sys.argv[1], sys.argv[2]

def rv(b, i):
    v = s = 0
    while True:
        c = b[i]; i += 1; v |= (c & 0x7F) << s
        if not c & 0x80:
            return v, i
        s += 7

def walk(b):
    i = 0
    while i < len(b):
        tag, i = rv(b, i); fno, wt = tag >> 3, tag & 7
        if wt == 0:
            v, i = rv(b, i); yield fno, v
        elif wt == 2:
            ln, i = rv(b, i); yield fno, b[i:i + ln]; i += ln
        elif wt == 5:
            yield fno, b[i:i + 4]; i += 4
        elif wt == 1:
            yield fno, b[i:i + 8]; i += 8
        else:
            raise ValueError('wiretype %d' % wt)

with open(payload, 'rb') as f:
    hdr = f.read(24)
    if hdr[:4] != b'CrAU':
        sys.exit('不是 OTA payload')
    manifest_len, = struct.unpack('>Q', hdr[12:20])
    sig_size, = struct.unpack('>I', hdr[20:24])
    manifest = f.read(manifest_len)
BASE = 24 + manifest_len + sig_size

part = None
for fno, val in walk(manifest):
    if fno != 13:
        continue
    name = ops = size = None
    for f2, v2 in walk(val):
        if f2 == 1:
            name = v2.decode()
        elif f2 == 7:
            for f3, v3 in walk(v2):
                if f3 == 1:
                    size = v3
        elif f2 == 8:
            op = {'doff': 0, 'dlen': 0, 'exts': []}
            for f3, v3 in walk(v2):
                if f3 == 2:
                    op['doff'] = v3
                elif f3 == 3:
                    op['dlen'] = v3
                elif f3 == 6:
                    e = {'s': 0, 'n': 0}
                    for f4, v4 in walk(v3):
                        if f4 == 1:
                            e['s'] = v4
                        elif f4 == 2:
                            e['n'] = v4
                    op['exts'].append(e)
            ops = (ops or []) + [op]
    if name == 'vendor_boot':
        part = (size, ops)
        break
if not part:
    sys.exit('manifest 里没有 vendor_boot 分区')
size, ops = part
BLOCK = 4096

buf = bytearray()
with open(payload, 'rb') as f:
    for i, op in enumerate(ops):
        if op['exts']:
            dst_off = op['exts'][0]['s'] * BLOCK
            length = sum(e['n'] for e in op['exts']) * BLOCK
        else:
            dst_off, length = len(buf), op['dlen']
        if dst_off + length > len(buf):
            buf.extend(b'\x00' * (dst_off + length - len(buf)))
        if op['dlen'] == 0:
            continue
        f.seek(BASE + op['doff'])
        data = f.read(op['dlen'])
        if data[:4] == b'\x28\xb5\x2f\xfd':
            do = zstd.ZstdDecompressor().decompressobj()
            raw = do.decompress(data)
            while do.unused_data[:4] == b'\x28\xb5\x2f\xfd':
                do = zstd.ZstdDecompressor().decompressobj()
                raw += do.decompress(do.unused_data)
        else:
            raw = data
        buf[dst_off:dst_off + len(raw)] = raw
if len(buf) < size:
    buf.extend(b'\x00' * (size - len(buf)))
buf = buf[:size]
assert buf[:8] == b'VNDRBOOT', 'vendor_boot magic 校验失败'
open(outpath, 'wb').write(buf)
print(f'vendor_boot: {len(buf)} bytes, magic OK')
PYEOF

echo "[5/6] 结构自检 (应有 recovery + dlkm 双片段) ..."
python3 "$DEV_DIR/vendor_boot_v4.py" dump --src "$WORK/vendor_boot.img" | sed 's/^/    /'
if ! python3 "$DEV_DIR/vendor_boot_v4.py" dump --src "$WORK/vendor_boot.img" | grep -q dlkm; then
  echo "错误: 提取的 vendor_boot 没有 dlkm 片段, OTA 可能不匹配" >&2
  exit 1
fi

echo "[6/6] 写入 $DEV_DIR/prebuilt/stock_vendor_boot.img"
mkdir -p "$DEV_DIR/prebuilt"
mv "$WORK/vendor_boot.img" "$DEV_DIR/prebuilt/stock_vendor_boot.img"
echo "完成: bash package-vendor-boot.sh <构建TOP> <输出> 现在会自动使用混合模式"
