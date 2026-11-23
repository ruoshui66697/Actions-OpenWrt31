#!/bin/bash
#
# =============================================================================
# diy-part2.sh  —  Inphic MARS A31s (sun6i-a31s) 设备注册脚本
# =============================================================================
# 执行时机 : workflow 里 ./scripts/feeds install -a 之后、make defconfig 之前
# 前置条件 : 脚本启动时 CWD = OpenWrt 源码根（脚本内部会自适应）
# 仓库位置 : https://github.com/ruoshui66697/Actions-OpenWrt31
#
# ------------------------------------------------------------------------------
# 【本脚本只做一件事】
#     在 target/linux/sunxi/image/cortexa7.mk 里注册 Device/inphic_mars-a31s
#
# 【本脚本明确不做的事 —— 踩过坑，别再加回来】
#   ✗ 不 cp DTS 到内核树
#       原因: target/linux/sunxi/files/ 是【根文件系统覆盖层】机制，
#             make 时会把它的内容铺进 rootfs (/etc /sbin ...)，
#             它【从来不会】把 arch/arm/boot/dts/*.dts 送进内核源码树。
#             旧版这里写了 mkdir+cp，CI 自检 ls 看着是绿的（验的是仓库目录），
#             但内核树里根本没有该 dts -> 不产出 .dtb
#             -> mkits.sh 报 FATAL ERROR: Couldn't open ".../sun6i-a31s-mars-a31s.dtb"
#             -> make[5] Error 1 / Process completed with exit code 2
#        正解: dts 由【仓库文件 + 内核 patch】提供，见下方「DTS 来源说明」
#
#   ✗ 不改 .config
#       原因: .config 是本地 menuconfig 生成后提交的完整文件，
#             由 workflow mv 进来，本脚本再改会被 make defconfig 冲掉。
#
#   ✗ 不改 image/Config.in
#       原因: 设备符号由 cortexa7.mk 的 TARGET_DEVICES 自动生成，已验证。
#
# ------------------------------------------------------------------------------
# 【DTS 来源说明 —— 关键，后续纠错先看这里】
#   DTS 本体  : target/linux/sunxi/files/arch/arm/boot/dts/allwinner/
#                   sun6i-a31s-mars-a31s.dts          （仓库里手工维护，正本）
#   编译开关  : target/linux/sunxi/patches-6.12/
#                   901-mars-a31s-add-dts.patch       （给内核 dts 目录的
#                   Makefile 补 dtb-y += ...、Kconfig 补 MACH_... 符号）
#   二者缺一不可:
#       只有 dts 没有 patch -> 文件在树里但不编译 -> 就是你见过的那条报错
#       只有 patch 没有 dts -> 报 No rule to make target '*.dts'
#   为什么走 patches-6.12: .config 里 LINUX_6_12=y / TESTING_KERNEL=y，
#       实际内核 linux-6.12.118，所以目录名必须是 patches-6.12 而非 patches-6.1
#
# ------------------------------------------------------------------------------
# 【维护约定】
#   * 一次只改一个变量。红了一次只回头动一处，否则不知道是哪个救活的。
#   * 改 DTS 内容 -> 只改上面那个 files/ 里的正本，dts/ 目录那份已废弃。
#   * 新增外设节点前，先去 ③ 用原厂 b_nandc.bin 扒 DTB 对照，别猜。
# =============================================================================

set -e
set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# 0) 路径定位（不依赖 CWD，兼容 CI runner 与本地手动执行）
#    $0 形如 /workdir/diy-part2.sh，用它反推仓库根，绕开 /workdir 被回收的坑
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBTARGET="cortexa7"
IMG_FILE="target/linux/sunxi/image/${SUBTARGET}.mk"

if [ -d "openwrt" ] && [ -f "openwrt/.config" ]; then
    cd openwrt
fi
[ -d "target/linux/sunxi" ] || { echo "[diy-part2] 错误：当前目录不是 OpenWrt 源码根：$PWD"; exit 1; }
[ -f "$IMG_FILE" ]          || { echo "[diy-part2] 错误：找不到 $IMG_FILE"; exit 1; }

echo "[diy-part2] 源码根 = $PWD"

