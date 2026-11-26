# 第三方声明

RipPatch 依 GNU General Public License 第 3 版发布（见 `licenses/LICENSE-GPL-3.0.txt`）。
它链接或内嵌了下列组件，各自适用自己的许可。要求随分发附带许可副本的组件，
其副本都收集在 `licenses/` 目录下。

## 链接进程序的组件

| 组件 | 用途 | 许可 |
|---|---|---|
| [AssetRipper](https://github.com/AssetRipper/AssetRipper) | Unity 资源解析与工程导出（git submodule） | GPL-3.0 |
| [ShaderRipper](https://github.com/StArraySharp/ShaderRipper) | 从编译后的 shader blob 反编译 ShaderLab | Apache-2.0，**附 GPL-3.0 链接例外** |
| [Harmony](https://github.com/pardeike/Harmony) | 运行期给 AssetRipper 打补丁 | MIT |
| [AsmResolver](https://github.com/Washi1337/AsmResolver) | 脚本引用补丁用的 IL 检查 | MIT |
| [SharpCompress](https://github.com/adamhathcock/sharpcompress) | 压缩包读取 | MIT |
| [Cpp2IL](https://github.com/SamboyCoding/Cpp2IL) | IL2CPP 元数据与程序集解析 | MIT |
| [NativeFileDialog](https://github.com/StArraySharp/NativeFileDialog) | 系统文件/目录选择框 | MIT |
| [Photino.NET](https://github.com/tryphotino/photino.NET) / Photino.Native | 承载 WebView2 界面的原生窗口 | Apache-2.0 |
| [Microsoft.Web.WebView2](https://learn.microsoft.com/microsoft-edge/webview2/) | 桌面界面的嵌入式浏览器 | Microsoft 条款 |
| [Fluent UI Web Components](https://github.com/microsoft/fluentui) | 界面组件库（打包进 `wwwroot/lib/fluent.js`） | MIT |
| [K4os.Compression.LZ4](https://github.com/MiloszKrajewski/K4os.Compression.LZ4) | Unity LZ4 块解压 | MIT |
| [Antlr4.Runtime.Standard](https://github.com/antlr/antlr4) | ShaderRipper 文法运行时 | BSD-3-Clause |
| [LibTessDotNet](https://github.com/speps/LibTessDotNet) | Sprite 轮廓三角化 | SGI-B-2.0 |
| D3DCompiler / DXIL（Microsoft，由 ShaderRipper 内嵌） | shader 反汇编 | Windows SDK / Apache-2.0 with LLVM exception |

## 关于 ShaderRipper 的链接例外

ShaderRipper 是 Apache-2.0，而 GPL-3.0 §7 不允许 GPL-3.0 作品链接它 ——
因为 Apache-2.0 的专利终止与赔偿条款构成额外限制。ShaderRipper 的著作权持有人
同时也是本项目的著作权人，因此 `LICENSE-EXCEPTION-ShaderRipper-GPL.txt` 授权
两者链接并以 GPL-3.0 分发，而 ShaderRipper 自身仍保持 Apache-2.0。

该例外只覆盖 ShaderRipper 自己的代码。它内嵌的第三方组件维持各自许可，见上表。

## 分发时的义务

**GPL-3.0 要求分发二进制时提供对应源码。** 如果你发布 RipPatch 的可执行文件，
必须同时让使用者能获取到完整源码（随附或提供可访问的仓库链接）。

同时请保持 `licenses/` 目录完整：

- `LICENSE-GPL-3.0.txt`（GPL-3.0 §6）
- `LICENSE-ShaderRipper-Apache-2.0.txt`
- `LICENSE-EXCEPTION-ShaderRipper-GPL.txt`（Apache-2.0 §4(a)）
- 本文件
