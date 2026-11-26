using AssetRipper.Assets;
using AssetRipper.Export.UnityProjects;
using AssetRipper.GUI.Web;
using AssetRipper.Import.Logging;
using AssetRipper.IO.Files;
using AssetRipper.Processing;

namespace RipPatch.Api;

/// <summary>
/// 单资源导出：把一个资源直接写成<b>一个文件</b>，写进用户选的目录。
///
/// <para><b>绝不删除任何目录或文件。</b>早期版本在这里用
/// <c>Directory.Delete(target, true)</c> 清空目标目录——用户选了桌面，
/// 整个桌面就被清空了。这类操作不可恢复（不进回收站），所以现在改为：
/// <list type="bullet">
/// <item>只在目标目录里<b>新建/覆盖一个文件</b>；</item>
/// <item>目录本身不存在才创建，已存在就原样用；</item>
/// <item>危险位置（盘符根、用户主目录、桌面、系统目录）直接拒绝写入。</item>
/// </list></para>
///
/// <para><b>导出的是裸资源。</b>图片是 png、模型是 glb、音频保持原格式、文本是 txt，
/// 不再生成 <c>.meta</c> 和整个 Unity 工程骨架——需要完整工程的用整包导出。</para>
/// </summary>
internal static class SingleAssetExporter
{
    /// <summary>
    /// 把 <paramref name="asset"/> 写成一个文件放进 <paramref name="outputDirectory"/>。
    /// 同名文件会被覆盖（那是一个明确的文件级操作，不是删目录）。
    /// </summary>
    /// <returns>写出的文件完整路径。</returns>
    public static string ExportFile(IUnityObjectBase asset, string outputDirectory)
    {
        string directory = Path.GetFullPath(outputDirectory);

        // 危险位置（盘符根 / 桌面 / 用户目录 / 系统目录）直接拒绝。
        // 注意：这里只写文件，不会删目录，但把这些位置当默认落点仍然是错误的选择。
        if (ExportPathGuard.Check(directory) is { } refusal)
        {
            throw new InvalidOperationException(refusal);
        }

        (string extension, Func<byte[]> producer) = ChooseProducer(asset);
        byte[] bytes;
        try
        {
            bytes = producer();
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException($"导出失败：{ex.Message}", ex);
        }

        if (bytes.Length == 0)
        {
            throw new InvalidOperationException("这个资源无法转成文件（内容为空或不受支持）。");
        }

        if (!Directory.Exists(directory))
        {
            // 只创建用户明确指出的那一层目录。
            Directory.CreateDirectory(directory);
        }

        string fileName = BuildFileName(asset, extension);
        string filePath = UniquePath(directory, fileName);
        File.WriteAllBytes(filePath, bytes);

        Logger.Info(LogCategory.Export,
            $"Exported single asset: {asset.ClassName} '{asset.GetBestName()}' -> {filePath} ({bytes.Length} bytes)");
        return filePath;
    }

    
    /// <summary>按资源类型挑转换器。只处理能直接落成常见文件的类型。</summary>
    private static (string Extension, Func<byte[]> Producer) ChooseProducer(IUnityObjectBase asset)
    {
        if (AssetProbe.HasImage(asset))
        {
            return ("png", () => AssetProbe.GetImageBytes(asset, AssetRipper.Export.Configuration.ImageExportFormat.Png)
                ?? throw new InvalidOperationException("图片无法解码。"));
        }

        if (AssetProbe.HasModel(asset))
        {
            return ("glb", () => AssetProbe.GetModelBytes(asset)
                ?? throw new InvalidOperationException("模型无法解码。"));
        }

        if (AssetProbe.HasAudio(asset))
        {
            return ("wav", () =>
            {
                (byte[] Data, string Mime)? audio = AssetProbe.GetAudioBytes(asset, null);
                if (audio is null)
                {
                    throw new InvalidOperationException("音频无法解码。");
                }
                return audio.Value.Data;
            });
        }

        if (AssetProbe.HasVideo(asset))
        {
            return ("mp4", () =>
            {
                (byte[] Data, string Mime)? video = AssetProbe.GetVideoBytes(asset);
                if (video is null)
                {
                    throw new InvalidOperationException("视频无法读取。");
                }
                return video.Value.Data;
            });
        }

        if (AssetProbe.HasFont(asset))
        {
            return ("ttf", () =>
            {
                (byte[] Data, string Mime)? font = AssetProbe.GetFontBytes(asset);
                if (font is null)
                {
                    throw new InvalidOperationException("字体无法读取。");
                }
                return font.Value.Data;
            });
        }

        if (AssetProbe.HasText(asset))
        {
            return ("txt", () =>
            {
                string? text = AssetProbe.GetText(asset);
                if (text is null)
                {
                    throw new InvalidOperationException("文本无法读取。");
                }
                return System.Text.Encoding.UTF8.GetBytes(text);
            });
        }

        // 兜底：有原始字节就写原始字节。
        return ("bin", () =>
        {
            (byte[] Data, string Mime)? raw = AssetProbe.GetRawBytes(asset);
            if (raw is null)
            {
                throw new InvalidOperationException(
                    $"这个类型（{asset.ClassName}）没有可以直接导出的文件形式。");
            }
            return raw.Value.Data;
        });
    }

    /// <summary>用资源名做文件名，剔掉 Windows 不允许的字符。</summary>
    private static string BuildFileName(IUnityObjectBase asset, string extension)
    {
        string name;
        try
        {
            name = asset.GetBestName();
        }
        catch
        {
            name = asset.ClassName;
        }

        if (string.IsNullOrWhiteSpace(name))
        {
            name = $"{asset.ClassName}_{asset.PathID}";
        }

        foreach (char invalid in Path.GetInvalidFileNameChars())
        {
            name = name.Replace(invalid, '_');
        }

        name = name.Trim().TrimEnd('.');
        if (name.Length > 120)
        {
            name = name[..120];
        }
        return $"{name}.{extension}";
    }

    /// <summary>
    /// 同名文件已存在时加 (1)、(2) 后缀，而不是覆盖别人的文件。
    /// </summary>
    private static string UniquePath(string directory, string fileName)
    {
        string path = Path.Join(directory, fileName);
        if (!File.Exists(path))
        {
            return path;
        }

        string stem = Path.GetFileNameWithoutExtension(fileName);
        string extension = Path.GetExtension(fileName);
        for (int i = 1; i < 1000; i++)
        {
            string candidate = Path.Join(directory, $"{stem} ({i}){extension}");
            if (!File.Exists(candidate))
            {
                return candidate;
            }
        }

        // 极端情况下用时间戳兜底。
        return Path.Join(directory, $"{stem} ({DateTime.Now:HHmmss}){extension}");
    }
}
