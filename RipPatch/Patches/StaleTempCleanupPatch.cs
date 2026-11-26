using AssetRipper.GUI.Web;
using RipPatch.Patching;
using HarmonyLib;

namespace RipPatch.Patches;

/// <summary>
/// 每次导入前清理上一次运行留下的临时目录。
///
/// <para><b>问题。</b>上游导入时会把整个 xapk/apk 解压到
/// <c>&lt;程序目录&gt;\temp\&lt;随机4字符&gt;</c>，并且只在「本次运行正常结束」时删掉自己那一个。
/// 程序崩溃、被强杀、或用户直接关窗口时，那一份就留下了。
/// 实测导入一个 230 MB 的 xapk 会留下 200+ MB，反复几次就是几个 GB。</para>
///
/// <para><b>为什么挂在 <see cref="GameFileLoader.LoadAndProcess"/> 上。</b>
/// 它是一次导入的入口，此刻「上次的「临时目录都还没被本次使用，
/// 正好可以安全清理；而且无论是界面导入还是命令行导入都会经过它。</para>
///
/// <para><b>安全性。</b>只删 <c>&lt;程序目录&gt;\temp</c> 下名字是 4 个字符的直接子目录
/// （上游 <c>GetRandomString()[0..4]</c> 的形状）。先删再导入，
/// 所以不会误删本次正在写的目录；任何失败都静默忽略。</para>
/// </summary>
internal static class StaleTempCleanupPatch
{
    [PatchMethod(typeof(GameFileLoader), nameof(GameFileLoader.LoadAndProcess), PatchType = PatchType.Prefix,
        Priority = HarmonyLib.Priority.High)]
    public static void CleanBeforeImport()
    {
        try
        {
            string tempRoot = Path.Join(AssetRipper.IO.Files.LocalFileSystem.ExecutingDirectory, "temp");
            if (!Directory.Exists(tempRoot))
            {
                return;
            }

            long freed = 0;
            int removed = 0;
            foreach (string directory in Directory.EnumerateDirectories(tempRoot))
            {
                string name = Path.GetFileName(directory);
                // 上游用 4 字符随机串作名字；别的形状（用户自己放的、其它工具的）不碰。
                if (name.Length != 4)
                {
                    continue;
                }

                try
                {
                    long size = DirectorySize(directory);
                    Directory.Delete(directory, true);
                    freed += size;
                    removed++;
                }
                catch
                {
                    // 被其它实例占用 / 权限不足：跳过。
                }
            }

            if (removed > 0)
            {
                Console.WriteLine(
                    $"[Cleanup] removed {removed} stale import temp folder(s), freed {freed / (1024 * 1024)} MB");
            }
        }
        catch
        {
            // 清理是尽力而为，不能影响导入。
        }
    }

    private static long DirectorySize(string directory)
    {
        long total = 0;
        try
        {
            foreach (string file in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
            {
                try
                {
                    total += new FileInfo(file).Length;
                }
                catch
                {
                    // 统计过程中文件消失：忽略。
                }
            }
        }
        catch
        {
            // 目录不可读：返回已统计的部分。
        }
        return total;
    }
}
