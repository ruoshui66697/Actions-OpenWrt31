#!/bin/bash
#
# =============================================================================
# diy-part2.sh  —  Inphic MARS A31s (sun6i-a31s) 设备注册 + DTS 注入
# =============================================================================
# 执行时机 : workflow 里 ./scripts/feeds install -a 之后、make defconfig 之前
#            （P3TERX/Actions-OpenWrt 模板的固定位置，本脚本不改这个约定）
# 仓库位置 : https://github.com/ruoshui66697/Actions-OpenWrt31
#            本仓库 fork 自 P3TERX/Actions-OpenWrt，是【编译模板仓库】
#
# ------------------------------------------------------------------------------
# 【必须搞清楚的两棵树 —— 前几轮踩坑的根因】
#   仓库 A = 本仓库 Actions-OpenWrt31
#            里面有 .config / diy-part1.sh / diy-part2.sh / dts/ / shuo.md
#            runner 把它 checkout 到 $GITHUB_WORKSPACE
#   仓库 B = coolsnowwolf/lede（由 workflow 的 REPO_URL / REPO_BRANCH 决定）
#            本脚本被 cp 进仓库 B 后执行，此时 CWD = 仓库 B 根
#
#   ★ 仓库 A 里的文件【不会】自动出现在仓库 B 里。
#     想让 lede 源码树拿到 dts，必须有人主动 cp —— 第 2 步干这件事。
#
# ------------------------------------------------------------------------------
# 【为什么不再用 kernel patch（901-mars-a31s-dts.patch 已删除）】
#   原 patch 在 CI 里报：
#     can't find file to patch at input line 25
#     No file to patch.  Skipping patch.
#     patch: **** malformed patch at line 66
#   两个原因：
#     1) patch 文件开头写了 # 注释块，patch 命令把注释当成文件名去猜
#        -> patch 文件里【一行注释都不能有】，必须从 "--- a/" 开头
#     2) 上下文行（空格开头的那几行）和内核 6.12.119 的原文不一致
#        （cubieboard5 那行、Kconfig 里 select 的顺序都对不上）
#   -> 改用第 5 步的 sed 直插：没有上下文匹配，不会 Hunk FAILED。
#
# ------------------------------------------------------------------------------
# 【本脚本做三件事】
#   1) 把仓库 A 的 dts/ 里的 dts 拷进仓库 B 的 target/linux/sunxi/files-X.Y/
#      （内核源码覆盖层；ARM 平台的 dts 目录就在这个位置下）
#   2) 在 target/linux/sunxi/image/cortexa7.mk 里注册 Device/inphic_mars-a31s
#   3) ★本次新增★ 等内核树出现后，直接往内核 dts 目录的 Makefile 插一行
#      dtb-y += sun6i-a31s-mars-a31s.dtb，让内核真的编译它
#
# ------------------------------------------------------------------------------
# 【本脚本明确不做的事 —— 踩过坑，别再加回来】
#   ✗ 不改 .config（会被紧随其后的 make defconfig 冲掉）
#   ✗ 不改 image/Config.in（设备符号由 TARGET_DEVICES 自动生成，已验证）
#   ✗ 不依赖 DEVICE_DTS 变量（这套 Makefile 不认，靠 SOC 自动拼文件名）
#   ✗ 不再校验/搬运 kernel patch（方案 B 已废弃 patch）
#
# ------------------------------------------------------------------------------
# 【维护约定】
#   * DTS 唯一正本 = 本仓库 dts/sun6i-a31s-mars-a31s.dts，改 DTS 只改它。
#   * 一次只改一个变量。红了一次只回头动一处。
#   * 新增外设节点前，先用原厂 b_nandc.bin 扒 DTB 对照，别猜。
# =============================================================================

set -e
set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# 0) 路径定位
#    SCRIPT_DIR 用 $0 反推，绕开 "/workdir 被 runner 回收"的老坑。
#    DTS 正本跟着脚本走：脚本在仓库 A 根，dts/ 也在仓库 A 根。
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DTS_NAME="sun6i-a31s-mars-a31s"
DTS_SRC="$SCRIPT_DIR/dts/${DTS_NAME}.dts"
SUBTARGET="cortexa7"
IMG_FILE="target/linux/sunxi/image/${SUBTARGET}.mk"
SUNXI_DIR="target/linux/sunxi"