# ─────────────────────────────────────────────────────────────────────────────
# 1) 校验 DTS 正本确实在仓库里
#    这里【只校验、不复制】。文件缺失直接失败，好过编译到一半才报 dtb 找不到。
# ─────────────────────────────────────────────────────────────────────────────
DTS_REL="target/linux/sunxi/files/arch/arm/boot/dts/allwinner/sun6i-a31s-mars-a31s.dts"
if [ ! -f "$DTS_REL" ]; then
    echo "[diy-part2] 错误：缺少 DTS 正本 $DTS_REL"
    echo "[diy-part2]       该文件必须由仓库提供，本脚本不负责生成或复制。"
    exit 1
fi
echo "[diy-part2] DTS 正本已就位 -> $DTS_REL"

# ─────────────────────────────────────────────────────────────────────────────
# 2) 校验内核 patch 已就位（没有它 dts 不会被编译成 dtb）
# ─────────────────────────────────────────────────────────────────────────────
PATCH_DIR="target/linux/sunxi/patches-6.12"
if ! ls "$PATCH_DIR"/*mars-a31s*.patch >/dev/null 2>&1; then
    echo "[diy-part2] 错误：$PATCH_DIR 下找不到 mars-a31s 的内核 patch"
    echo "[diy-part2]       缺它会导致 .dtb 不产出，mkits.sh 报 FATAL ERROR。"
    exit 1
fi
echo "[diy-part2] 内核 patch 已就位 -> $(ls "$PATCH_DIR"/*mars-a31s*.patch)"

# ─────────────────────────────────────────────────────────────────────────────
# 3) 注册 Device/inphic_mars-a31s（幂等：已存在则跳过，可反复执行）
#
#    插入位置 : cortexa7.mk 开头 KERNEL_LOADADDR 那一行【之后】
#    为什么必须插在前面 : image/Makefile 末尾才 `include $(SUBTARGET).mk`，
#              追加到文件尾 Make 不会再解析，设备不会出现在 TARGET_DEVICES 里。
#    为什么不用 DEVICE_DTS : 这套 Makefile 不认该变量，
#              靠 SOC := sun6i-a31s 自动拼出 sun6i-a31s-mars-a31s.dtb。
#    FitImageGzip : 已由 CI 日志实锤跑通（cp zImage -> gzip -> mkits.sh -C gzip），
#              KERNEL 链完整，这一行不要改。
# ─────────────────────────────────────────────────────────────────────────────
if grep -q 'define Device/inphic_mars-a31s' "$IMG_FILE"; then
    echo "[diy-part2] Device 定义已存在，跳过插入（幂等）"
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

# ─────────────────────────────────────────────────────────────────────────────
# 4) 自检：把关键结论打进 CI 日志
#    ★ 只验【仓库目录】的自检是假绿（旧版 ls 仓库 DTS_DIR 永远成功）。
#      必须验【构建目录】里 dtb 有没有真的产出来。
#    本步在 diy-part2 阶段内核还没编译，dtb 当然还不存在，
#    所以这里只打路径与前置条件；真正的 dtb 核验看第 5 步 / 或 make 后日志。
# ─────────────────────────────────────────────────────────────────────────────
echo "[diy-part2] ---- 插入后 cortexa7.mk 前 14 行 ----"
head -14 "$IMG_FILE"

echo "[diy-part2] ---- DTS 正本 ----"
ls -l "$DTS_REL"

echo "[diy-part2] ---- 内核 patch ----"
ls -l "$PATCH_DIR"/

# ─────────────────────────────────────────────────────────────────────────────
# 5) 构建产物核验（内核 prepare 之后内核树才存在，故此处容错，不致命）
#    预期看到: sun6i-a31s-mars-a31s.dtb
#    若此处为空 -> patch 没打上（往前翻日志找 'Applying .*mars-a31s' 那行）
# ─────────────────────────────────────────────────────────────────────────────
KDIR="$(echo build_dir/target-arm_cortex-a7+neon-vfpv4_musl_eabi/linux-sunxi_cortexa7/linux-6.12.* 2>/dev/null | awk '{print $1}')"
if [ -n "$KDIR" ] && [ -d "$KDIR/arch/arm/boot/dts/allwinner" ]; then
    echo "[diy-part2] ---- 内核树 dtb 核验: $KDIR/arch/arm/boot/dts/allwinner ----"
    ls -l "$KDIR/arch/arm/boot/dts/allwinner/" | grep -i 'mars' || echo "[diy-part2] 警告：尚未产出 mars dtb（若本步早于内核编译属正常）"
else
    echo "[diy-part2] 内核树尚未就绪，跳过 dtb 核验（属正常，make 阶段再看）"
fi

echo "[diy-part2] 完成。"
exit 0
