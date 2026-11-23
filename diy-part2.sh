#!/bin/bash
#
# diy-part2.sh
# 执行时机：./scripts/feeds install -a 之后、make defconfig 之前
# 前置条件：yml 已 `cd openwrt`，脚本启动时 CWD = 源码根
#
# 本脚本做两件事：
#   1) 把仓库自带 DTS 注入内核源码树（走 target/linux/sunxi/files/ 覆盖机制）
#   2) 在 cortexa7.mk 头部插入本盒子的 Device 定义
#
# 【不做的事】不动 .config —— 那份是你本地 menuconfig 生成后提交的完整文件，
#             由 yml 第 79 行 mv 进来，脚本再改会被 make defconfig 冲掉。

set -e

# ── 定位仓库根（$0 = /workdir/diy-part2.sh，不受 CWD 影响）──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DTS_NAME="sun6i-a31s-mars-a31s"
DTS_SRC="$SCRIPT_DIR/dts/${DTS_NAME}.dts"

[ -f "$DTS_SRC" ] || { echo "[diy-part2] 错误：找不到 $DTS_SRC"; exit 1; }

# ── 自适应进源码目录（兼容 CI / 本地手动）──
if [ -d "openwrt" ] && [ -f "openwrt/.config" ]; then
    cd openwrt
fi
[ -d "target/linux/sunxi" ] || { echo "[diy-part2] 错误：当前目录不是 OpenWrt 源码根：$PWD"; exit 1; }

SUBTARGET="cortexa7"
IMG_FILE="target/linux/sunxi/image/${SUBTARGET}.mk"
[ -f "$IMG_FILE" ] || { echo "[diy-part2] 错误：找不到 $IMG_FILE"; exit 1; }

# ==========================================================
# 1) 注入 DTS 到内核源码树
#    target/linux/<target>/files/ 的内容会在内核 prepare 阶段
#    按相同相对路径覆盖进 build_dir 的内核树，不挑内核版本。
#    路径带 allwinner/ 是为了对齐 image/Makefile 里的
#    `SUNXI_DTS_DIR := allwinner/`，让自动拼接的 DTS 路径找得到。
# ==========================================================
DTS_DIR="target/linux/sunxi/files/arch/arm/boot/dts/allwinner"
mkdir -p "$DTS_DIR"
cp -f "$DTS_SRC" "$DTS_DIR/${DTS_NAME}.dts"
echo "[diy-part2] DTS 已注入 -> $DTS_DIR/${DTS_NAME}.dts"

# ==========================================================
# 2) 注册 Device 定义（幂等：已存在则跳过，可反复执行）
#    插入位置：文件开头 KERNEL_LOADADDR 那行之后
#    原因：image/Makefile 末尾 `include $(SUBTARGET).mk`，
#          追加到文件尾 Make 不会再解析 -> 必须插在前面
# ==========================================================
if grep -q 'define Device/inphic_mars-a31s' "$IMG_FILE"; then
    echo "[diy-part2] Device 定义已存在，跳过"
else
    MARKER='KERNEL_LOADADDR:=0x40008000'
    grep -q "$MARKER" "$IMG_FILE" || { echo "[diy-part2] 错误：锚点行未找到，$IMG_FILE 结构有变"; exit 1; }

    sed -i "/^${MARKER}$/a\\
\\
define Device/inphic_mars-a31s\\
  \$(call Device/FitImageGzip)\\
  DEVICE_VENDOR := Inphic\\
  DEVICE_MODEL := MARS A31s\\
  DEVICE_PACKAGES:= kmod-rtl8xxxu rtl8188eu-firmware kmod-rtc-sunxi\\
  SUPPORTED_DEVICES += inphic,mars-a31s\\
  SOC := sun6i-a31s\\
endef\\
TARGET_DEVICES += inphic_mars-a31s\\
" "$IMG_FILE"

    echo "[diy-part2] Device/inphic_mars-a31s 已插入 $IMG_FILE"
fi

# ── 自检：把插入结果打进 CI 日志，方便一眼确认 ──
echo "[diy-part2] ---- 插入后前 14 行 ----"
head -14 "$IMG_FILE"
echo "[diy-part2] ---- DTS 目录实际内容 ----"
ls -l "$DTS_DIR/"

exit 0