# 自适应进 lede 源码根（兼容 CI 与本地手动执行）
if [ -d "openwrt" ] && [ -f "openwrt/.config" ]; then
    cd openwrt
fi
[ -d "target/linux/sunxi" ] || { echo "[diy-part2] 错误：当前目录不是 OpenWrt 源码根：$PWD"; exit 1; }
[ -f "$IMG_FILE" ]          || { echo "[diy-part2] 错误：找不到 $IMG_FILE"; exit 1; }

echo "[diy-part2] 源码根(仓库B) = $PWD"
echo "[diy-part2] 脚本目录(仓库A) = $SCRIPT_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# 1) 校验 DTS 正本存在于【仓库 A】
#    缺失就早失败，别等编译到一半才报 dtb 找不到。
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -f "$DTS_SRC" ]; then
    echo "[diy-part2] 错误：找不到 DTS 正本 $DTS_SRC"
    echo "[diy-part2]       该文件必须由本仓库 dts/ 目录提供，本脚本不生成它。"
    exit 1
fi
echo "[diy-part2] DTS 正本已找到 -> $DTS_SRC"

# ─────────────────────────────────────────────────────────────────────────────
# 2) 把 DTS 搬进仓库 B 的【内核源码覆盖层】
#    files-X.Y = 内核源码覆盖层，ARM 的 dts 目录在 files-X.Y/arch/arm/boot/dts/
#    files/    = 根文件系统覆盖层（只落到固件 /etc），不送 dts 进内核树
#    两种都探测；都不存在也不退出，靠第 5 步兜底。
# ─────────────────────────────────────────────────────────────────────────────
DTS_DST_DIR=""
for cand in "${SUNXI_DIR}/files-6.12/arch/arm/boot/dts/allwinner" \
            "${SUNXI_DIR}/files/arch/arm/boot/dts/allwinner"; do
    if [ -d "$cand" ] || mkdir -p "$cand" 2>/dev/null; then
        DTS_DST_DIR="$cand"
        break
    fi
done

if [ -n "$DTS_DST_DIR" ]; then
    cp -f "$DTS_SRC" "${DTS_DST_DIR}/${DTS_NAME}.dts"
    echo "[diy-part2] DTS 已注入内核 dts 目录 -> ${DTS_DST_DIR}/${DTS_NAME}.dts"
    ls -l "${DTS_DST_DIR}/${DTS_NAME}.dts"
else
    echo "[diy-part2] 警告：未找到可写的内核 dts 目录，将只依赖第 5 步兜底。"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3) 注册 Device/inphic_mars-a31s（幂等：已存在则跳过，可反复执行）
#
#    插入位置 : cortexa7.mk 开头 KERNEL_LOADADDR 那一行【之后】
#    为什么必须插在前面 : image/Makefile 末尾才 `include $(SUBTARGET).mk`，
#              追加到文件尾 Make 不会再解析，设备不会进 TARGET_DEVICES。
#    FitImageGzip : 已由 CI 日志实锤跑通（cp zImage -> gzip -> mkits.sh -C gzip），
#              KERNEL 链完整，这几行不要改。
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
# 4) ★方案B核心★ 往内核 dts 目录的 Makefile 直插 dtb-y 一行
#
#    为什么不用 patch：见文件头「为什么不再用 kernel patch」。
#    幂等：grep 到已有条目就跳过，反复执行不会插出重复行。
#    容错：内核树此时可能还没解压 -> 找不到就打印提示并正常结束，
#          【绝不 exit 1】，否则会把整个编译卡死在 diy-part2 阶段。
#
#    日志判读：
#      "已插入 dtb-y 条目"    -> 这一关过了，等 dtb 产出
#      "内核树尚未就绪、跳过"  -> 本脚本时机早于内核 prepare，
#                                 需要把这步挪到 yml 里 make 之前再跑一次
# ─────────────────────────────────────────────────────────────────────────────
KDIR="$(ls -d build_dir/target-arm_cortex-a7+neon-vfpv4_musl_eabi/linux-sunxi_cortexa7/linux-6.12.* 2>/dev/null | head -1)"

