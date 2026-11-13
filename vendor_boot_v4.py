#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
vendor_boot_v4.py —— 自带实现的 Android vendor_boot (header v4) 打包/解析工具

为什么需要它:
    OrangeFox / TWRP 树里的 system/tools/mkbootimg/mkbootimg.py 往往是旧版,
    --vendor_ramdisk 只能接一个文件, 也没有 --ramdisk_type, 无法生成 v4 的
    vendor_ramdisk_table (多 fragment)。而 PD2551 的 vendor_boot 需要
    platform + recovery 两个不同 type 的 fragment, 否则 normal boot 会把
    TWRP 的 /init 当成系统 init 顶掉 Android。

    本工具只用 Python 标准库, 直接按 bootimg.h 的 v4 结构读写, 不依赖树内工具。

子命令:
    clone   --src IN --out OUT
            原样重打(不换 fragment, 不改 cmdline), 用于验证布局是否与输入逐字节一致
    dump    --src IMG
            打印头部字段与 fragment 表
    repack  --src IN --out OUT [--platform FILE] [--dtb FILE]
            --add-cmdline "k=v" [--set-cmdline TEXT] [--pagesize 4096]
            用 platform 替换/前置第一个 fragment, 其余 fragment 原样保留(含 type)
"""

import argparse
import os
import struct
import sys

PAGE = 4096
MAGIC = b'VNDRBOOT'
HDR_SIZE_V4 = 2128
ENTRY_SIZE_V4 = 108

# AOSP bootimg.h vendor_ramdisk_type (v4): 官方枚举, 勿改!
#   enum vendor_ramdisk_type {
#       VENDOR_RAMDISK_TYPE_NONE     = 0,
#       VENDOR_RAMDISK_TYPE_PLATFORM = 1,
#       VENDOR_RAMDISK_TYPE_RECOVERY = 2,
#       VENDOR_RAMDISK_TYPE_DLKM     = 3,
#   };
# 注意: 旧版曾错写为 {0:platform,1:recovery,2:dlkm}, 整体错位一位,
# 导致把 20B 的空 platform 主区当成 recovery 片段 (CI Run 报"空 ramdisk"假警报)。
TYPE_NAMES = {0: 'none', 1: 'platform', 2: 'recovery', 3: 'dlkm'}
NAME_TYPES = {v: k for k, v in TYPE_NAMES.items()}


def align(n, a=PAGE):
    return (n + a - 1) // a * a


class VendorBoot:
    def __init__(self, data):
        self.data = data
        if data[:8] != MAGIC:
            raise SystemExit('不是 vendor_boot 镜像: magic=%r' % data[:8])
        (self.header_version, self.page_size, self.kernel_addr, self.ramdisk_addr,
         self.vendor_ramdisk_size) = struct.unpack('<IIIII', data[8:28])
        self.cmdline = data[28:28 + 2048].split(b'\x00')[0].decode('utf-8', 'replace')
        self.tags_addr = struct.unpack('<I', data[2076:2080])[0]
        self.name = data[2080:2096].split(b'\x00')[0].decode('utf-8', 'replace')
        (self.header_size, self.dtb_size) = struct.unpack('<II', data[2096:2104])
        self.dtb_addr = struct.unpack('<Q', data[2104:2112])[0]

        ps = self.page_size or PAGE
        off = align(self.header_size, ps)
        self.ramdisk_off = off
        self.ramdisk = data[off:off + self.vendor_ramdisk_size]

        off = align(off + self.vendor_ramdisk_size, ps)
        self.dtb_off = off
        self.dtb = data[off:off + self.dtb_size]

        off = align(off + self.dtb_size, ps)
        self.table_off = off
        self.table_raw = b''
        self.entries = []
        self.bootconfig = b''

        if self.header_version >= 4:
            (tbl_size, num, esz, bcsz) = struct.unpack('<IIII', data[2112:2128])
            self.table_raw = data[off:off + tbl_size]
            self.entries = self._parse_table(self.table_raw, num, esz)
            off = align(off + tbl_size, ps)
            self.bootconfig_off = off
            self.bootconfig = data[off:off + bcsz]
            self.content_end = off + bcsz
        else:
            self.content_end = off

    @staticmethod
    def _parse_table(raw, num, esz):
        out = []
        for i in range(num):
            e = raw[i * esz:(i + 1) * esz]
            if len(e) < 12:
                break
            size, offset, typ = struct.unpack('<III', e[:12])
            name = e[12:44].split(b'\x00')[0].decode('utf-8', 'replace')
            board_id = list(struct.unpack('<16I', e[44:108]))
            out.append({'size': size, 'offset': offset, 'type': typ,
                        'name': name, 'board_id': board_id})
        return out

    def frag_bytes(self, idx):
        e = self.entries[idx]
        return self.ramdisk[e['offset']:e['offset'] + e['size']]

    def dump(self):
        print('header_version : %d' % self.header_version)
        print('page_size      : %d' % self.page_size)
        print('header_size    : %d' % self.header_size)
        print('name           : %r' % self.name)
        print('kernel_addr    : 0x%08x' % self.kernel_addr)
        print('ramdisk_addr   : 0x%08x' % self.ramdisk_addr)
        print('tags_addr      : 0x%08x' % self.tags_addr)
        print('dtb_addr       : 0x%016x' % self.dtb_addr)
        print('dtb_size       : %d  (at 0x%x)' % (self.dtb_size, self.dtb_off))
        print('vendor_ramdisk : %d  (at 0x%x)' % (self.vendor_ramdisk_size, self.ramdisk_off))
        print('bootconfig     : %d bytes (at 0x%x)' % (len(self.bootconfig), self.bootconfig_off))
        print('cmdline        : %s' % (self.cmdline or '<空>'))
        print('fragments      : %d' % len(self.entries))
        for i, e in enumerate(self.entries):
            print('  [%d] %-9s size=%-10d off=%-10d name=%r board_id[0]=0x%x'
                  % (i, TYPE_NAMES.get(e['type'], e['type']), e['size'],
                     e['offset'], e['name'], e['board_id'][0]))

    def build(self, fragments, cmdline=None, dtb=None, page_size=None):
        """fragments: [(bytes, type, name, board_id)]"""
        ps = page_size or self.page_size or PAGE
        cmd = (cmdline if cmdline is not None else self.cmdline).encode('utf-8')
        if len(cmd) > 2047:
            raise SystemExit('cmdline 超长: %d > 2047' % len(cmd))
        dtb = self.dtb if dtb is None else dtb

        blob = bytearray()
        table = bytearray()
        for payload, typ, name, board_id in fragments:
            table += struct.pack('<III32s16I', len(payload), len(blob), typ,
                                 name.encode()[:31], *board_id)
            blob += payload
        if len(blob) == 0:
            raise SystemExit('没有 fragment')

        hdr = struct.pack(
            '<8sIIIII2048sI16sIIQIIII',
            MAGIC, 4, ps, self.kernel_addr, self.ramdisk_addr, len(blob),
            cmd, self.tags_addr, self.name.encode()[:15],
            HDR_SIZE_V4, len(dtb), self.dtb_addr,
            len(table), len(fragments), ENTRY_SIZE_V4, len(self.bootconfig))

        out = bytearray()

        def pad():
            out.extend(b'\x00' * (align(len(out), ps) - len(out)))

        out += hdr
        pad()
        out += blob
        pad()
        out += dtb
        pad()
        out += table
        pad()
        # bootconfig 放在最后, 后面由调用方(avbtool/truncate)补到分区大小
        out += self.bootconfig
        return bytes(out)


def split_args(text):
    """按空白切分 cmdline, 但保留引号内的空格"""
    import shlex
    try:
        return shlex.split(text)
    except ValueError:
        return text.split()


def merge_cmdline(base, extras):
    """向 base 追加 extras 中的 k=v, 已存在的 key 则替换值"""
    toks = split_args(base)
    keys = {}
    for i, t in enumerate(toks):
        if '=' in t:
            keys[t.split('=', 1)[0]] = i
    for t in split_args(extras):
        if '=' in t:
            k = t.split('=', 1)[0]
            if k in keys:
                toks[keys[k]] = t
            else:
                keys[k] = len(toks)
                toks.append(t)
        else:
            toks.append(t)
    return ' '.join(toks)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)

    p = sub.add_parser('dump')
    p.add_argument('--src', required=True)

    p = sub.add_parser('clone')
    p.add_argument('--src', required=True)
    p.add_argument('--out', required=True)

    p = sub.add_parser('repack')
    p.add_argument('--src', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--platform')
    p.add_argument('--platform-type', default='platform',
                   choices=sorted(NAME_TYPES))
    p.add_argument('--dtb')
    p.add_argument('--cmdline')
    p.add_argument('--add-cmdline', default='')
    p.add_argument('--pagesize', type=int)
    p.add_argument('--keep-platform', action='store_true',
                   help='保留原有 platform 片段, 与 --platform 并存')
    p.add_argument('--platform-if-missing', action='store_true',
                   help='src 已有 platform 片段时不再追加(优先用构建产物自带的)')
    p.add_argument('--retag-recovery', action='store_true',
                   help='把 src 里除 dlkm 外的片段统一改成 recovery 类型')
    p.add_argument('--drop-type', default='',
                   help='丢弃指定类型的片段, 逗号分隔 (如 platform,dlkm)')

    a = ap.parse_args()
    src = VendorBoot(open(a.src, 'rb').read())

    if a.cmd == 'dump':
        src.dump()
        return

    if a.cmd == 'clone':
        frags = [(src.frag_bytes(i), e['type'], e['name'], e['board_id'])
                 for i, e in enumerate(src.entries)]
        open(a.out, 'wb').write(src.build(frags))
        print('clone: %d fragments -> %s' % (len(frags), a.out))
        return

    # repack
    src_frags = [(src.frag_bytes(i), e['type'], e['name'], e['board_id'])
                 for i, e in enumerate(src.entries)]
    if not src_frags:
        # header v3 或表为空: 整个 vendor_ramdisk 就是一份 recovery ramdisk
        src_frags = [(src.ramdisk, NAME_TYPES['recovery'], 'recovery', [0] * 16)]

    has_platform = any(f[1] == NAME_TYPES['platform'] for f in src_frags)
    use_platform = bool(a.platform) and not (a.platform_if_missing and has_platform)

    drop = {NAME_TYPES.get(t.strip(), -1) for t in a.drop_type.split(',') if t.strip()}

    frags = []
    for payload, typ, name, bid in src_frags:
        if typ in drop:
            continue
        # 仅当注入的是 platform 片段(替换语义)时才丢弃旧 platform;
        # 混合模式注入的是 recovery 片段, 原厂 platform 片段必须原样保留
        # (normal boot 的 fstab/first_stage 来源)。
        if (a.platform_type == 'platform' and use_platform
                and typ == NAME_TYPES['platform'] and not a.keep_platform):
            continue  # 用新 platform 替换旧的
        if a.retag_recovery and typ != NAME_TYPES['dlkm']:
            typ = NAME_TYPES['recovery']
            name = 'recovery'
        frags.append((payload, typ, name, bid))
    # 注入片段放到最后: bootloader 按表顺序拼接 cpio, 后面的归档覆盖同名路径。
    # 原厂镜像就是 platform 在前 / recovery 在后, recovery 片段的 /init
    # 必须最后写入才能覆盖 platform 片段里的同名文件。
    if use_platform:
        frags.append((open(a.platform, 'rb').read(),
                      NAME_TYPES[a.platform_type], a.platform_type, [0] * 16))
    if not frags:
        raise SystemExit('src 里没有可用的 recovery fragment')

    cmd = a.cmdline if a.cmdline is not None else src.cmdline
    if a.add_cmdline:
        cmd = merge_cmdline(cmd, a.add_cmdline)

    dtb = open(a.dtb, 'rb').read() if a.dtb else None
    img = src.build(frags, cmdline=cmd, dtb=dtb, page_size=a.pagesize)
    open(a.out, 'wb').write(img)

    chk = VendorBoot(open(a.out, 'rb').read())
    print('repack: %d fragments, %d bytes' % (len(frags), len(img)))
    print('cmdline: %s' % chk.cmdline)
    if a.platform and not use_platform:
        print('note: 构建产物已自带 platform 片段, 未追加 prebuilt 平台 ramdisk')
    for i, e in enumerate(chk.entries):
        print('  [%d] %-9s size=%d name=%r' % (i, TYPE_NAMES.get(e['type'], e['type']),
                                              e['size'], e['name']))
    if chk.cmdline != cmd:
        raise SystemExit('自检失败: cmdline 未正确写入')
    for i, e in enumerate(chk.entries):
        got = chk.frag_bytes(i)
        if got != frags[i][0]:
            raise SystemExit('自检失败: fragment %d 内容不一致' % i)


if __name__ == '__main__':
    main()
