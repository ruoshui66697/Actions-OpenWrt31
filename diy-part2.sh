#!/bin/bash
#
# =============================================================================
# diy-part2.sh  —  Inphic MARS A31s (sun6i-a31s) 设备注册 + DTS 注入
# =============================================================================
# 执行时机 : workflow 里 "Install feeds" 之后、"Download package" 之前
#            （Load custom configuration 这一步），此时 CWD = openwrt 源码根
# 仓库位置 : https://github.com/ruoshui66697/Actions-OpenWrt31
#            本仓库 fork 自 P3TERX/Actions-OpenWrt，是【编译模板仓库】
#
# ------------------------------------------------------------------------------
# 【两棵树 —— 前几轮踩坑的根因】
#   仓库 A = 本仓库 Actions-OpenWrt31
#            .config / diy-part1.sh / diy-part2.sh / dts/ / shuo.md
#            checkout 到 $GITHUB_WORKSPACE
#   仓库 B = coolsnowwolf/lede（workflow 的 REPO_URL / REPO_BRANCH 决定）
#            本脚本被 cd 进仓库 B 后执行，CWD = 仓库 B 根
#   ★ 仓库 A 的文件不会自动出现在仓库 B 里，必须主动 cp（第 2 步）。
#     CI 日志已验证：dts 从仓库 A 找到并成功搬进 files-6.12。
#
# ------------------------------------------------------------------------------
# 【分工：脚本管什么，yml 管什么 —— 实测结论】
#   本脚本能做的（此时内核树【不存在】）：
#     - 把 dts 放进 target/linux/sunxi/files-6.12/... （内核源码覆盖层）
#     - 在 image/cortexa7.mk 注册 Device/inphic_mars-a31s
#     - 把 mac80211 构建补丁铺进 package/kernel/mac80211/patches/build/
#       （写的是仓库 B 源码树，不是 build_dir，见第 4b 步）
#   本脚本做不了的：
#     - 往内核 dts 目录 Makefile 插 dtb-y。原因：本步早于内核解压，
#       实测 KDIR=空，sed 必然跳过。已移到 yml 的
#       "Inject MARS A31s dtb-y" step（Download package 与 Compile 之间）。
#
# ------------------------------------------------------------------------------
# 【为什么不用 kernel patch（901-mars-a31s-dts.patch 已删除）】
#   原 patch 报：can't find file to patch at input line 25 /
#   patch: **** malformed patch at line 66
#   原因：1) patch 文件头写了 # 注释块，被当成文件名
#         2) 上下文行与内核 6.12.119 原文不符
#   -> 改用 yml 里 sed 直插，无上下文匹配，不会 Hunk FAILED。
#
# ------------------------------------------------------------------------------
# 【明确不做的事 —— 踩过坑，别再加回来】
#   ✗ 不改 .config（会被紧随其后的 make defconfig 冲掉）
#   ✗ 不改 image/Config.in（设备符号由 TARGET_DEVICES 自动生成，已验证）
#   ✗ 不依赖 DEVICE_DTS 变量（这套 Makefile 不认，靠 SOC 自动拼文件名）
#   ✗ 不在本脚本里插 dtb-y（时机不对，已移 yml）
#   ✗ 不再校验/搬运 kernel patch（方案 B 已废弃 patch）
#
# ------------------------------------------------------------------------------
# 【维护约定】
#   * DTS 唯一正本 = 本仓库 dts/sun6i-a31s-mars-a31s.dts，改 DTS 只改它。
#   * mac80211 补丁唯一正本 = 本仓库 patches/999-*.patch，脚本只搬运不生成。
#   * 一次只改一个变量。红了一次只回头动一处。
#   * 新增外设节点前，先用原厂 b_nandc.bin 扒 DTB 对照，别猜。
# =============================================================================

