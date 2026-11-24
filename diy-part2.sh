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
#            runner 把它 checkout 到 $GITHUB_WORKSPACE (= /home/runner/work/xxx/xxx)
#   仓库 B = coolsnowwolf/lede（由 workflow 的 REPO_URL/REPO_BRANCH 决定）
#            本脚本被 cp 进仓库 B 后执行，此时 CWD = 仓库 B 根（下面会 cd 进去）
#
#   ★ 仓库 A 里的文件【不会】自动出现在仓库 B 里。
#     想让 lede 源码树拿到 dts，必须有人主动 cp —— 第 2 步干的就是这件事。
#     之前那版把 cp 删掉、只留校验，于是脚本去仓库 B 里找 dts 必然找不到，
#     报 "[diy-part2] 错误：缺少 DTS 正本"。
#
# ------------------------------------------------------------------------------
# 【本脚本做两件事】
#   1) 把仓库 A 的 dts/sun6i-a31s-mars-a31s.dts 拷进 lede 源码树的
#      target/linux/sunxi/files-X.Y/arch/arm/boot/dts/allwinner/  ← 正解位置
#   2) 在 target/linux/sunxi/image/cortexa7.mk 里注册 Device/inphic_mars-a31s
#
# 【DTS 落点为什么是 files-X.Y 而不是 files/】
#   target/linux/<target>/files/      = 根文件系统覆盖层（落到固件 /etc /sbin），
#                                       它【不会】把 .dts 送进内核源码树。
#   target/linux/<target>/files-X.Y/  = 内核源码覆盖层，ARM 平台的 dts 目录
#                                       就在 files-X.Y/arch/arm/boot/dts/ 下
#                                       （OpenWrt 官方 Adding a new device 文档原话：
#                                        "ARM devices ... typically have it located
#                                         at files-X.yy/arch/arm/boot/dts/"）
#   本脚本两种目录都探测，哪个存在用哪个；都不存在则跳过并给出提示，
#   因为此时第 3 步的 kernel patch 仍能把 dts 带进内核树（见下）。
#
# 【patches-6.12/901-mars-a31s-dts.patch 仍然必需】
#   files-X.Y 只负责把 .dts 文件放进去；内核只编译 dts 目录 Makefile 里
#   dtb-y 列出的条目。不补那一行 -> 文件在树里但不编译 -> 不产出 .dtb
#   -> mkits.sh 报 FATAL ERROR: Couldn't open ".../sun6i-a31s-mars-a31s.dtb"
#   -> make[5] Error 1 / Process completed with exit code 2   ← 你见过的那条
#
# ------------------------------------------------------------------------------
# 【本脚本明确不做的事 —— 踩过坑，别再加回来】
#   ✗ 不改 .config
#       它是本地 menuconfig 生成后提交的完整文件，由 workflow mv 进来，
#       本脚本再改会被紧随其后的 make defconfig 冲掉。
#   ✗ 不改 image/Config.in
#       设备符号由 cortexa7.mk 的 TARGET_DEVICES 自动生成，已验证。
#   ✗ 不依赖 DEVICE_DTS 变量
#       这套 Makefile 不认它，靠 SOC := sun6i-a31s 自动拼文件名。
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
#    SCRIPT_DIR 用 $0 反推，绕开 "/workdir 被 runner 回收"那个老坑。
#    DTS 正本跟着脚本走：脚本在仓库 A 根，dts/ 也在仓库 A 根，所以能拼出来。
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DTS_NAME="sun6i-a31s-mars-a31s"
DTS_SRC="$SCRIPT_DIR/dts/${DTS_NAME}.dts"
SUBTARGET="cortexa7"
IMG_FILE="target/linux/sunxi/image/${SUBTARGET}.mk"

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
#    这里必须校验：文件缺失就早失败，别等编译到一半才报 dtb 找不到。
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -f "$DTS_SRC" ]; then
    echo "[diy-part2] 错误：找不到 DTS 正本 $DTS_SRC"
    echo "[diy-part2]       该文件必须由本仓库提供（dts/ 目录），本脚本不生成它。"
    exit 1
