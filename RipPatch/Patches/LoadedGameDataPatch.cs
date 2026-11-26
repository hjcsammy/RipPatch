using AssetRipper.GUI.Web;
using AssetRipper.Processing;
using RipPatch.Patching;
using HarmonyLib;
using System.Reflection;

namespace RipPatch.Patches;

/// <summary>
/// 记录界面模式下加载完成的 <see cref="GameData"/>，供单资源导出使用。
///
/// <para><b>为什么需要它。</b><c>GameFileLoader</c> 把加载结果存在 private 属性里，
/// 只对外暴露 <c>IsLoaded</c> / <c>GameBundle</c> 等派生成员；
/// 而单资源导出要调用 <c>ExportHandler.Export(gameData, ...)</c>，需要 GameData 本身。
/// 与其改上游可见性，不如在加载完成时多存一份引用——只是一份引用，不复制任何数据。</para>
///
/// <para>命令行模式不走这里（<c>Program.cs</c> 自己保存），互不干扰。</para>
/// </summary>
internal static class LoadedGameDataPatch
{
    /// <summary>上游 <c>GameFileLoader.GameData</c> 这个 private 静态属性。</summary>
    private static readonly PropertyInfo? s_gameDataProperty =
        typeof(GameFileLoader).GetProperty("GameData", BindingFlags.Static | BindingFlags.NonPublic);

    [PatchMethod(typeof(GameFileLoader), nameof(GameFileLoader.LoadAndProcess), PatchType = PatchType.Postfix,
        Priority = HarmonyLib.Priority.Low)]
    public static void Remember()
    {
        if (s_gameDataProperty?.GetValue(null) is GameData gameData)
        {
            AppState.LoadedGameData = gameData;
        }
    }

    /// <summary>
    /// 重置时同步清掉：之后再点「单文件导出」应当提示「先导入」，而不是导出已卸载的数据。
    /// </summary>
    [PatchMethod(typeof(GameFileLoader), nameof(GameFileLoader.Reset), PatchType = PatchType.Postfix,
        Priority = HarmonyLib.Priority.Low)]
    public static void Forget()
    {
        AppState.LoadedGameData = null;
    }

    /// <summary>测试用：反射是否仍能定位到上游字段。</summary>
    internal static bool CanLocateGameData => s_gameDataProperty is not null;
}
