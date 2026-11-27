<div align="center">

<img src="Assets/icons/icon-256.png" width="120" alt="RipPatch">

<h1>RipPatch</h1>

<p><strong>Turn Unity game assets into a project you can actually open</strong></p>

<p>
  <a href="#quick-start">Quick Start</a> ·
  <a href="#features">Features</a> ·
  <a href="#what-it-fixes">What it fixes</a> ·
  <a href="#docs">Docs</a> ·
  <a href="#building">Building</a>
</p>

<p>
  <a href="README.zh.md">中文</a> · <strong>English</strong>
</p>

<p>
  <a href="https://github.com/hjcsammy/RipPatch/releases/latest">
    <img src="https://img.shields.io/badge/Download-latest%20release-2ea44f?style=for-the-badge" alt="Download">
  </a>
</p>

</div>

---

RipPatch builds on [AssetRipper](https://github.com/AssetRipper/AssetRipper)'s export pipeline.

AssetRipper moves assets from a game into a project, but that is **data relocation, not semantic
restoration**. Plenty of assets depend on values the Unity editor recomputes at import time, so
copying them verbatim produces output that is wrong or missing. RipPatch fills those gaps:
the exported project is not "opens but won't run" — it can actually be edited and compiled.

> This is a third-party tool. It is **not an official AssetRipper release** and is not
> affiliated with the upstream project.

## Quick Start

### Just want to use it

1. **[Download the latest release](https://github.com/hjcsammy/RipPatch/releases/latest)** (a ~107 MB zip)
2. Extract it anywhere
3. Double-click **`RipPatch.cmd`**

That is all. **No .NET install, no git, no build step** — the runtime is bundled.

The extracted folder looks like this:

```
RipPatch-1.0.0-win-x64\
  RipPatch.cmd        <- double-click this
  使用说明.txt         <- quick notes (Chinese)
  RipPatch\           <- the program itself
    RipPatch.exe
```

You do not need to open `RipPatch\` — it holds ~450 runtime files that have to sit next to
the exe, so digging for the exe there is not the intended way to start it.

### Building from source

Clone the repo and run:

```
双击 启动.cmd        (or Start.cmd — same file)
```

The first run prepares the environment, fetches dependencies and builds (about 2–5 minutes).
After that it opens the UI directly in a few seconds. If something fails, the window stays open
with the reason instead of flashing past.

Prefer the command line:

```powershell
.\tools\arp.ps1                    # check + build + open the UI
.\tools\arp.ps1 run <game> <out>   # export from the CLI, no UI
.\tools\arp.ps1 doctor             # diagnostics only, changes nothing
```

Full instructions, options and troubleshooting: **[Usage Guide](docs/USAGE.md)** (in Chinese).

## Features

### Browsing and preview

- Search by name / type / collection, with multi-keyword support
- **List** and **thumbnail grid** views — the grid shows dozens of images per screen
- Preview images, audio, video and fonts
- **3D model preview** with drag to rotate and wheel to zoom, no third-party library

### Export

| Mode | Description |
|---|---|
| Full export | Export the complete project, filterable by asset type |
| Right-click single file | Save one asset straight to png / glb / wav / txt… |
| Batch export | Select many, export once; failures stay selected for retry |

### Interface

Chinese and English; dark / light / **follow-system** themes; native desktop window or browser mode.

## What it fixes

| Patch | Problem it solves |
|---|---|
| **Shader** | Replaces placeholder shaders with a built-in decompiler, emitting compilable ShaderLab |
| **Sprite mesh** | Regenerates vertices/indices with Unity's algorithm when the tight mesh is missing |
| **Sprite outline** | Fixes `outline` / `physicsShape` coordinate mismatches, out-of-range `m_Pivot`, and wrong Single/Multiple mode detection |
| **Sprite ownership** | Export crashed when one sprite was referenced by two atlas textures; now the first one wins |
| **Alpha-only textures** | `Alpha8` exports as a transparent white image instead of solid black |
| **Legacy dynamic fonts** | Clears dangling atlas references so Unity re-renders the font |
| **Script references** | Fills in missing entries in `Plugins/` and `Packages/manifest.json` |
| **Asset deduplication** | Identical assets are exported once and rewritten as references, producing no Missing entries |
| **MonoBehaviour tolerance** | Falls back to lenient reading with rate-limited logging when the layout does not match |
| **TypeTree tolerance** | Assets without a C# class are recovered field by field instead of being discarded |
| **Temp directory** | Cleans up temp directories left behind by imports, which can take gigabytes |

## Known limitations

**Scripts cannot be recovered when the IL2CPP metadata is encrypted.**
If `global-metadata.dat` does not start with `AF 1B B1 FA`, it has been protected. Assets still
export fine, but script classes come out empty: component references in Prefabs cannot resolve,
so UI does not render. This is a data-source problem that cannot be solved at the tool level.

**It cannot be packaged as a single exe.**
Harmony is used for runtime patching, and it needs to load `clrjit.dll` from disk to generate
IL stubs — a lookup that does not recognise single-file bundle extraction directories. The
distribution is therefore "self-contained folder + zip": unzip and run, no .NET install needed.

**Not guaranteed to work with every game.**
Some patches compute coordinates from reverse-engineered data of specific games; a different
game may need recalibration.

## Docs

| Document | Contents |
|---|---|
| [Usage Guide](docs/USAGE.md) | How to use it, options, requirements, troubleshooting (Chinese) |
| [JSON API](docs/json-api.md) | Backend endpoints, also the entry point for scripting (English) |
| [Third-Party Notices](docs/THIRD-PARTY-NOTICES.md) | Dependencies and their licenses |

## Building

Requires the **.NET 10 SDK**. Two dependencies are vendored in-tree; `tools/arp.ps1` pins their versions:

| Directory | Contents | Version |
|---|---|---|
| `AssetRipper/` | Upstream core | `2.0.0` |
| `ShaderRipper/` | Shader decompiler | tag `v1.2.5` |

```powershell
.\tools\arp.ps1 build      # install the SDK if needed, fetch deps, compile
.\tools\arp.ps1 publish    # publish to publish/RipPatch-win-x64/
.\tools\arp.ps1 package    # publish + zip (~107 MB, unzip and run)
dotnet test RipPatch.slnx  # 155 tests
```

> ShaderRipper must be **v1.2.5+**: this project calls `Translate(model, includeDxbc)` and reads
> `DxbcPrograms`, which does not compile on v1.2.4. Note that v1.2.5 still declares `1.2.4`
> in its `csproj` — only the tag is trustworthy.

### Structure and how patches are declared

```
RipPatch/
  Patches/          one file per patch, target declared with [PatchMethod]
  Patching/         attribute, registrar, deterministic overload ordering
  Sprites/          SpriteUtility + SpriteMeshGenerator ported from Unity
  Shader/           shader exporter
  Api/              JSON endpoints for the UI
  WebUi/            Photino host + wwwroot frontend (no framework)
Assets/             icons (icon.svg / icon.ico / png at each size)
tools/arp.ps1       one-click: environment check / fetch deps / build / publish / run
```

Patch targets are declared once and shared by both sides: a Roslyn analyzer validates them at
compile time and the registrar binds them at runtime.

```csharp
[PatchMethod(typeof(ExportHandler), nameof(ExportHandler.Export), PatchType = PatchType.Postfix)]
public static void DoSomething(GameData gameData, string outputPath, FileSystem fileSystem) { ... }
```

The analyzer checks that the target exists, that overload indices are in range and that parameter
injection is valid (HRP001/002/003…). A failed binding throws at startup rather than being skipped
silently.

## License

**GPL-3.0** — because this project links AssetRipper, which is also GPL-3.0.

This means **binaries must be distributed together with their source**, and the project cannot be
made closed-source. See [License](License) for details.

## Origin and what this project changes

This project is a modified version of
[StArraySharp/AssetRipperPatcher](https://github.com/StArraySharp/AssetRipperPatcher) (GPL-3.0).
**The core architecture and most patch implementations come from that project**, including:

- The patch registration mechanism (`[PatchMethod]` attribute + Roslyn analyzer + runtime binding)
- The shader decompilation export pipeline
- The sprite mesh generator (ported from Unity's `SpriteUtility` / `SpriteMeshGenerator`)
- Most of the existing patches

**What this project changes and adds**:

| Area | Change |
|---|---|
| Branding | Renamed project / namespaces / artifacts to RipPatch (was AssetRipperPatcher) |
| New patches | Sprite ownership conflict (export crashed when a sprite was referenced by two atlas textures), temp directory cleanup, exposed LoadedGameData |
| New feature | Single-asset export, with a path guard that refuses to write into or delete your home/desktop/system folders |
| UI | Thumbnail grid view, 3D model preview, batch export, export type filter, dark / light / follow-system themes |
| Tooling | `tools/arp.ps1` one-click build, `启动.cmd` launcher, release packaging pipeline |
| Docs | All READMEs, usage guide, icons |

Copyright in the original code remains with its original author. This project as a whole
continues to be distributed under **GPL-3.0**.

> If you build on this project, GPL-3.0 applies to you as well — please keep this section.

## Acknowledgements

- [AssetRipper](https://github.com/AssetRipper/AssetRipper) — asset parsing and project export (GPL-3.0)
- [ShaderRipper](https://github.com/StArraySharp/ShaderRipper) — shader decompilation (Apache-2.0 with GPL linking exception)
- [Harmony](https://github.com/pardeike/Harmony) — runtime patching (MIT)
- [Photino.NET](https://github.com/tryphotino/photino.NET) — native window (Apache-2.0)
- [Fluent UI](https://github.com/microsoft/fluentui) — UI components (MIT)

The full list with license copies is in [docs/THIRD-PARTY-NOTICES.md](docs/THIRD-PARTY-NOTICES.md).
