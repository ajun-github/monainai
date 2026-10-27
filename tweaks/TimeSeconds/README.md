# TimeSeconds

让 iOS 状态栏的时间实时显示秒数：`9:41` → `9:41:07`。

- 目标系统：iOS 16 及以上
- 兼容：RootHide / Dopamine roothide、常规 rootless（Dopamine / palera1n rootless）
- 架构：arm64 + arm64e
- 无设置面板：装上即用，没有任何开关和滑块

> 2.0.0 曾经加过「设置 → 插件 → TimeSeconds」的面板（字号 / 位置 / 开关），
> 因为不好用，2.1.0 已经把它整套撤掉了，回到最初的无配置版本。

## 原理

iOS 16 的状态栏时间由 `UIKitCore` 的 `_UIStatusBarTimeItem` 驱动，
最终写到 `_UIStatusBarStringView`（`UILabel` 子类）的 `text` 上。
系统只在**分钟变化**时才刷新这个文本，所以原生只显示到分钟。

本插件：

1. hook `-[_UIStatusBarStringView setText:]` 和 `setAttributedText:`，
   把系统写进来的分钟级文本（`9:41`）记作基准 `base`；
2. 自己跑一个**对齐到整秒**的 `NSTimer`，每秒把 `base` 重新渲染成
   `9:41:07`，保留原来的 12/24 小时制分隔符和 AM/PM 后缀；
3. 给文本套上等宽数字（`kNumberSpacingType` / `MonospacedNumbersSelector`），
   字号按系统原字号收 5%（`TS_FONT_SCALE = 0.95`），
   并用负的 `NSKernAttributeName` 把字距收紧（`TS_KERN_RATIO = 0.05`），
   整体比原生窄 4~5pt，秒数跳动时宽度不抖；
4. 兜底：如果 hook 没抓到（未来系统改了类名），每秒扫一次状态栏视图树，
   找形如时间的 `UILabel` 自行接管。

字体始终从**系统原始字体**推导，并且每秒校验一次，所以：

- 系统在整分钟重写文本时不会被重复缩放（1.0.1 的隐患，已修）；
- 系统换了字体（灵动岛 pill、状态栏样式切换）会立刻跟上。

## 构建

需要 [Theos](https://theos.dev)。仓库里的 GitHub Actions 会自动构建
（`macos-14` + `Randomblock1/theos-action`），产物直接落到 `debs/`。

本地构建：

```bash
export THEOS=~/theos
cd tweaks/TimeSeconds
make package FINALPACKAGE=1
# 产物：packages/com.ajun.timeseconds_2.1.2_iphoneos-arm64.deb
```

## 安装

```bash
dpkg -i com.ajun.timeseconds_2.1.2_iphoneos-arm64.deb
killall -9 SpringBoard
```

或者直接从源里装：`https://ajun-github.github.io/monainai/`

源里会**同时保留历史版本**（2.1.0 / 2.1.1 / 2.1.2 ...），Sileo 里可以随时降级。

## 调字号 / 字距

只有源码里两个常量：

```objc
#define TS_FONT_SCALE 0.95   // 字号倍率，1.0 = 和系统原生一样大
#define TS_KERN_RATIO 0.05   // 字距收紧比例，0 = 系统默认
```

想更紧凑就调大 `TS_KERN_RATIO`（0.07 已经很挤了），想恢复默认就设 0。

改完推 `main` 会自动重编译发布。

## 已知限制

- 加了 3 个字符后时间会变宽，刘海机型左耳空间窄，可能显得紧凑；
  如果被截断，可以把状态栏字体调小或改用 24 小时制。
- 12 小时制下 `9:41:07 PM` 会比原来宽不少。
- 锁屏的大时钟不受影响（那是另一个视图，不是状态栏）。
