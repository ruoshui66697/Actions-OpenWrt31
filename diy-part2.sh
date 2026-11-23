
#!/bin/bash
#
# diy-part2.sh
# 由 Actions-OpenWrt 在 `./scripts/feeds install -a` 之后、`make defconfig` 之前执行。
# 此时源码树（coolsnowwolf/lede）已经 clone 完成，是注入自定义 DTS、
# 注册设备 profile、切换编译目标的唯一正确时机。
#
# 本脚本做三件事：
#   1) 把仓库自带的设备树复制到源码树里 sunxi target 的内核覆盖目录
#   2) 把本盒子的 Device profile 注册进 sunxi 的 image 定义文件
#   3) 把编译目标（.config）切到本盒子
#
# 运行时的当前目录就是仓库根目录（脚本与 dts/ 同级）。

set -e

# 仓库内 dts 的位置（与本脚本同级目录下的 dts/ 文件夹）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DTS_NAME="sun6i-a31s-mars-a31s"
DTS_SRC="$SCRIPT_DIR/dts/${DTS_NAME}.dts"

[ -f "$DTS_SRC" ] || { echo "[diy-part2] 找不到 $DTS_SRC"; exit 1; }

cd openwrt || { echo "[diy-part2] 未找到 openwrt 源码目录"; exit 1; }

# ------------------------------------------------------------------
# 1) 注入设备树到内核源码
#    target/linux/<target>/files/ 目录的内容，会在内核 prepare 阶段
#    按相同相对路径拷贝进 build_dir 里真正编译的内核源码树。
#    这是【最不挑内核版本】的做法：files 与 files-<内核次版本> 都会被使用，
#    所以放不带版本后缀的 files/ 最稳。
# ------------------------------------------------------------------
DTS_DIR="target/linux/sunxi/files/arch/arm/boot/dts"
mkdir -p "$DTS_DIR"
cp -f "$DTS_SRC" "$DTS_DIR/"
echo "[diy-part2] DTS 已注入: $DTS_DIR/${DTS_NAME}.dts"

# ------------------------------------------------------------------
# 2) 注册设备 profile
#    自动定位当前源码里真正被 include 的 image 定义文件
#    （哪个文件里有 "define Device/allwinner" 就是它），
#    把新 define 块追加进去。追加进被 include 的文件一定会被加载，
#    比"新建一个 .mk 再想办法 include"可靠。
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
#    先清掉模板 .config 里残留的其它 target 选择，避免多 target=y 冲突；
#    再写入本盒子的 target/子目标/profile。随后的 make defconfig 会据此补全。
#    子目标名 sunxi_cortexa7（sun6i=A7）。若源码子目标名不同，按报错改。
# ------------------------------------------------------------------
sed -i '/^CONFIG_TARGET_[a-z0-9_]*=y/d' .config
cat >> .config <<TARGET_EOF
CONFIG_TARGET_sunxi=y
CONFIG_TARGET_sunxi_cortexa7=y
CONFIG_TARGET_sunxi_cortexa7_DEVICE_mars_a31s=y
TARGET_EOF
echo "[diy-part2] 编译目标已切到 sunxi/cortexa7/mars_a31s"

exit 0
