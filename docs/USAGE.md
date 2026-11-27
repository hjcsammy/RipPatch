指南

把 Unity 游戏导出成「能在 Unity 里打开、能跑起来」的工程。

本文面向**使用者**。想了解实现原理、补丁写法、代码结构，看 [README](../README.zh.md)；
想脚本化调用 HTTP 接口，看 [JSON API](json-api.md)。

---

## 目录

1. [最快路径](#1-最快路径)
2. [导出游戏](#2-导出游戏)
3. [浏览与预览](#3-浏览与预览)
4. [导出单个文件](#4-导出单个文件)
5. [界面](#5-界面)
6. [命令速查](#6-命令速查)
7. [环境要求](#7-环境要求)
8. [出问题怎么办](#8-出问题怎么办)

---

## 1. 最快路径

前提：**Windows 10/11 x64**，能上网。

**双击仓库根目录的 `启动.cmd`**（或 `Start.cmd`，两个是同一份）。

第一次双击会自动做完：环境检查 → 补装缺失的 .NET 10 SDK → 拉取依赖 → 编译 → 打开界面。
之后再双击就是直接打开界面，几秒。

出错时窗口不会一闪而过，会停住等你按 Enter，并列出常见原因。

> 如果 PowerShell 拦截脚本执行，用这个形式：
> `powershell -ExecutionPolicy Bypass -File .\启动.ps1`

下载中断了也没关系：**支持断点续传**，重跑同一条命令会接着下。

---

## 2. 导出游戏

### 桌面界面（默认）

```
双击 启动.cmd
```

| 步骤 | 操作 |
|---|---|
| 导入 | 「选择游戏目录」选游戏根目录，或「选择单个文件」选 `.apk` / `.xapk` / `.assets` 等 |
| 等待 | 进度条走完 |
| 检查 | 左侧按类型浏览，右侧看图片 / 模型 / 文本 / 音频 |
| 导出 | 「导出」→ 选输出目录 → 开始 |

**该选哪一层**——游戏在 `D:\Games\MyGame\`，里面长这样：

```
MyGame\
  MyGame.exe
  MyGame_Data\      ← 有这个文件夹，就选 MyGame 这一层
```

### 命令行导出

适合批量、脚本、CI。不需要开着界面：

```powershell
.\tools\arp.ps1 run "D:\Games\MyGame" "D:\Exports\MyGame"
```

- 全部补丁自动生效，不需要额外开关
- 退出码：`0` 成功，`1` 失败
- 日志写在程序目录的 `RipPatch.Headless.log`

### 只导出某些类型

大游戏全量导出要十几分钟。调试或只要某几类资源时：

```powershell
# 只要 Sprite 和 Texture2D（默认会连它们引用的依赖一起导出）
.\tools\arp.ps1 run "D:\Games\MyGame" "D:\Exports" -Only "Sprite,Texture2D"

# 通配符
.\tools\arp.ps1 run "D:\Games\MyGame" "D:\Exports" -Only "Sprite*"
```

界面的「导出」页里也有同样的筛选，常用类型可以点标签直接选。

筛选的效果很显著，实测同一个包：

| | 全量 | 只导 `Shader` |
|---|---|---|
| 文件数 | 53,472 | 103 |
| 大小 | 1.2 GB | 2.5 MB |
| 耗时 | ~15 分钟 | ~1 分钟 |

### ⚠️ 输出目录会被清空

**整包导出会先删除输出目录里的所有内容**，这是为了不混入上次的残留。

程序会拒绝这些危险位置：盘符根目录、桌面、用户主目录、系统目录。

但它**拦不住「你选了一个平时放别的东西的文件夹」**。所以请始终导出一个**专用空文件夹**，
例如 `D:\Exports\游戏名`。

> 删除不进回收站，不可恢复。

---

## 3. 浏览与预览

### 两种视图

工具栏右侧可切换**列表** / **网格**：

- **列表**：信息密度高，适合按名称、大小、类型筛选
- **网格**：缩略图墙，适合找图（透明图片有棋盘格底衬）

切换会被记住，下次打开还是你习惯的那个。

### 3D 模型预览

选中 `Mesh` 类型，在「预览」标签里直接画出模型：

- **拖动**旋转，**滚轮**缩放
- 需要原始文件时点「下载 GLB 模型」

用的是内置的轻量 WebGL 渲染器，不依赖任何第三方库。
压缩或加密过的 mesh 会显示「无法预览」，这时只能下载 GLB 看原文件。

### 搜索

搜索框支持多关键词（空格分隔，全部命中才显示），匹配范围包括：
资源名、类名、集合名、原始路径。

配合左侧的类型筛选可以快速收敛到目标资源。

---

## 4. 导出单个文件

在资源列表里**右键**任意一行 →「导出这个文件」。

| 资源类型 | 导出的文件 |
|---|---|
| 图片 | `.png` |
| 模型 | `.glb` |
| 音频 | 原格式 |
| 视频 | `.mp4` |
| 字体 | `.ttf` |
| 文本 | `.txt` |
| 其它 | `.bin`（原始字节） |

选一个文件夹，里面就多出一个文件。**不会生成 `.meta`，也不会生成整个 Unity 工程**。
需要完整工程请用正常导出。

### 批量导出

在列表或网格里 **Ctrl+点击**多选（支持 **Shift** 连选），底部会弹出操作条：

```
已选 12 项                      [导出所选] [取消选择]
```

逐个导出到同一个文件夹。**部分失败会如实报告失败项，并保持选中，方便直接重试。**

### 安全约定

单文件导出**不会删除任何东西**：

- 只新增一个文件，不删目录、不删已有文件
- 同名文件不覆盖，自动变成 `名字 (1).png`
- 拒绝桌面、用户主目录、盘符根、系统目录

---

## 5. 界面

### 主题

点标题栏右上角的圆形图标循环切换：

```
跟随系统 → 深色 → 浅色 → 跟随系统 …
```

- **跟随系统**（默认）：Windows 切换深浅色时界面实时跟着变
- 手动选择后会一直保持，重启也记得

### 语言

点标题栏的「中文 / English」切换，选择同样会记住。

### 浏览器模式

界面同时提供浏览器入口，用于调试或 WebView2 不可用时：

```powershell
.\tools\arp.ps1 build
RipPatch\bin\Release\net10.0\RipPatch.exe --web --port 5199 --no-open
```

启动后会打印 `WEB_UI_URL=http://127.0.0.1:5199/`，用任意浏览器打开即可。
窗口和浏览器跑的是**同一套代码**，所以界面出问题时可以在这里复现并开 DevTools。

---

## 6. 命令速查

```powershell
.\tools\arp.ps1                 # 检查 + 构建 + 启动界面（最常用）
.\tools\arp.ps1 setup           # 检查 + 构建，不启动
.\tools\arp.ps1 doctor          # 只体检，不动任何文件
.\tools\arp.ps1 build           # 只编译
.\tools\arp.ps1 restore         # 只拉依赖 + 还原 NuGet
.\tools\arp.ps1 publish         # 发布自包含目录
.\tools\arp.ps1 package         # 发布 + 打包成 zip（用于分发）
.\tools\arp.ps1 run             # 构建后启动界面
.\tools\arp.ps1 run <游戏> <输出>  # 命令行导出
.\tools\arp.ps1 clean           # 清掉 bin/obj/publish（子模块源码保留）
.\tools\arp.ps1 help            # 脚本自己的帮助
```

常用参数：

| 参数 | 作用 |
|---|---|
| `-Only "Sprite,Texture2D"` | 只导指定类型（仅 `run <游戏> <输出>` 有效） |
| `-Configuration Debug` | 用 Debug 构建（默认 Release） |
| `-Force` | 强制重下依赖 / `run` 时强制重建 |
| `-NoRestore` | 跳过 NuGet 还原 |
| `-Skip submodules,sdk` | 跳过某一步（`sdk` = 不自动装 .NET） |
| `-Quiet` | 少输出 |

### 分发给别人

```powershell
.\tools\arp.ps1 package
# → RipPatch-1.0.0-win-x64.zip（约 107 MB）
```

解压后双击 `RipPatch.exe` 即可，**目标机器不需要装 .NET**。

注意：

- **整个 `RipPatch\` 文件夹要一起发**，不要只给 exe —— 依赖、`wwwroot` 界面资源、
  `licenses` 都在旁边
- 包内已排除 `.pdb` 调试符号
- 按 GPL-3.0，分发二进制时**必须一并提供源码**（见 [第三方声明](THIRD-PARTY-NOTICES.md)）

> **为什么不是单个 exe？** 技术上做不到：本项目依赖 Harmony 做运行期补丁，
> 而 Harmony 需要从磁盘加载 `clrjit.dll` 才能生成 IL stub，它找这个库的方式
> 不兼容单文件打包模式。实测单文件版本启动即崩溃
> （`PlatformNotSupportedException: Could not locate clrjit library`），
> 手动把 clrjit.dll / coreclr.dll 放到旁边也无效。所以采用「目录 + zip」。
### 直接调用程序

不看脚本，直接调 exe 时的开关：

| 参数 | 作用 |
|---|---|
| 无参数 | 打开桌面窗口 |
| `--web` | 用默认浏览器打开 |
| `--port 5199` | 固定端口（默认随机） |
| `--no-open` | 不自动开窗口/浏览器，当后台服务跑 |
| `--legacy-ui` | 回退到上游原版 Web UI |
| `--only <类型>` | 只导出指定类型（命令行导出时） |
| `--only-strict` | 配合 `--only`：只留匹配项，不跟依赖 |
| `--shader-asm` | 额外导出 DXBC 等原始 shader 子程序 |
| `--remove-packaged-dlls` | 删掉其实是 UPM 包产物的裸 DLL（**会断引用，慎用**） |

---

## 7. 环境要求

| 项 | 要求 | 缺了会怎样 | 怎么补 |
|---|---|---|---|
| 系统 | Windows 10 1703+ / 11，x64 | 跑不起来 | — |
| PowerShell | 5.1（系统自带） | — | — |
| .NET SDK | **10.0** | 编译失败 | `arp.ps1` 会自动装，或手动装 |
| WebView2 运行时 | 任意新版 | 窗口自动降级成浏览器，命令行不受影响 | 装 Edge WebView2 Runtime |
| 网络 | 能访问 `github.com`、`api.nuget.org`、`builds.dotnet.microsoft.com` | 拉依赖 / 装 SDK / 还原失败 | 配代理 |
| 磁盘 | 约 5 GB 空闲 | 编译或发布中断 | — |
| Git | **不需要** | — | — |

> 从 GitHub 下载的压缩包没有 `.git`，`git submodule update` 会报
> `not a git repository`。`arp.ps1` 按版本直接下载源码压缩包铺到子模块目录，
> 两种情况都适用。

---

## 8. 出问题怎么办

先体检：

```powershell
.\tools\arp.ps1 doctor
```

| 现象 | 原因 | 处理 |
|---|---|---|
| `NETSDK1045: 当前 .NET SDK 不支持 net10.0` | 没装 10.0 SDK | `arp.ps1 build` 会自动装 |
| `MSB4068: 无法识别元素 <Solution>` | PATH 上的 `dotnet` 是旧版，`.slnx` 需要 9.0+ | 脚本会自动挑对的；doctor 会打印该用哪个 |
| `CS1061` / `CS1501`，缺 `DxbcPrograms` | `ShaderRipper/` 是 v1.2.4（太旧） | `arp.ps1 build` 会识别并换成 v1.2.5 |
| `CS0122: 不可访问` | ShaderRipper 的 `InternalsVisibleTo` 没匹配上程序集名 | 确认用的是 `RipPatch` 这个程序集名 |
| 导出秒失败：`same key has already been added` | 同一个 Sprite 被两张图集纹理引用 | 已由「Sprite 归属」补丁修复；确认用最新版本 |
| 导出目录被拒绝 | 护栏：桌面 / 盘符根 / 用户目录 | 换一个专用子文件夹 |
| 双击 exe 闪退 | 缺 WebView2 | 装 WebView2，或改用 `--web` |
| 界面空白 | `wwwroot` 没跟 exe 放一起 | 拷整个目录，别只拷 exe |
| 导出后 Unity 里脚本全是 `Missing (Mono Script)` | IL2CPP 元数据被加密，或 DLL 被删 | 见 [已知限制](../README.zh.md#已知限制) |
| 想从头再来 | 产物乱了 | `.\tools\arp.ps1 clean` 后重跑 |

### 导出结果为空的 Prefab / 看不到 UI

如果不是配置问题，通常是 **IL2CPP 元数据被加密**：`global-metadata.dat` 的 magic 不是
`AF 1B B1 FA`。此时资源能导出，但脚本类为空，Prefab 里的组件引用找不到类。

可以用这段命令确认：

```powershell
# 从 apk 里取出 metadata，看前 4 字节
# 正常应该是 AF 1B B1 FA
```

这是数据源的问题，工具层面解决不了。

---

## 自己构建一个可分发的包

维护者发布版本时用的自动化脚本不包含在本仓库里。你自己打包只需要一条命令：

```powershell
.\tools\arp.ps1 package
```

产物在仓库根目录：`RipPatch-<版本>-win-x64.zip`（约 107 MB）。

版本号在 `RipPatch/RipPatch.csproj` 的 `<Version>` 里改。

## 附：脚本做了什么

`tools/arp.ps1` 不含魔法，每一步都能手动对应：

```powershell
git submodule update --init --recursive     # 没有 git 时用源码压缩包代替
dotnet restore RipPatch.slnx
dotnet build   RipPatch.slnx -c Release
dotnet publish RipPatch/RipPatch.csproj -c Release -r win-x64 --self-contained true
```

区别在于它会判断每一步要不要做、缺的环境自动补、出错时说清楚缺什么。
想读明白某个命令，直接看 [tools/arp.ps1](../tools/arp.ps1)，带中文注释。

> 手动跑上面几条时，确保 `dotnet` 是 **10.0 那个**。机器上同时装了 8.0 时，
> PATH 通常指向旧版，会报 `MSB4068` 或 `NETSDK1045`。
