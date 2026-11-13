#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# verify_payload.py — OTA payload.bin 内部签名校验 (自包含, 只依赖 openssl CLI)
#
# 校验内容:
#   1) metadata 签名: 头部 metadata_signature 块 (Signatures), 覆盖整个 manifest
#   2) payload  签名: manifest.signatures_offset 处的 Signatures 块,
#                     覆盖 payload 去掉签名块后的全部字节 (流式, 9GB 也不爆内存)
#
# 公钥解析顺序: 签名块自带 public_key > --pubkey > prebuilt/ota_public_key.pem
# 都没有时只做结构校验 (vivo payload 不内嵌公钥, 属正常情况);
# --strict 模式下没有可用公钥也算失败。
#
# 用法:
#   python3 verify_payload.py payload.bin
#   python3 verify_payload.py payload.bin --skip-payload-sig   # 快速模式, 只验 metadata
#   python3 verify_payload.py payload.bin --pubkey key.pem --pin-key <sha256hex>
#   python3 verify_payload.py payload.bin --allow-unsigned     # 无签名时跳过
#
# 退出码: 0=通过  1=校验失败  2=未签名且未 --allow-unsigned

import argparse
import hashlib
import os
import struct
import subprocess
import sys
import tempfile


def read_varint(b, i):
    v = s = 0
    while True:
        c = b[i]
        i += 1
        v |= (c & 0x7F) << s
        if not c & 0x80:
            return v, i
        s += 7


def parse_signatures(blob):
    """Signatures{repeated Signature signatures=1|2{version=1,data=2,public_key=3}}
    vivo 的 payload 用 field 1, AOSP 标准是 field 2, 两者都接受。"""
    sigs = []
    i = 0
    while i < len(blob):
        tag, i = read_varint(blob, i)
        fno, wt = tag >> 3, tag & 7
        if wt == 2 and fno in (1, 2):
            ln, i = read_varint(blob, i)
            sub = blob[i:i + ln]
            i += ln
            version, data, pub = 1, b'', b''
            j = 0
            while j < len(sub):
                t2, j = read_varint(sub, j)
                f2, w2 = t2 >> 3, t2 & 7
                if w2 == 0:
                    val, j = read_varint(sub, j)
                    if f2 == 1:
                        version = val
                elif w2 == 2:
                    l2, j = read_varint(sub, j)
                    v2 = sub[j:j + l2]
                    j += l2
                    if f2 == 2:
                        data = v2
                    elif f2 == 3:
                        pub = v2
                elif w2 in (5, 1):        # fixed32/fixed64, 容错跳过
                    j += 4 if w2 == 5 else 8
                else:
                    raise ValueError('Signature 里出现不支持的 wiretype %d' % w2)
            sigs.append({'version': version, 'data': data, 'pub': pub})
        elif wt == 0:
            _, i = read_varint(blob, i)
        elif wt == 2:
            ln, i = read_varint(blob, i)
            i += ln
        elif wt == 5:
            i += 4
        elif wt == 1:
            i += 8
        else:
            raise ValueError('Signatures 里出现不支持的 wiretype %d' % wt)
    return sigs


def parse_manifest_scalars(manifest):
    """只取 block_size(3) / signatures_offset(4) / signatures_size(5)"""
    out = {'block_size': 4096, 'signatures_offset': None, 'signatures_size': None}
    i = 0
    while i < len(manifest):
        tag, i = read_varint(manifest, i)
        fno, wt = tag >> 3, tag & 7
        if wt == 0:
            v, i = read_varint(manifest, i)
            if fno == 3:
                out['block_size'] = v
            elif fno == 4:
                out['signatures_offset'] = v
            elif fno == 5:
                out['signatures_size'] = v
        elif wt == 2:
            ln, i = read_varint(manifest, i)
            i += ln
        elif wt == 5:
            i += 4
        elif wt == 1:
            i += 8
        else:
            raise ValueError('manifest 里出现不支持的 wiretype %d' % wt)
    return out


def key_summary(pub_der):
    fp = hashlib.sha256(pub_der).hexdigest()
    try:
        with tempfile.NamedTemporaryFile(suffix='.der', delete=False) as tf:
            tf.write(pub_der)
            path = tf.name
        txt = subprocess.run(
            ['openssl', 'pkey', '-pubin', '-inform', 'DER', '-in', path,
             '-text', '-noout'], capture_output=True, text=True).stdout
        os.unlink(path)
        kind = ' / '.join(l.strip() for l in txt.splitlines()
                          if 'Public-Key' in l or 'NIST CURVE' in l)
    except Exception:
        kind = ''
    return fp, kind


def openssl_verify(pub_der, sig, stream_chunks):
    """流式验签, 返回命中的哈希名或 None; stream_chunks 为可调用(返回迭代器)或迭代器"""
    ok = None
    with tempfile.TemporaryDirectory() as td:
        pub = os.path.join(td, 'pub.der')
        sg = os.path.join(td, 'sig.bin')
        open(pub, 'wb').write(pub_der)
        open(sg, 'wb').write(sig)
        for h in ('sha256', 'sha384', 'sha512'):
            # 输出走临时文件, 避免大流量下 pipe 死锁
            fo = open(os.path.join(td, 'out.txt'), 'w')
            fe = open(os.path.join(td, 'err.txt'), 'w')
            p = subprocess.Popen(
                ['openssl', 'dgst', '-' + h, '-verify', pub, '-signature', sg],
                stdin=subprocess.PIPE, stdout=fo, stderr=fe)
            try:
                chunks = stream_chunks() if callable(stream_chunks) else stream_chunks
                for chunk in chunks:
                    p.stdin.write(chunk)
                p.stdin.close()
            except (BrokenPipeError, ValueError, OSError):
                # openssl 验签失败会提前关闭 stdin
                try:
                    p.stdin.close()
                except Exception:
                    pass
            p.wait()
            fo.close()
            fe.close()
            if p.returncode == 0:
                ok = h
                break
    return ok


