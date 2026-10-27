# monainai

一个可以直接托管在 GitHub Pages 上的越狱源（APT 平铺仓库），Sileo / Zebra / Cydia 通用。

> 仓库：`ajun-github/monainai`

源地址：`https://ajun-github.github.io/monainai/`

---

## 目录说明

| 路径 | 作用 | 要不要改 |
|---|---|---|
| `debs/` | 放你的 `.deb` 安装包 | **只往这里丢文件** |
| `Packages` | 索引，脚本生成 | 不要手改 |
| `Packages.gz` / `.bz2` | 索引的压缩版 | 不要手改 |
| `Release` | 源名称、架构声明 | 改一次即可 |
| `CydiaIcon.png` | 源图标（512×512） | 想换就换 |
| `build_repo.py` | 本地构建脚本 | 一般不用改 |
| `.github/workflows/build-repo.yml` | push 后自动重建索引 | 不用改 |
| `.nojekyll` | 告诉 Pages 别用 Jekyll 处理 | 必须有，别删 |

---

## 一、改源名称（一次）

编辑 `Release`，把 `Origin` / `Label` 改成你想要的显示名：

```
Origin: My Tweaks
Label: My Tweaks
```

Sileo 里显示的源名字就是这两个字段。

---

## 二、发布到 GitHub Pages

```bash
# 1. 在 GitHub 上新建一个 public 仓库，名字叫 monainai（或任意）

# 2. 本地初始化并推送
git init
git add -A
git commit -m "init: jailbreak repo"
git remote add origin https://github.com/ajun-github/monainai.git
git push -u origin main
```

然后到仓库 **Settings → Pages**：

- Source: `Deploy from a branch`
- Branch: `main` / `/ (root)`
- 点 **Save**

等 1~2 分钟，访问 `https://ajun-github.github.io/monainai/Packages`，
能下载到一个（可能为空的）文本文件就说明成功了。

> 第一次部署时 `Packages` 是空的，属正常。丢一个 deb 进去就会自动有内容。

---

## 三、加一个包

```bash
# 1. 把 deb 放进 debs/
copy 你的包.deb debs\

# 2. 本地重建索引
python build_repo.py

# 3. 推送
git add -A
git commit -m "add: com.example.tweak 1.0"
git push
```

push 之后 GitHub Actions 会**自动再跑一次** `build_repo.py` 并提交索引，
所以第 2 步其实可以省略 —— 本地跑只是让你先看到解析结果对不对。

### 在 Sileo 里添加

源 → 右上角 `+` → `https://ajun-github.github.io/monainai/` → 添加。

---

## 四、本地构建脚本

```bash
python build_repo.py          # 生成 Packages / .gz / .bz2
python build_repo.py --check  # 只检查 deb，不写文件
```

它会自动：

- 解析每个 deb 的 `control`（支持 gzip / xz / lzma / zstd 压缩）
- 算出 `Size` / `MD5sum` / `SHA1` / `SHA256`
- 写入 `Filename: debs/xxx.deb`
- 检查 `Architecture` 是否是合法 iOS 架构
- 按包名 + 版本排序（保证 diff 干净）

输出示例：

```
发现 1 个 deb，成功解析 1 个
   com.example.demo    1.0.2    iphoneos-arm64
已写出 Packages / Packages.gz / Packages.bz2  (546 字节索引)
```

---

## 五、常见问题

**Sileo 添加后提示「无法读取源」**

1. 打开 `https://ajun-github.github.io/monainai/Packages` 看能不能下载
2. 打不开 → Pages 还没部署好，或分支/目录选错了
3. 能下载但报错 → `Packages` 格式坏了，重新跑 `python build_repo.py`

**加了新包但 Sileo 看不到**

- GitHub Pages 有 5~10 分钟 CDN 缓存，等一会儿再刷新
- 或者确认 `Packages` 里已经有新包的 `Package:` 行（直接打开网页看）

**Architecture 警告**

必须是以下之一：

- `iphoneos-arm64` —— rootless（Dopamine / palera1n rootless）
- `iphoneos-arm64e` —— arm64e 设备
- `iphoneos-arm` —— 老式 rootful（iOS 14 及以前）

写成 `arm64` / `aarch64` 都会装不上。

**deb 上传到 GitHub 有什么限制**

- 单文件 100 MB
- 站点总计 1 GB（软限制）
- 仓库必须 public（免费账号）

**想加截图 / 详细说明**

在 `control` 里加：

```
Depiction: https://你的介绍页
SileoDepiction: https://你的sileo-depiction.json
Icon: https://图标地址.png
```

`SileoDepiction` 需要按 Sileo 的 JSON 规范写，比较复杂；
`Depiction` 放一个普通网页就够了，Sileo 会内嵌显示。

---

## 六、这个源合法吗 / 安全吗

- GitHub Pages 只托管静态文件，**不执行任何代码**
- 你上传什么，客户端就下载什么，所以**只放你自己打的包**
- 不要在这个仓库里放别人的付费插件（版权问题，会被 DMCA 下架）
- 不需要 GPG 签名，Sileo 会在源页面标注「未签名」，属正常
