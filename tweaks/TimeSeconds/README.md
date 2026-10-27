# TimeSeconds

让 iOS 状态栏的时间实时显示秒数：`9:41` → `9:41:07`。

- 目标系统：iOS 16 及以上
- 兼容：RootHide / Dopamine roothide、常规 rootless（Dopamine / palera1n rootless）
- 架构：arm64 + arm64e

## 原理

iOS 16 的状态栏时间由 `UIKitCore` 的 `_UIStatusBarTimeItem` 驱动，
最终写到 `_UIStatusBarStringView`（`UILabel` 子类）的 `text` 上。
系统只在**分钟变化**时才刷新这个文本，所以原生只显示到分钟。

本插件：

1. hook `-[_UIStatusBarStringView setText:]` 和 `setAttributedText:`，
   把系统写进来的分钟级文本（`9:41`）记作基准 `base`；
2. 自己跑一个**对齐到整秒**的 `NSTimer`，每秒把 `base` 重新渲染成
   `9:41:07`，保留原来的 12/24 小时制分隔符和 AM/PM 后缀；
3. 兜底：如果 hook 没抓到（未来系统改了类名），每秒扫一次状态栏视图树，
   找形如时间的 `UILabel` 自行接管。

系统在整分钟时会重写文本，`refreshAll` 会自动跟上新的基准，不会越跑越偏。

## 构建

需要 [Theos](https://theos.dev)。仓库里的 GitHub Actions 会自动构建
（`macos-14` + `Randomblock1/theos-action`），产物直接落到 `debs/`。

本地构建：

```bash
export THEOS=~/theos
cd tweaks/TimeSeconds
make package FINALPACKAGE=1
# 产物：packages/com.ajun.timeseconds_1.0.0_iphoneos-arm64.deb
```

## 安装

```bash
dpkg -i com.ajun.timeseconds_1.0.0_iphoneos-arm64.deb
killall -9 SpringBoard
```

或者直接从源里装：`https://ajun-github.github.io/monainai/`

## 已知限制

- 加了 3 个字符后时间会变宽，刘海机型左耳空间窄，可能显得紧凑；
  如果被截断，可以把状态栏字体调小或改用 24 小时制。
- 12 小时制下 `9:41:07 PM` 会比原来宽不少。
- 锁屏的大时钟不受影响（那是另一个视图，不是状态栏）。