set -e
set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# 0) 路径定位（SCRIPT_DIR 用 $0 反推，绕开 /workdir 被回收的老坑）
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
# 1) 校验 DTS 正本存在于【仓库 A】；缺失就早失败，别等编译到一半才报
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -f "$DTS_SRC" ]; then
    echo "[diy-part2] 错误：找不到 DTS 正本 $DTS_SRC"
    echo "[diy-part2]       该文件必须由本仓库 dts/ 目录提供，本脚本不生成它。"
    exit 1
fi
echo "[diy-part2] DTS 正本已找到 -> $DTS_SRC"

# ─────────────────────────────────────────────────────────────────────────────
# 2) 把 DTS 搬进仓库 B 的【内核源码覆盖层】files-6.12
#    files-X.Y = 内核源码覆盖层，ARM 的 dts 目录在 files-X.Y/arch/arm/boot/dts/
#    files/    = 根文件系统覆盖层（只落到固件 /etc），不送 dts 进内核树
#    ★ 本步已由 CI 日志验证通过（18272 字节落地），不要再改路径。
# ──────────────────────────────────────────────────────────────────────验证────
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
    echo "[diy-part2] 警告：未找到可写的内核 dts 目录，将只依赖 yml 步骤兜底。"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3) 注册 Device/inphic_mars-a31s（幂等：已存在则跳过，可反复执行）
#    插入位置 : cortexa7.mk 开头 KERNEL_LOADADDR 那一行【之后】
#    为什么必须插前面 : image/Makefile 末尾才 include $(SUBTARGET).mk，
#              追加到文件尾 Make 不会再解析，设备进不了 TARGET_DEVICES。
#    FitImageGzip : 已由 CI 日志实锤跑通（cp zImage -> gzip -> mkits.sh），
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
# 4) 【已移到 yml，此处故意留空】
#
#    原第 4 步在这里往内核 dts 目录 Makefile 插 dtb-y，实测必然失败：
#    本脚本运行在 make 之前，build_dir 里还没有内核树，日志实锤 KDIR=空，
#    走"跳过"分支，dtb-y 根本没插进去，编译阶段照旧报：
#      FATAL ERROR: Couldn't open ".../allwinner/sun6i-a31s-mars-a31s.dtb"
#
#    现由 workflow 的 "Inject MARS A31s dtb-y" step 负责，位置在
#    "Download package"(make defconfig) 之后、"Compile the firmware" 之前——
#    那时内核树已解压、Makefile 已就位，sed 一插就生效。
#    —— 不要再往本脚本里加这段，时机问题无解。
# ─────────────────────────────────────────────────────────────────────────────
echo "[diy-part2] 第 4 步（dtb-y 插入）已移交 yml 的 Inject step，本脚本不处理。"

# ─────────────────────────────────────────────────────────────────────────────
# 4b) 把 mac80211 构建补丁铺进仓库 B 的源码树（patches/build/ 子目录）
#
#     ★ 这一段不是第 4 步那个 dtb-y：写的是【clone 出来的源码树】，
#       build_dir 还没解压也能写；dtb-y 写的是解压后的内核树，两者不冲突。
#
#     正本   : 仓库 A 的 patches/999-*.patch（补丁正文由仓库 A 提供，
#              本脚本只负责搬运，不生成、不拼接补丁内容）
#     落点   : package/kernel/mac80211/patches/build/
#     机制   : lede master 的 mac80211/Makefile 在 CONFIG_LINUX_6_12=y 时
#              PKG_VERSION:=6.18.39 / PATCH_DIR:=./patches；
#              Build/Patch 第 400 行
#                $(call PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/build,build/)
#              → 该目录补丁在 backports 解压后自动应用。
#              不用改 yml、不用新增 step、不碰 build_dir。
#     编号   : 999- 排现有 23 个补丁（最大 502）之后，最后应用不被覆盖，
#              避开 500 段，将来同步上游不撞名。
#
#     ★ set -e 下：正本缺失 / 落地为空 一律早失败，
#       不制造"以为铺了其实没铺"的假绿（与第 1 步 DTS 同纪律）。
#       用 999-*.patch 通配，补丁具体文件名由下一步定，本脚本不写死。
# ─────────────────────────────────────────────────────────────────────────────
PATCH_SRC_DIR="$SCRIPT_DIR/patches"
PATCH_DST_DIR="package/kernel/mac80211/patches/build"

