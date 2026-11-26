<div align="center">

<img src="Assets/icons/icon-256.png" width="120" alt="RipPatch">

<h1>RipPatch</h1>

<p><strong>把 Unity 游戏资源还原成可以直接打开的工程</strong></p>

<p>
  <a href="#快速开始">快速开始</a> ·
  <a href="#功能">功能</a> ·
  <a href="#修复了什么">修复了什么</a> ·
  <a href="#文档">文档</a> ·
  <a href="#构建">构建</a>
</p>

</div>

---

RipPatch 在 [AssetRipper](https://github.com/AssetRipper/AssetRipper) 的导出流程上做增强。

AssetRipper 把游戏资源「搬」成工程，但那是**数据搬运，不是语义还原**——很多资源依赖
编辑器在导入时重新计算的东西，原样搬运就是错的或缺失的。RipPatch 把这些补齐：
导出的工程不是「能打开但跑不起来」，而是真的能编辑、能编译。

> 这是第三方工具，**不是 AssetRipper 的官方版本**，与上游项目没有隶属关系。

## 快速开始

**不需要预装 .NET，也不需要 git。**

```
双击 启动.cmd
```

第一次双击会自动准备环境、拉取依赖、编译（约 2–5 分钟）；之后再双击直接打开界面（几秒）。
出错时窗口会停住显示原因，不会一闪而过。

偏好命令行的等价做法：

```powershell
.\tools\arp.ps1                    # 检查 + 构建 + 打开界面
.\tools\arp.ps1 run <游戏> <输出>   # 命令行导出，不开界面
.\tools\arp.ps1 doctor             # 只体检，不改动任何东西
```

详细步骤、参数与排错见 **[使用指南](docs/USAGE.md)**。

## 功能

### 浏览与预览

- 按名称 / 类型 / 集合搜索，支持多关键词
- **列表**与**缩略图网格**两种视图，网格视图一屏可扫几十张图
- 图片、音频、视频、字体预览
- **3D 模型预览**：拖拽旋转、滚轮缩放，无需任何第三方库

### 导出

| 方式 | 说明 |
|---|---|
| 整包导出 | 导出完整工程，可按类型筛选 |
| 右键单文件 | 直接把一个资源存成 png / glb / wav / txt… |
| 批量导出 | 多选后一次导出，失败项自动保留供重试 |

### 界面

中英双语；深色 / 浅色 / **跟随系统**主题；桌面原生窗口或浏览器模式。

## 修复了什么

| 补丁 | 修复的问题 |
|---|---|
| **Shader** | 用内置反编译器替代占位 shader，输出可编译的 ShaderLab |
| **Sprite 网格** | Tight 网格缺失时，按 Unity 的算法重新生成 vertices/indices |
| **Sprite 轮廓** | 修复 `outline` / `physicsShape` 坐标系错位、`m_Pivot` 越界、Single/Multiple 模式误判 |
| **Sprite 归属** | 同一个 Sprite 被两张图集纹理引用时导出会崩溃，改为只归第一张 |
| **纯 alpha 纹理** | `Alpha8` 导出成白底透明图，而不是全黑 |
| **旧版动态字体** | 清掉悬空图集引用，让 Unity 重新渲染 |
| **脚本引用** | 补齐 `Plugins/` 与 `Packages/manifest.json` 里缺失的条目 |
| **资源去重** | 内容相同的资源只导一份，其余改写成引用，不产生 Missing |
| **MonoBehaviour 容错** | 结构不匹配时宽松读取并重试，日志限流 |
| **TypeTree 容错** | 没有 C# 类接管的资源逐字段恢复，不再整条作废 |
| **临时目录** | 清理上游导入残留的临时目录，避免占用几个 GB |

## 已知限制

**IL2CPP 元数据被加密的包无法还原脚本。**
如果 `global-metadata.dat` 的开头不是 `AF 1B B1 FA`，说明它被保护过。此时资源能正常导出，
但脚本类会是空的，Prefab 里的组件引用找不到对应类，UI 显示不出来。这是数据源的问题，
工具层面无法解决。

**无法打包成单个 exe。**
本项目依赖 Harmony 做运行期补丁，而 Harmony 需要从磁盘加载 `clrjit.dll` 生成 IL stub，
这个查找过程不认单文件打包的解压目录。发布方式是「自包含目录 + zip」，解压即用，
目标机器不需要装 .NET。

**不保证对任意游戏通用。**
部分补丁的坐标换算基于对具体游戏数据的逆向分析，换游戏可能需要重新校准。

## 文档

| 文档 | 内容 |
|---|---|
| [使用指南](docs/USAGE.md) | 怎么用、参数、环境要求、排错 |
| [JSON API](docs/json-api.md) | 后端接口，也是脚本化调用的入口 |
| [第三方声明](docs/THIRD-PARTY-NOTICES.md) | 依赖组件与各自许可 |

## 构建

需要 **.NET 10 SDK**。两个依赖以子模块引入，版本由 `tools/arp.ps1` 自动锁定：

| 目录 | 内容 | 版本 |
|---|---|---|
| `AssetRipper/` | 上游本体 | `2.0.0` |
| `ShaderRipper/` | shader 反编译器 | tag `v1.2.5` |

```powershell
.\tools\arp.ps1 build      # 自动补 SDK、拉依赖、编译
.\tools\arp.ps1 publish    # 发布到 publish/RipPatch-win-x64/
.\tools\arp.ps1 package    # 发布 + 打包 zip（约 107 MB，解压即用）
dotnet test RipPatch.slnx  # 155 个测试
```

> ShaderRipper 必须是 **v1.2.5+**：本项目调用 `Translate(model, includeDxbc)` 并读
> `DxbcPrograms`，v1.2.4 编译不过。注意它在 v1.2.5 里 `csproj` 仍写着 `1.2.4`，
> 判断版本只能看 tag。

### 结构与补丁写法

```
RipPatch/
  Patches/          每个补丁一个文件，用 [PatchMethod] 注解声明目标
  Patching/         注解、注册器、确定性重载排序
  Sprites/          移植自 Unity 的 SpriteUtility + SpriteMeshGenerator
  Shader/           shader 导出器
  Api/              UI 的 JSON 端点
  WebUi/            Photino 宿主 + wwwroot 前端资源（无框架）
Assets/             图标（icon.svg / icon.ico / 各尺寸 png）
tools/arp.ps1       一键：环境检查 / 拉依赖 / 构建 / 发布 / 运行
```

补丁目标用注解声明，编译期由 Roslyn 分析器校验、运行期由注册器绑定，两侧共用同一份声明：

```csharp
[PatchMethod(typeof(ExportHandler), nameof(ExportHandler.Export), PatchType = PatchType.Postfix)]
public static void DoSomething(GameData gameData, string outputPath, FileSystem fileSystem) { ... }
```

分析器检查目标是否存在、重载索引是否越界、参数注入是否合法（HRP001/002/003…）。
绑定失败在启动时直接抛异常，不静默跳过。

## License

**GPL-3.0** —— 因为本项目链接了同样以 GPL-3.0 发布的 AssetRipper。

这意味着**分发二进制时必须同时提供源码**，且不能改为闭源。详见 [License](License)。

## 致谢

- [AssetRipper](https://github.com/AssetRipper/AssetRipper) —— 资源解析与工程导出（GPL-3.0）
- [ShaderRipper](https://github.com/StArraySharp/ShaderRipper) —— shader 反编译（Apache-2.0 + GPL 链接例外）
- [Harmony](https://github.com/pardeike/Harmony) —— 运行期补丁（MIT）
- [Photino.NET](https://github.com/tryphotino/photino.NET) —— 原生窗口（Apache-2.0）
- [Fluent UI](https://github.com/microsoft/fluentui) —— 界面组件（MIT）

完整清单与许可副本见 [docs/THIRD-PARTY-NOTICES.md](docs/THIRD-PARTY-NOTICES.md)。
