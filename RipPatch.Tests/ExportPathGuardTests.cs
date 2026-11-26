using RipPatch.Api;
using NUnit.Framework;

namespace RipPatch.Tests;

/// <summary>
/// 导出目录护栏的回归测试。
///
/// <para>这组用例来自一次真实事故：右键「导出这一个」时把输出目录填成了桌面，
/// 旧实现先 <c>Directory.Delete(target, true)</c> 清空目标再写文件，
/// 结果整个桌面被清空，而且删除不进回收站、不可恢复。</para>
///
/// <para>现在两条导出路径都必须拒绝「桌面 / 用户目录 / 盘符根」这类位置。</para>
/// </summary>
public class ExportPathGuardTests
{
    private static readonly string Root = Path.GetPathRoot(Path.GetFullPath("."))!;

    [Test]
    public void Rejects_drive_root()
    {
        string? reason = ExportPathGuard.Check(Root);
        Assert.That(reason, Is.Not.Null);
        Assert.That(reason, Does.Contain("盘符根"));
    }

    [Test]
    public void Rejects_user_profile()
    {
        string? reason = ExportPathGuard.Check(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        Assert.That(reason, Is.Not.Null);
    }

    /// <summary>
    /// 这条是事故的直接回归：桌面绝不能被当成导出目标。
    /// </summary>
    [Test]
    public void Rejects_desktop()
    {
        string desktop = Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
        Assert.That(desktop, Is.Not.Empty, "测试环境取不到桌面路径，无法验证这条规则。");

        string? reason = ExportPathGuard.Check(desktop);
        Assert.That(reason, Is.Not.Null, "桌面必须被拒绝：导出会先清空目标目录。");
    }

    [Test]
    public void Rejects_documents_and_pictures()
    {
        foreach (Environment.SpecialFolder folder in new[]
        {
            Environment.SpecialFolder.MyDocuments,
            Environment.SpecialFolder.MyPictures,
        })
        {
            string path = Environment.GetFolderPath(folder);
            if (string.IsNullOrEmpty(path))
            {
                continue;
            }
            Assert.That(ExportPathGuard.Check(path), Is.Not.Null, $"{folder} 应当被拒绝。");
        }
    }

    /// <summary>
    /// 桌面下的子目录是允许的：用户经常就是想把东西导出到桌面上的某个文件夹。
    /// </summary>
    [Test]
    public void Allows_subfolder_of_desktop()
    {
        string desktop = Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
        string sub = Path.Combine(desktop, "AssetRipperExport", "MyGame");
        Assert.That(ExportPathGuard.Check(sub), Is.Null);
    }

    [Test]
    public void Allows_ordinary_directory()
    {
        string path = Path.Combine(Path.GetTempPath(), "arp-export-test", "out");
        Assert.That(ExportPathGuard.Check(path), Is.Null);
    }

    /// <summary>尾部反斜杠不应绕过检查。</summary>
    [Test]
    public void Rejects_drive_root_with_trailing_separator()
    {
        Assert.That(ExportPathGuard.Check(Root + Path.DirectorySeparatorChar), Is.Not.Null);
    }
}
