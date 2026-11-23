#!/bin/bash
#
# diy-part1.sh
# 执行时机：feeds update -a 之前（此时源码刚 clone 完，feeds 还没拉）
# 本文件只干一件事：让 feeds 拉得稳、拉得快
#
# 【和设备的分工】
#   本文件  → 只管 feeds 从哪拉、怎么拉（跟 A31s 无关）
#   part2   → 注入 DTS + 插 Device 块（设备相关，全在那）
#   .config → 决定编什么架构（已是 7840 行 sunxi 配置）
#
# 【幂等】重复执行不会产生 ghproxy.net/https://ghproxy.net/ 这种套娃 URL

set -e

echo "[diy-part1] ===== 开始 ====="

# ==========================================================
# ① 放开 git 低速超时
#    很多 "GnuTLS recv error (-110)" 其实是【慢】不是【断】，
#    git 默认低速等 120 秒就放弃，放开放它自己慢慢拉完。
#    这条不管走不走镜像都有用，纯增益。
# ==========================================================
git config --global http.lowSpeedLimit 0
git config --global http.lowSpeedTime 999999
echo "[diy-part1] git 低速超时已放开"

# ==========================================================
# ② feeds 源换加速前缀
#    ⚠ 镜像域名会失效，改这里一个变量就够，别在 sed 里写死
# ==========================================================
MIRROR="https://ghproxy.net/https://github.com"
FEEDS_CONF="feeds.conf.default"

if [ ! -f "$FEEDS_CONF" ]; then
    echo "[diy-part1] 警告：$FEEDS_CONF 不存在，跳过（可能已被 yml 的 mv 替换）"
else
    # 幂等判断：已经改过就不再套一层
    if grep -q "$MIRROR" "$FEEDS_CONF"; then
        echo "[diy-part1] 已是加速地址，跳过（幂等）"
    else
        # 只匹配 https://github.com/，http 和已加速的不动
        sed -i "s#https://github.com/#${MIRROR}/#g" "$FEEDS_CONF"
        echo "[diy-part1] feeds 源已换加速前缀"
    fi

    echo "[diy-part1] ---- 当前 feeds.conf.default ----"
    cat "$FEEDS_CONF"
    echo "[diy-part1] --------------------------------"
fi

# 顺带打一下源码自带的那份（万一 yml 用 mv 覆盖过，能看到效果）
echo "[diy-part1] ===== 结束 ====="
exit 0
