namespace RipPatch.Api;

/// <summary>
/// 导出目录的安全检查。
///
/// <para><b>为什么必须有。</b>整包导出会先 <c>Directory.Delete(输出目录, true)</c>
/// 清空目标，而删除<b>不进回收站、不可恢复</b>。用户把输出目录填成桌面，
/// 桌面就会被整个清空——这已经在真实使用中发生过。</para>
///
/// <para>命令行导出走 <see cref="Program.ValidateOutputDirectory"/>（带输入/输出互相包含的检查），
/// Web UI 的导出以前完全没有校验；这里补上同一类拒绝规则。</para>
/// </summary>
internal static class ExportPathGuard
{
    /// <summary>
    /// 检查 <paramref name="outputPath"/> 适不适合作为导出目标。
    /// </summary>
    /// <returns>不安全时返回可读的中文原因；安全时返回 null。</returns>
    public static string? Check(string outputPath)
    {
        string normalized;
        try
        {
            normalized = Path.TrimEndingDirectorySeparator(Path.GetFullPath(outputPath));
        }
        catch (Exception ex)
        {
            return $"路径无效：{ex.Message}";
        }

        StringComparison comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;

        string? root = Path.GetPathRoot(normalized);
        if (root is not null && string.Equals(normalized, Path.TrimEndingDirectorySeparator(root), comparison))
        {
            return "不能直接导出到盘符根目录，请选一个子文件夹（例如 D:\\Exports\\游戏名）。";
        }

        foreach (Environment.SpecialFolder folder in new[]
        {
            Environment.SpecialFolder.UserProfile,
            Environment.SpecialFolder.Desktop,
            Environment.SpecialFolder.DesktopDirectory,
            Environment.SpecialFolder.MyDocuments,
            Environment.SpecialFolder.MyMusic,
            Environment.SpecialFolder.MyPictures,
            Environment.SpecialFolder.MyVideos,
            Environment.SpecialFolder.ProgramFiles,
            Environment.SpecialFolder.Windows,
            Environment.SpecialFolder.System,
        })
        {
            string path = Environment.GetFolderPath(folder);
            if (string.IsNullOrEmpty(path))
            {
                continue;
            }
            if (string.Equals(normalized, Path.TrimEndingDirectorySeparator(path), comparison))
            {
                return $"'{normalized}' 是系统文件夹（{folder}）。导出会先清空目标目录，"
                    + "不能直接导出到这里，请改用桌面下的一个子文件夹，例如 "
                    + Path.Join(normalized, "AssetRipperExport") + "。";
            }
        }

        return null;
    }
}