def file_prefix_chunks(path, length, chunk=4 << 20):
    with open(path, 'rb') as f:
        left = length
        while left > 0:
            data = f.read(min(chunk, left))
            if not data:
                break
            left -= len(data)
            yield data


def mem_chunks(data, chunk=4 << 20):
    for i in range(0, len(data), chunk):
        yield data[i:i + chunk]


def verify_with_key(name, sig_entry, stream_chunks, pin, pubkey_der, key_src):
    version, data, pub = sig_entry['version'], sig_entry['data'], sig_entry['pub']
    if pub:
        pubkey_der = pub
        fp, desc = key_summary(pub)
        print(f'  [{name}] version={version} 内嵌公钥: {desc}')
    else:
        fp, _ = key_summary(pubkey_der)
        print(f'  [{name}] version={version} 外部公钥 ({key_src})')
    print(f'  [{name}] 公钥指纹 sha256(SPKI)={fp}')
    if pin and fp != pin:
        print(f'  [{name}] 公钥指纹与 --pin-key 不匹配 (期望 {pin}) -> 失败')
        return False
    h = openssl_verify(pubkey_der, data, stream_chunks)
    if h:
        print(f'  [{name}] 验签通过 (openssl dgst -{h})')
        return True
    print(f'  [{name}] 验签失败: sha256/sha384/sha512 均不匹配')
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('payload')
    ap.add_argument('--pubkey', help='外部公钥 (PEM/DER/SPKI), 用于签名块不内嵌公钥时')
    ap.add_argument('--pin-key', help='期望公钥指纹 sha256(SPKI) hex, 可选')
    ap.add_argument('--allow-unsigned', action='store_true',
                    help='完全无签名块时跳过而非失败 (退出码 0)')
    ap.add_argument('--skip-payload-sig', action='store_true',
                    help='跳过 payload 本体签名 (大文件快速检查)')
    ap.add_argument('--strict', action='store_true',
                    help='无可用公钥完成密码学验签时也算失败')
    args = ap.parse_args()

    with open(args.payload, 'rb') as f:
        hdr = f.read(24)
        if hdr[:4] != b'CrAU':
            sys.exit('不是 OTA payload (magic=%r)' % hdr[:4])
        version, = struct.unpack('>Q', hdr[4:12])
        manifest_len, = struct.unpack('>Q', hdr[12:20])
        meta_sig_size, = struct.unpack('>I', hdr[20:24])
        manifest = f.read(manifest_len)
        meta_sig_blob = f.read(meta_sig_size)
    scalars = parse_manifest_scalars(manifest)

    print(f'payload 版本 {version}, manifest {manifest_len}B, metadata 签名块 {meta_sig_size}B')
    print(f"manifest: block_size={scalars['block_size']} "
          f"signatures_offset={scalars['signatures_offset']} "
          f"signatures_size={scalars['signatures_size']}")

    pin = args.pin_key.lower() if args.pin_key else None
    results = []

    def resolve_key(sig_entry):
        """返回 (pubkey_der, source) 或 (None, None)"""
        if sig_entry['pub']:
            return sig_entry['pub'], '内嵌'
        if args.pubkey:
            return open(args.pubkey, 'rb').read(), args.pubkey
        default_key = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   'prebuilt', 'ota_public_key.pem')
        if os.path.exists(default_key):
            return open(default_key, 'rb').read(), default_key
        return None, None

    # 1) metadata 签名 (覆盖 manifest)
    msigs = parse_signatures(meta_sig_blob)
    if not msigs:
        if args.allow_unsigned:
            print('  [metadata] 无签名块, --allow-unsigned 已跳过')
        else:
            print('  [metadata] 无签名块且未指定 --allow-unsigned')
            sys.exit(2)
    else:
        key, src = resolve_key(msigs[0])
        if key:
            results.append(verify_with_key(
                'metadata', msigs[0], lambda: mem_chunks(manifest), pin, key, src))
        else:
            ok_struct = bool(msigs[0]['data'])
            note = ('  [metadata] 有签名块 (%dB) 但无可用公钥, 仅结构校验%s'
                    % (len(msigs[0]['data']),
                       ' -> 失败(--strict)' if args.strict else ' -> 通过'))
            print(note)
            if args.strict:
                results.append(False)
            else:
                results.append(ok_struct)

    # 2) payload 签名 (覆盖 payload[0:signatures_offset])
    off, size = scalars['signatures_offset'], scalars['signatures_size']
    if args.skip_payload_sig:
        print('  [payload] --skip-payload-sig 已跳过')
    elif off and size:
        with open(args.payload, 'rb') as f2:
            f2.seek(off)
            blob = f2.read(size)
        psigs = parse_signatures(blob)
        if psigs:
            key, src = resolve_key(psigs[0])
            if key:
                results.append(verify_with_key(
                    'payload', psigs[0],
                    lambda: file_prefix_chunks(args.payload, off), pin, key, src))
            else:
                print(f"  [payload] 有签名块 ({len(psigs[0]['data'])}B) 但无可用公钥, "
                      f"仅结构校验{' -> 失败(--strict)' if args.strict else ' -> 通过'}")
                if args.strict:
                    results.append(False)
                else:
                    results.append(bool(psigs[0]['data']))
        else:
            print('  [payload] 签名块解析为空')
            results.append(False)
    else:
        print('  [payload] manifest 未声明 signatures_offset/size, 跳过')

    if not results or not all(results):
        sys.exit('payload 签名校验未全部通过')
    print('payload 签名校验: 全部通过')


if __name__ == '__main__':
    main()