shopt -s nullglob
PATCH_FILES=( "$PATCH_SRC_DIR"/999-*.patch )
shopt -u nullglob

if [ "${#PATCH_FILES[@]}" -eq 0 ]; then
    echo "[diy-part2] 错误：仓库 A 缺少补丁正本 $PATCH_SRC_DIR/999-*.patch"
    echo "[diy-part2]       补丁正文由仓库 A 的 patches/ 目录提供，本脚本只搬运。"
    echo "[diy-part2]       请确认 patches/999-*.patch 已提交后再跑 workflow。"
    exit 1
fi

mkdir -p "$PATCH_DST_DIR"
for f in "${PATCH_FILES[@]}"; do
    base="$(basename "$f")"
    cp -f "$f" "$PATCH_DST_DIR/$base"
    [ -s "$PATCH_DST_DIR/$base" ] || {
        echo "[diy-part2] 错误：补丁落地为空 $PATCH_DST_DIR/$base"; exit 1;
    }
    echo "[diy-part2] mac80211 补丁已铺入 -> $PATCH_DST_DIR/$base ($(stat -c%s "$PATCH_DST_DIR/$base") bytes)"
done

echo "[diy-part2] ---- 仓库B 的 patches/build/ 999 段 ----"
ls -l "$PATCH_DST_DIR"/999-*.patch
echo "[diy-part2] ---- 编译阶段请在日志确认 backports 应用了 999 段补丁 ----"

# ─────────────────────────────────────────────────────────────────────────────
# 4c) 把【内核补丁】搬进仓库 B 的 target/linux/sunxi/patches-6.12/
#
#     时机：本步在 clone 之后、make target/linux/prepare 之前运行；
#           patches-6.12 会在 prepare 时由 PatchDir 应用到解压后的内核源码。
#           这个目录是 lede 源码树自带的，不是 build_dir，时序不会踩
#           "往还没铺出来的内核树里插东西"那个老坑。
#
#     正本在仓库 A 的 kernel-patches/，用通配不写死补丁名。
#     缺正本 / 落地为空一律早失败（set -e），避免"以为铺了"的假绿。
#     不覆盖 lede 自带的 12 个补丁（本补丁编号 999，现有最大 461）。
# ─────────────────────────────────────────────────────────────────────────────
KPATCH_SRC_DIR="$SCRIPT_DIR/kernel-patches"
KPATCH_DST_DIR="target/linux/sunxi/patches-6.12"

if ls "$KPATCH_SRC_DIR"/*.patch >/dev/null 2>&1; then
    mkdir -p "$KPATCH_DST_DIR"
    cp -f "$KPATCH_SRC_DIR"/*.patch "$KPATCH_DST_DIR/"
    echo "[diy-part2] 内核补丁已铺入 -> $PWD/$KPATCH_DST_DIR"
    for f in "$KPATCH_DST_DIR"/*.patch; do
        [ -s "$f" ] || { echo "[diy-part2] 错误：补丁落地为空 $f"; exit 1; }
        echo "[diy-part2]   $(basename "$f")  $(wc -c < "$f") bytes"
    done
else
    echo "[diy-part2] 错误：仓库 A 找不到 kernel-patches/*.patch ($KPATCH_SRC_DIR)"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5) 自检：把前置条件打进 CI 日志
#    ★ 本步骤运行在 make 之前，内核树不存在、dtb 没有是正常的。
#      真正判据在编译阶段日志（见下方 echo）。
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
