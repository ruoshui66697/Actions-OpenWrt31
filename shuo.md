
# Mars A31s 接入 Actions-OpenWrt 的放置方案

## 一、先回答你的核心疑问：这仓库没源码，DTS 写哪？

你看到的 `Actions-OpenWrt31` 是一个**编译流水线**，本身不含 OpenWrt 源码。
源码是在 GitHub Actions 跑起来的那一刻，由 yml 里的这两行现拉下来的：

```
REPO_URL:   https://github.com/coolsnowwolf/lede
REPO_BRANCH: master
```

也就是说：你往仓库里提交任何"源码级"文件，单独放着是不会生效的，
因为编译器拉的是 `coolsnowwolf/lede` 那份代码，不是你的仓库。

这套框架提供了两个**自定义脚本钩子**，在拉到源码之后、开始编译之前插入执行：

| 钩子 | 执行时机 | 典型用途 |
| :--- | :--- | :--- |
| `diy-part1.sh` | `feeds update` 之前 | 改 feeds 源、加第三方软件包 |
| `diy-part2.sh` | `feeds install` 之后、`make defconfig` 之前 | **改源码树、放 DTS、加设备定义、改 target 配置** |

**所以 DTS 的正确归宿是：通过 `diy-part2.sh` 把它复制进源码树。**
注意仓库根目录那个 `files/` 目录是另一回事——它是 OpenWrt 的 **rootfs 覆盖目录**，
放进去的文件会被打进最终固件的文件系统，**不是**塞进源码树编译。DTS 绝不能放 `files/`。

## 二、最终目录结构（提交到你的仓库后）

```
Actions-OpenWrt31/
├── .github/workflows/openwrt-builder.yml   # 基本不用动（见第四节）
├── .config                                 # 模板自带，target 由脚本改写，可不动
├── diy-part1.sh                            # 保持原样
├── diy-part2.sh                            # 【替换成我给你的这份】
├── diy-part2.sh 同级 ↓
└── dts/
    └── sun6i-a31s-mars-a31s.dts            # 【新增这个文件夹和文件】
```

要做的两件事：
1. 把我给的 `sun6i-a31s-mars-a31s.dts` 放进仓库的 `dts/` 文件夹；
2. 用我给的 `diy-part2.sh` 覆盖仓库里原来的同名文件。

提交后到仓库的 Actions 页手动点 "Run workflow" 触发编译即可。

## 三、diy-part2.sh 在源码里到底干了什么

| 步骤 | 动作 | 落到源码树哪个位置 |
| :--- | :--- | :--- |
| 1 | 复制 DTS | `target/linux/sunxi/files/arch/arm/boot/dts/` |
| 2 | 追加设备定义 | `target/linux/sunxi/image/` 下含 `define Device/allwinner` 的那个 .mk 末尾 |
| 3 | 改写编译目标 | `openwrt/.config` 里写入 sunxi/cortexa7/mars_a31s 三行 |

第 1 步为什么放 `target/linux/sunxi/files/`：OpenWrt 在内核 prepare 阶段，
会把 `target/linux/<target>/files/`（以及 `files-<内核版本>/`）里的内容，
按相同相对路径拷进 `build_dir` 里真正编译的内核源码树。这是**最不挑内核版本**的注入点，
不用猜当前源码是 5.10 还是 6.x。

## 四、yml 要不要改？—— 取决于内核版本，这是唯一的坑

你前几轮想把内核锁在 5.10。但 `coolsnowwolf/lede` 的 `master` 分支内核较新，
而且 sunxi 这个 target 在 lean 里是否保留完整、子目标名是否就是 `cortexa7`，都需现场确认。
给你两条路：

**路线 A：先按现状直接试编（最省事）**
- yml 一字不改，保持 `REPO_URL=coolsnowwolf/lede` + `REPO_BRANCH=master`。
- 若 Actions 编译通过且生成了 `sunxi/cortexa7` 目录下的固件，皆大欢喜。
- 若报错，把日志发我，多半是"找不到 mars_a31s profile"或子目标名不对，按提示改。

**路线 B：换官方源码，锁定内核 5.10（最稳，推荐用于 A31s 这种老平台）**
- 把 yml 里两行改成官方 OpenWrt 21.02 分支（内核 5.10，sunxi 支持完整）：
```
REPO_URL:    https://github.com/openwrt/openwrt
REPO_BRANCH: openwrt-21.02
```
- 其余 dts/ 与 diy-part2.sh 不用动（注入逻辑对官方源码同样适用）。
- 代价：没有 lean 自带的丰富插件，需要自己往 `.config` 或 `feeds` 里加。

> 说明：本次给的 DTS 用的是 `sun6i-a31.dtsi` 里稳定的节点 label（gmac / ehci1 / mmc0 / nandc），
> 这些在 5.10 到 6.x 主线里基本一致，因此路线 A、B 都能直接复用。

## 五、可能报错点速查

| 报错 | 含义 | 处理 |
| :--- | :--- | :--- |
| 找不到 mars_a31s profile | image 定义没注册成功 | 看 diy-part2 日志有没有打印"已注册到 xxx.mk" |
| 子目标名不对 | cortexa7 名字对不上 | 用 `make kernel_menuconfig`/`make menuconfig` 看实际子目标名，改脚本第 3 步 |
| DTS 编译报语法错 | 内核里节点 label 或 include 名变了 | 把报错发我，按当前内核改 dts |

先走路线 A 编一次，把 Actions 的完整日志发我，再决定要不要切路线 B。
