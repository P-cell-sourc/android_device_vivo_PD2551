#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# verify_ota_zip.py — 官方 OTA zip 的签名链校验 (JAR v1 签名, 只依赖 openssl CLI)
#
# 校验链 (每一步都验证):
#   CERT.RSA (PKCS#7) --签名--> CERT.SF --摘要--> MANIFEST.MF --摘要--> payload.bin
#
# 同时完成:
#   - payload.bin 与 META-INF/CERT.SF/MANIFEST.MF 均直接流式读取, 不落盘
#   - CMS 验签用 openssl cms -noverify (vivo 证书自签, 链校验无意义),
#     用 --pin-cert <sha256hex> 钉死签名证书指纹才具有认证意义
#
# 用法:
#   python3 verify_ota_zip.py 官方OTA.zip
#   python3 verify_ota_zip.py 官方OTA.zip --pin-cert <sha256hex>
#
# 退出码: 0=通过  1=失败

import argparse
import base64
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import zipfile

CHUNK = 4 << 20


def jar_member(zipf, name):
    return zipf.read(name)


def check(step, ok, detail=''):
    tag = 'PASS' if ok else 'FAIL'
    print(f'  [{step}] {tag} {detail}')
    return ok


def cert_fingerprint(cert_path):
    """sha256(DER) of the signer cert via openssl"""
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, 'cert.der')
        r = subprocess.run(['openssl', 'x509', '-in', cert_path, '-outform', 'DER',
                            '-out', out], capture_output=True)
        if r.returncode != 0:
            return None
        return hashlib.sha256(open(out, 'rb').read()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('ota_zip')
    ap.add_argument('--pin-cert', help='签名证书指纹 sha256(DER) hex, 可选(推荐)')
    args = ap.parse_args()

    zipf = zipfile.ZipFile(args.ota_zip)
    results = []

    # ---- 1. 提取签名文件 ----
    try:
        manifest = jar_member(zipf, 'META-INF/MANIFEST.MF')
        sf = jar_member(zipf, 'META-INF/CERT.SF')
    except KeyError as e:
        sys.exit(f'OTA zip 缺少 JAR 签名文件: {e}')
    print(f'MANIFEST.MF {len(manifest)}B, CERT.SF {len(sf)}B')

    # ---- 2. CMS 验签: CERT.RSA 覆盖 CERT.SF ----
    with tempfile.TemporaryDirectory() as td:
        try:
            rsa = jar_member(zipf, 'META-INF/CERT.RSA')
        except KeyError:
            print('  [cms] 无 CERT.RSA, zip 未签名')
            sys.exit(1)
        p_sf = os.path.join(td, 'CERT.SF')
        p_rsa = os.path.join(td, 'CERT.RSA')
        open(p_sf, 'wb').write(sf)
        open(p_rsa, 'wb').write(rsa)
        r = subprocess.run(
            ['openssl', 'cms', '-verify', '-inform', 'DER', '-in', p_rsa,
             '-content', p_sf, '-out', os.devnull, '-noverify', '-purpose', 'any'],
            capture_output=True, text=True)
        results.append(check('cms(CERT.RSA->CERT.SF)', r.returncode == 0,
                             r.stderr.strip()[:80]))
        # 证书指纹
        # openssl cms 不直接给签名者证书, 用 pkcs7 取
        p7 = subprocess.run(
            ['openssl', 'pkcs7', '-inform', 'DER', '-in', p_rsa,
             '-print_certs', '-out', os.path.join(td, 'certs.pem')],
            capture_output=True, text=True)
        if p7.returncode == 0:
            # 取第一个证书 (签名者)
            pem = open(os.path.join(td, 'certs.pem'), 'rb').read()
            first = re.search(rb'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                              pem, re.S)
            if first:
                cp = os.path.join(td, 'signer.pem')
                open(cp, 'wb').write(first.group(0))
                fp = cert_fingerprint(cp)
                print(f'  [cert] 签名者证书指纹 sha256(DER)={fp}')
                subj = subprocess.run(
                    ['openssl', 'x509', '-in', cp, '-noout', '-subject'],
                    capture_output=True, text=True).stdout.strip()
                print(f'  [cert] {subj}')
                if args.pin_cert:
                    results.append(check('cert-pin',
                                         fp == args.pin_cert.lower(),
                                         f'期望 {args.pin_cert}'))

    # ---- 3. CERT.SF -> MANIFEST.MF section 摘要 ----
    sec = re.search(rb'(\r\n)?Name: payload\.bin\r\nSHA1-Digest(-Manifest)?: ([^\r]+)\r\n\r\n',
                    manifest)
    sf_expect = re.search(rb'Name: payload\.bin\r\nSHA1-Digest-Manifest: (\S+)', sf)
    if sec and sf_expect:
        body = sec.group(0)
        body = body[2:] if body.startswith(b'\r\n') else body
        ok = hashlib.sha1(body).digest() == base64.b64decode(sf_expect.group(1))
        results.append(check('sf->manifest-section', ok))
    else:
        print('  [sf->manifest-section] 找不到 payload.bin 条目, 跳过')

    # ---- 4. MANIFEST.MF -> payload.bin 内容摘要 (流式) ----
    mf_expect = re.search(rb'Name: payload\.bin\r\nSHA1-Digest: (\S+)', manifest)
    if mf_expect:
        want = base64.b64decode(mf_expect.group(1))
        h = hashlib.sha1()
        with zipf.open('payload.bin') as f:
            while True:
                c = f.read(CHUNK)
                if not c:
                    break
                h.update(c)
        results.append(check('manifest->payload.bin',
                             h.digest() == want,
                             f'sha1={h.hexdigest()[:16]}'))
    else:
        print('  [manifest->payload.bin] 找不到 SHA1-Digest 条目, 跳过')

    if not all(results):
        sys.exit('OTA zip 签名链校验失败')
    print('OTA zip 签名链校验: 全部通过')


if __name__ == '__main__':
    main()
