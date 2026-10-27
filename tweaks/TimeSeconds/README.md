# TimeSeconds

让 iOS 状态栏的时间实时显示秒数：`9:41` → `9:41:07`。

- 目标系统：iOS 16 及以上
- 兼容：RootHide / Dopamine roothide、常规 rootless（Dopamine / palera1n rootless）
- 架构：arm64 + arm64e

## 设置面板（2.0.0 新增）

安装后：**设置 → 插件 → TimeSeconds**

| 选项 | 范围 | 默认 | 说明 |
|---|---|---|---|
| 启用秒数显示 | 开 / 关 | 开 | 关闭后立即恢复系统原生的分钟级时间 |
| 字体大小 | 60% ~ 140% | 95% | 觉得偏大往左调；数字始终等宽 |
| 水平位置 | -30 ~ +30 pt | 0 | 以系统原始位置为基准，向右为正 |
| 垂直位置 | -15 ~ +15 pt | 0 | 向下为正 |

改动**即时生效**，不需要注销或重启 SpringBoard。设置写在
`/var/mobile/Library/Preferences/com.ajun.timeseconds.plist`，
通过 Darwin 通知推给 SpringBoard；tweak 端每秒还有一次兜底轮询，
所以即使通知没送到也会在 1 秒内跟上。

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
   秒数跳动时宽度不抖；
4. 位置偏移 hook `-[_UIStatusBarStringView setFrame:]`，每次布局叠加，
   不和状态栏自己的布局打架；
5. 兜底：如果 hook 没抓到（未来系统改了类名），每秒扫一次状态栏视图树，
   找形如时间的 `UILabel` 自行接管。

系统在整分钟时会重写文本，`refreshAll` 会自动跟上新的基准，不会越跑越偏。

## 构建

需要 [Theos](https://theos.dev)。仓库里的 GitHub Actions 会自动构建
（`macos-14` + `Randomblock1/theos-action`），产物直接落到 `debs/`。

```bash
export THEOS=~/theos
cd tweaks/TimeSeconds
make package FINALPACKAGE=1
# 产物：packages/com.ajun.timeseconds_2.0.0_iphoneos-arm64.deb
```

一个 deb 里同时包含：

```
var/jb/Library/MobileSubstrate/DynamicLibraries/TimeSeconds.dylib
var/jb/Library/MobileSubstrate/DynamicLibraries/TimeSeconds.plist
var/jb/Library/PreferenceBundles/TimeSecondsPrefs.bundle/
```

## 安装

```bash
dpkg -i com.ajun.timeseconds_2.0.0_iphoneos-arm64.deb
killall -9 SpringBoard
```

或者直接从源里装：`https://ajun-github.github.io/monainai/`

设置面板依赖 `preferenceloader`（RootHide / Dopamine 默认仓库里有），
本包把它列为 `Recommends`，没装的话插件本体仍然工作，只是没有设置入口。

## 已知限制

- 加了 3 个字符后时间会变宽，刘海机型左耳空间窄可能偏紧，
  可以用「字体大小」调小，或用「水平位置」微调。
- 12 小时制下 `9:41:07 PM` 会比原来宽不少。
- 锁屏的大时钟不受影响（那是另一个视图，不是状态栏）。
- 位置偏移只作用于状态栏时间视图，不影响其他状态栏元素。