if [ -n "$KDIR" ] && [ -d "$KDIR/arch/arm/boot/dts/allwinner" ]; then
    K_DTS_DIR="$KDIR/arch/arm/boot/dts/allwinner"

    # 4.1 兜底：dts 文件没被 files-X.Y 覆盖进去的话，这里补一份
    if [ ! -f "$K_DTS_DIR/${DTS_NAME}.dts" ]; then
        cp -f "$DTS_SRC" "$K_DTS_DIR/${DTS_NAME}.dts"
        echo "[diy-part2] 兜底：dts 已直接拷入内核树 -> $K_DTS_DIR/${DTS_NAME}.dts"
    fi

    # 4.2 插 Makefile 条目（幂等）
    if grep -q "${DTS_NAME}.dtb" "$K_DTS_DIR/Makefile"; then
        echo "[diy-part2] Makefile 已含 ${DTS_NAME}.dtb，跳过（幂等）"
    else
        # 插在第一行 dtb-y 之前，结构最稳，不依赖任何具体上下文内容
        sed -i "0,/^dtb-y/s|^dtb-y|dtb-\$(CONFIG_MACH_SUN6I_A31S_MARS_A31S) += ${DTS_NAME}.dtb\n\ndtby-|" "$K_DTS_DIR/Makefile"
        echo "[diy-part2] 已插入 dtb-y 条目 -> $K_DTS_DIR/Makefile"
    fi

    # 4.3 顺带补 Kconfig 符号（没有它 CONFIG_MACH_..._MARS_A31S 不会为 y）
    if grep -q 'MACH_SUN6I_A31S_MARS_A31S' "$K_DTS_DIR/Kconfig"; then
        echo "[diy-part2] Kconfig 已含 MARS_A31S 符号，跳过（幂等）"
    else
        sed -i "/^config MACH_SUN6I_A31S\$/i\\
config MACH_SUN6I_A31S_MARS_A31S\\
\tbool \"Allwinner MARS A31s (Inphic MARS A31s TV Box)\"\\
\tdepends on ARCH_MULTI_V7\\
\tselect MACH_SUN6I\\
\tselect MACH_SUN6I_A31S\\
\tselect SUNXI_CCU\\
\tselect SUNXI_DEVDDB\\
\tselect SUNXI_SRAM\\
\tselect ARM_GIC\\
\thelp\\
\t  Support for Inphic MARS A31s Android TV box.\\
\\
" "$K_DTS_DIR/Kconfig" || echo "[diy-part2] 警告：Kconfig 插入失败（非致命）"
        echo "[diy-part2] 已插入 Kconfig 符号 MACH_SUN6I_A31S_MARS_A31S"
    fi

    echo "[diy-part2] ---- 内核 dts 目录实况 ----"
    ls -l "$K_DTS_DIR/" | grep -i 'mars' || echo "(暂无 mars 文件)"
else
    echo "[diy-part2] 内核树尚未就绪（KDIR=${KDIR:-空}），跳过 dtb-y 插入。"
    echo "[diy-part2] 若最终仍报 mkits 找不到 .dtb，需把第 4 步挪到 yml 里 make 之前执行。"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5) 自检：把前置条件打进 CI 日志
#    ★ 注意：本步骤运行在 make 之前，内核树多半还不存在，
#      所以 dtb 此刻没有是正常的 —— 真正的判据在编译阶段日志。
# ─────────────────────────────────────────────────────────────────────────────
echo "[diy-part2] ---- 插入后 cortexa7.mk 前 14 行 ----"
head -14 "$IMG_FILE"

echo "[diy-part2] ---- 仓库A 的 dts 目录 ----"
ls -l "$SCRIPT_DIR/dts/"

echo "[diy-part2] ---- 仓库B 的内核覆盖层 dts 目录 ----"
[ -n "$DTS_DST_DIR" ] && ls -l "$DTS_DST_DIR/" || echo "(未落盘)"

echo "[diy-part2] 完成。编译阶段请在日志里确认一条："
echo "[diy-part2]   build_dir/.../linux-6.12.*/arch/arm/boot/dts/allwinner/ 下"
echo "[diy-part2]   出现 sun6i-a31s-mars-a31s.dtb   ← 这一条出现，① 就算过关"
exit 0