fi
echo "[diy-part2] DTS 正本已找到 -> $DTS_SRC"

# ─────────────────────────────────────────────────────────────────────────────
# 2) 把 DTS 从仓库 A 搬进仓库 B 的内核 dts 目录  ★本次唯一新增的逻辑★
#
#    探测顺序：
#      a) target/linux/sunxi/files-6.12/arch/arm/boot/dts/allwinner  （首选）
#      b) target/linux/sunxi/files/arch/arm/boot/dts/allwinner       （兼容）
#    都不存在时不退出：内核 patch（第 3 步校验）会把 dts 带进内核树，
#    这里只打印警告，避免把两种机制绑死导致重复失败。
# ─────────────────────────────────────────────────────────────────────────────
SUNXI_DIR="target/linux/sunxi"
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
    echo "[diy-part2] 警告：未找到可写的内核 dts 目录，DTS 未落盘。"
    echo "[diy-part2]       将由 patches-6.12 的 901 号补丁负责带入内核树。"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3) 校验内核 patch 已就位
#    没有它 -> dts 即使进了源码树也不编译 -> 还是那条 FATAL ERROR。
#    注意：patch 文件在【仓库 A】，但要在仓库 B 的 patches-6.12/ 下才生效，
#    所以同样需要搬运 —— 若仓库 B 里没有、仓库 A 里有，自动补过去。
# ─────────────────────────────────────────────────────────────────────────────
PATCH_DIR_REL="target/linux/sunxi/patches-6.12"
PATCH_DIR_ABS="$SCRIPT_DIR/$PATCH_DIR_REL"

if ! ls "$PATCH_DIR_REL"/*mars-a31s*.patch >/dev/null 2>&1; then
    if ls "$PATCH_DIR_ABS"/*mars-a31s*.patch >/dev/null 2>&1; then
        mkdir -p "$PATCH_DIR_REL"
        cp -f "$PATCH_DIR_ABS"/*mars-a31s*.patch "$PATCH_DIR_REL/"
        echo "[diy-part2] 内核 patch 已从仓库A补入仓库B -> $PATCH_DIR_REL/"
    else
        echo "[diy-part2] 错误：$PATCH_DIR_REL 下找不到 mars-a31s 的内核 patch"
        echo "[diy-part2]       缺它会导致 .dtb 不产出，mkits.sh 报 FATAL ERROR。"
        exit 1
    fi
fi
echo "[diy-part2] 内核 patch 已就位："
ls -l "$PATCH_DIR_REL"/

# ─────────────────────────────────────────────────────────────────────────────
# 4) 注册 Device/inphic_mars-a31s（幂等：已存在则跳过，可反复执行）
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
# 5) 自检：把关键结论打进 CI 日志
#    ★ 只验仓库目录的自检是假绿。本步骤运行在 make 之前，内核树还不存在，
#      所以 dtb 此刻必然没有 —— 真正的 dtb 核验要等编译阶段。
#      这里只负责确认【前置条件全部到位】，编译阶段的判据见下方注释。
# ─────────────────────────────────────────────────────────────────────────────
echo "[diy-part2] ---- 插入后 cortexa7.mk 前 14 行 ----"
head -14 "$IMG_FILE"

echo "[diy-part2] ---- 仓库A 的 dts 目录 ----"
ls -l "$SCRIPT_DIR/dts/"

echo "[diy-part2] ---- 仓库B 的内核 dts 目录 ----"
[ -n "$DTS_DST_DIR" ] && ls -l "$DTS_DST_DIR/" || echo "(未落盘)"

echo "[diy-part2] ---- 仓库B 的 patches-6.12 ----"
ls -l "$PATCH_DIR_REL/"

echo "[diy-part2] 完成。编译阶段请在日志里确认两件事："
echo "[diy-part2]   1) 出现 'Applying ...901-mars-a31s...patch' 且无 Hunk FAILED"
echo "[diy-part2]   2) build_dir/.../linux-6.12.*/arch/arm/boot/dts/allwinner/ 下"
echo "[diy-part2]      出现 sun6i-a31s-mars-a31s.dtb  ← 这一条出现，① 就算过关"
exit 0
