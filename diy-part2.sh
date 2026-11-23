#!/bin/bash
#
# diy-part2.sh
# 由 Actions-OpenWrt 在 `./scripts/feeds install -a` 之后、`make defconfig` 之前执行。
#
# 【关键】yml 执行本脚本前已 `cd openwrt`，脚本启动时当前目录就是源码根，
#        因此脚本内不能再无条件 `cd openwrt`（会去找 openwrt/openwrt 而失败）。
#        下面用自适应判断兼容"CI 环境"和"本地手动执行"两种情况。
#
# 本脚本做三件事：
#   1) 把仓库自带的设备树复制进 sunxi target 的内核覆盖目录
#   2) 把本盒子的 Device profile 注册进 sunxi 的 image 定义文件
#   3) 把编译目标（.config）切到本盒子

set -e

# 仓库根目录：用 $0 定位，不受当前工作目录影响（$0 = /workdir/diy-part2.sh）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DTS_NAME="sun6i-a31s-mars-a31s"
DTS_SRC="$SCRIPT_DIR/dts/${DTS_NAME}.dts"

[ -f "$DTS_SRC" ] || { echo "[diy-part2] 找不到 $DTS_SRC"; exit 1; }

# 自适应进入源码目录：
#   CI 环境：当前目录已是 openwrt/，没有 openwrt 子目录 → 保持不动
#   本地手动：当前目录是仓库根，有 openwrt/ → 进去
if [ -d "openwrt" ] && [ -f "openwrt/.config" ]; then
    cd openwrt
fi

# 校验当前目录确实是 OpenWrt 源码根，出错时信息更直观
[ -d "target/linux/sunxi" ] || { echo "[diy-part2] 当前目录不是 OpenWrt 源码根：$PWD"; exit 1; }

# ------------------------------------------------------------------
# 1) 注入设备树到内核源码
#    target/linux/<target>/files/ 的内容会在内核 prepare 阶段按相同
#    相对路径拷进 build_dir 里真正编译的内核源码树，最不挑内核版本。
# ------------------------------------------------------------------
DTS_DIR="target/linux/sunxi/files/arch/arm/boot/dts"
mkdir -p "$DTS_DIR"
cp -f "$DTS_SRC" "$DTS_DIR/"
echo "[diy-part2] DTS 已注入: $DTS_DIR/${DTS_NAME}.dts"

# ------------------------------------------------------------------
# 2) 注册设备 profile
#    自动定位真正被 include 的 image 定义文件（含 define Device/allwinner 的那个）
# ------------------------------------------------------------------
IMG_FILE="$(grep -rl 'define Device/allwinner' target/linux/sunxi/image/ 2>/dev/null | head -1)"
if [ -z "$IMG_FILE" ]; then
    echo "[diy-part2] 警告：未定位到 image 定义文件，请手动追加 Device 定义"
else
    cat >> "$IMG_FILE" <<PROFILE_EOF

# ===== MARS A31s 自定义设备（由 diy-part2.sh 追加）=====
define Device/mars_a31s
  DEVICE_VENDOR := MARS
  DEVICE_MODEL := A31s
  DEVICE_DTS := ${DTS_NAME}
  KERNEL_LOADADDR := 0x40008000
  DEVICE_PACKAGES := kmod-rtl8188eu kmod-usb2 kmod-usb-ohci
endef
TARGET_DEVICES += mars_a31s
# ===== 自定义设备结束 =====
PROFILE_EOF
    echo "[diy-part2] Device/mars_a31s 已注册到 $IMG_FILE"
fi

# ------------------------------------------------------------------
# 3) 切换编译目标到本盒子
#    子目标名随源码版本不同：老 lede 是 cortexa7，新版是 sun6i-a31。
#    这里自动探测目录名，避免写死导致 make defconfig 后目标丢失。
# ------------------------------------------------------------------
SUBTARGET=""
for d in sun6i-a31 cortexa7; do
    if [ -d "target/linux/sunxi/$d" ]; then SUBTARGET="$d"; break; fi
done
if [ -z "$SUBTARGET" ]; then
    echo "[diy-part2] 警告：未识别 sunxi 子目标，现有目录如下："
    ls target/linux/sunxi/
    SUBTARGET="cortexa7"
fi
# Kconfig 里用下划线（sun6i_a31），目录名用连字符（sun6i-a31）
SUBTARGET_CFG="$(echo "$SUBTARGET" | tr '-' '_')"
echo "[diy-part2] 使用子目标: $SUBTARGET_CFG"

# .config 由 yml 从仓库根目录 mv 过来，正常情况下存在；兜底创建避免 sed 报错
[ -f ".config" ] || touch .config

sed -i '/^CONFIG_TARGET_[a-z0-9_]*=y/d' .config
cat >> .config <<TARGET_EOF
CONFIG_TARGET_sunxi=y
CONFIG_TARGET_sunxi_${SUBTARGET_CFG}=y
CONFIG_TARGET_sunxi_${SUBTARGET_CFG}_DEVICE_mars_a31s=y
TARGET_EOF
echo "[diy-part2] 编译目标已切到 sunxi/${SUBTARGET_CFG}/mars_a31s"

exit 0
