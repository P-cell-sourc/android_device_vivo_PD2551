#!/bin/bash
# check-vendor-fit.sh — PD2551 recovery 适配自检
# 用法: ./check-vendor-fit.sh <设备树根目录>
# 作用: 在刷机前把"模块与内核不匹配""模块缺失"这类必死问题挡掉。
set -u

DEV="${1:-.}"
PRE="$DEV/prebuilt"
MODDIR="$DEV/recovery/root/lib/modules"
FAIL=0

hr() { printf '%.0s-' {1..64}; echo; }

# GKI: 只比较 KMI (如 6.6.89-android15-8), 忽略 -g<hash> 及后缀。
# kernel 的 -g<hash>-abogki<id> 与 vendor 模块的 -g<hash> 天生不同, 属正常。
kmi_of() { printf '%s' "$1" | sed -E 's/-g[0-9a-f]{6,}.*$//'; }

hr; echo "[1] 内核版本 / KMI"; hr
KREL=""
if [ -f "$PRE/kernel" ]; then
  KREL="$(strings "$PRE/kernel" | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+-[^ ]*' )"
  echo "kernel file : $PRE/kernel ($(du -h "$PRE/kernel" | cut -f1))"
  echo "UTS_RELEASE : ${KREL:-<未找到>}"
  echo "KMI         : $(kmi_of "$KREL")"
else
  echo "!! 缺少 $PRE/kernel"; FAIL=1
fi

hr; echo "[2] 模块 vermagic 分布"; hr
if [ -d "$MODDIR" ]; then
  declare -A VM
  for f in "$MODDIR"/*.ko; do
    [ -e "$f" ] || continue
    v="$(strings "$f" | grep -m1 'vermagic=' | sed 's/^vermagic=//')"
    VM["$v"]=$(( ${VM["$v"]:-0} + 1 ))
  done
  for v in "${!VM[@]}"; do
    printf '%4d 个模块: %s\n' "${VM[$v]}" "$v"
  done
  echo "模块总数: $(ls "$MODDIR"/*.ko 2>/dev/null | wc -l)"

  # 与内核比对: 只比 KMI
  if [ -n "$KREL" ]; then
    KMOD="$(kmi_of "$KREL")"
    BAD=0; BADV=""
    for v in "${!VM[@]}"; do
      if [ "$(kmi_of "$v")" != "$KMOD" ]; then BAD=$((BAD + VM[$v])); BADV="$BADV
                   $v"; fi
    done
    echo
    if [ "$BAD" -gt 0 ]; then
      echo "!! $BAD 个模块的 KMI 与内核不一致:"
      echo "   内核 KMI: $KMOD"
      echo "   模块 KMI:$BADV"
      echo "   => 内核大版本/KMI 不同, 模块必然 invalid module format, 需从同一份 OTA 重取"
      FAIL=1
    else
      echo "OK  KMI 一致: $KMOD"
      echo "    注: kernel 的 -g<hash>-abogki<id> 与 vendor 模块的 -g<hash> 不同是 GKI 的正常状态,"
      echo "        不参与加载匹配; 实际兼容由 KMI + 符号 CRC 决定, 最终以 dmesg 为准。"
    fi
  fi
else
  echo "!! 缺少目录 $MODDIR"; FAIL=1
fi

hr; echo "[3] modules.load.recovery 引用完整性"; hr
LOADF="$MODDIR/modules.load.recovery"
if [ -f "$LOADF" ]; then
  MISS=0
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    case "$m" in \#*) continue ;; esac
    [ -f "$MODDIR/$m" ] || { echo "   缺少: $m"; MISS=$((MISS+1)); }
  done < "$LOADF"
  echo "load 列表 $(grep -cv '^\s*$' "$LOADF") 条, 缺失 $MISS 个"
  [ "$MISS" -gt 0 ] && FAIL=1
else
  echo "!! 缺少 $LOADF (TWRP 不会自动 insmod)"; FAIL=1
fi

hr; echo "[4] modules.dep / softdep / alias"; hr
for f in modules.dep modules.softdep modules.alias; do
  if [ -f "$MODDIR/$f" ]; then
    echo "OK  $f ($(wc -l < "$MODDIR/$f") 行)"
  else
    echo "!!  缺少 $f"; FAIL=1
  fi
done

hr; echo "[5] vendor_cmdline 关键参数"; hr
S="$DEV/package-vendor-boot.sh"
B2="$DEV/BoardConfig.mk"
if [ -f "$S" ]; then
  LINE="$(grep -m1 '^VENDOR_CMDLINE=' "$S" || true)"
  if echo "$LINE" | grep -q 'UNPACK_BOOTIMG'; then
    echo "OK  cmdline 从构建产物动态读回（推荐方式）"
    if [ -f "$B2" ] && grep -qE '^BOARD_VENDOR_CMDLINE' "$B2"; then
      echo "OK  已定义 BOARD_VENDOR_CMDLINE"
    else
      echo "!!  BoardConfig 未定义 BOARD_VENDOR_CMDLINE"; FAIL=1
    fi
    if [ -f "$B2" ] && grep -qE '^BOARD_KERNEL_CMDLINE.*androidboot.selinux=permissive' "$B2"; then
      echo "OK  BOARD_KERNEL_CMDLINE 含 androidboot.selinux=permissive"
    else
      echo "!!  BOARD_KERNEL_CMDLINE 缺 androidboot.selinux=permissive"; FAIL=1
    fi
  else
    echo "$LINE"
    for k in androidboot.selinux androidboot.hardware; do
      if echo "$LINE" | grep -q "$k"; then echo "OK  含 $k"; else echo "!!  缺 $k"; FAIL=1; fi
    done
  fi
else
  echo "!! 缺少 $S"; FAIL=1
fi

hr; echo "[6] BoardConfig 危险开关"; hr
B="$DEV/BoardConfig.mk"
chk() { # $1=pattern $2=说明
  if grep -qE "^[[:space:]]*$1" "$B"; then echo "!!  启用: $1  ($2)"; FAIL=1; else echo "OK  未启用: $1"; fi
}
if [ -f "$B" ]; then
  chk 'TW_SCREEN_BLANK_ON_BOOT[[:space:]]*:=[[:space:]]*true' '新 panel 容易黑屏假死'
  grep -qE '^TARGET_RECOVERY_PIXEL_FORMAT.*BGRA' "$B" && echo "!!  pixel format 是 BGRA_8888, 建议 RGBX_8888"
  grep -qE '^BOARD_VENDOR_CMDLINE' "$B" && echo "OK  已定义 BOARD_VENDOR_CMDLINE" || echo "!!  未定义 BOARD_VENDOR_CMDLINE"
else
  echo "!! 缺少 $B"; FAIL=1
fi

hr
if [ "$FAIL" -gt 0 ]; then
  echo "结果: 存在阻断项, 不建议刷机"
  exit 1
else
  echo "结果: 全部通过"
fi
