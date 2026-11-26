using AssetRipper.Assets;
using AssetRipper.IO.Files;
using AssetRipper.Processing;
using AssetRipper.Processing.Textures;
using AssetRipper.SourceGenerated.Classes.ClassID_213;
using AssetRipper.SourceGenerated.Classes.ClassID_687078895;
using RipPatch.Patching;
using HarmonyLib;
using System.Reflection;

namespace RipPatch.Patches;

/// <summary>
/// 修复「同一个 Sprite 被两张图集纹理同时认领」导致的导出崩溃。
///
/// <para><b>现象。</b>点导出后立刻失败，只有一行：
/// <c>System.ArgumentException: An item with the same key has already been added. Key: daily_task_btn_0001</c>。</para>
///
/// <para><b>根因。</b><see cref="SpriteProcessor.Process"/> 用两条路径把 Sprite 归档进
/// 「纹理 → Sprite 集合」（<see cref="SpriteInformationObject"/>）：
/// <list type="number">
/// <item>Sprite 自身：<c>sprite.TryGetTexture()</c> → 那张纹理的对象；</item>
/// <item>SpriteAtlas：遍历 <c>PackedSpritesP</c>，用 <c>RenderDataMap</c> 里的纹理 → 那张纹理的对象。</item>
/// </list>
/// 当游戏里两张<b>不同的图集纹理</b>（实测：<c>...DailyTasks-2f693ef4</c> 与
/// <c>...DailyTask-9eac1fa7</c>，都是 1024x1024 的图集页）指向同一批 Sprite 时，
/// 同一个 Sprite 会进两个对象。导出阶段每个对象生成一条 <c>TextureExportCollection</c>，
/// 它会把集合里的 Sprite 全部 <c>AddAsset</c>，于是同一个 Sprite 被两条集合声明；
/// <see cref="AssetRipper.Export.UnityProjects.ProjectAssetContainer"/> 用
/// <c>Dictionary.Add</c> 建「资源 → 集合」表时键冲突，导出失败。</para>
///
/// <para><b>为什么不是本项目其他补丁造成的。</b>实测该游戏
/// <c>EnableAssetDeduplication=false</c>（去重补丁整段跳过），冲突的两条集合都是上游
/// <c>TextureExportCollection</c>；去掉本补丁可稳定复现，加上即修复。</para>
///
/// <para><b>修法。</b>在 <see cref="SpriteProcessor"/> 跑完、导出集合构建之前，
/// 让每个 Sprite <b>只留在第一个</b>认领它的对象里，从后续对象中移除。
/// Unity 工程里一个 Sprite 本来就只能有一个归属，所以这里是恢复唯一性而非丢数据：
/// 被移走的 Sprite 仍随保留它的那张纹理导出，引用通过那条集合的 GUID/fileID 正常解析，
/// 不会产生 Missing。</para>
///
/// <para><b>为什么用反射。</b><see cref="SpriteInformationObject"/> 的资源表是 private，
/// 上游也没有为本项目开放 <c>internal</c> 可见性。反射只碰一个
/// <c>Dictionary&lt;ISprite, ISpriteAtlas?&gt;</c>，且只在真的检测到冲突时才调用，
/// 不会影响正常游戏。</para>
/// </summary>
internal static class DuplicateSpriteOwnershipPatch
{
    private static readonly FieldInfo? s_dictionaryField =
        typeof(SpriteInformationObject).GetField("dictionary", BindingFlags.Instance | BindingFlags.NonPublic);

    /// <summary>
    /// 挂在 <see cref="SpriteProcessor.Process"/> 之后：此刻所有 Sprite 都归档完了，
    /// 而 <c>ProjectExporter.CreateCollections</c> 还没开始。
    ///
    /// <para>Priority 必须显式声明：同一个目标上还挂着 <c>SpriteOutlinePatch</c>，
    /// 两者顺序不确定会得到不稳定的导出结果（分析器 HRP005 也会报）。</para>
    /// </summary>
    [PatchMethod(typeof(SpriteProcessor), nameof(SpriteProcessor.Process), PatchType = PatchType.Postfix,
        Priority = HarmonyLib.Priority.Low)]
    public static void DeduplicateOwnership(GameData gameData)
    {
        try
        {
            int removed = Deduplicate(gameData);
            if (removed > 0)
            {
                Console.WriteLine($"[SpriteOwnership] released {removed} sprite(s) claimed by a second texture");
            }
        }
        catch (Exception ex)
        {
            // 修复失败不能把导出带崩：交回上游按原行为处理。
            Console.WriteLine($"[SpriteOwnership] repair skipped: {ex.GetType().Name}: {ex.Message}");
        }
    }

    /// <summary>测试入口：返回从次要纹理上摘掉的 Sprite 条数。</summary>
    internal static int DeduplicateForTesting(GameData gameData) => Deduplicate(gameData);

    /// <summary>
    /// 测试用：反射是否成功定位到 <c>SpriteInformationObject.dictionary</c>。
    /// 上游改字段名时补丁会静默失效，靠这条断言提前暴露。
    /// </summary>
    internal static bool CanLocateSpriteTable => s_dictionaryField is not null;

    private static int Deduplicate(GameData gameData)
    {
        if (s_dictionaryField is null)
        {
            return 0;
        }

        // 资源顺序必须稳定：同一个 Sprite 每次导出都归到同一张纹理，
        // 否则两次导出的 GUID 分配会不一致。
        List<SpriteInformationObject> owners = gameData.GameBundle
            .FetchAssetCollections()
            .Where(static c => !SpecialFileNames.IsDefaultResourceOrBuiltinExtra(c.Name))
            .SelectMany(static c => c)
            .OfType<SpriteInformationObject>()
            .ToList();

        Dictionary<ISprite, SpriteInformationObject> firstOwner = new(ReferenceEqualityComparer.Instance);

        List<(string Sprite, string Texture)> samples = new();
        int removed = 0;

        foreach (SpriteInformationObject owner in owners)
        {
            if (s_dictionaryField.GetValue(owner) is not Dictionary<ISprite, ISpriteAtlas?> map)
            {
                continue;
            }

            // 先收集再删：不能边遍历边改。
            List<ISprite> surplus = new();
            foreach (ISprite sprite in map.Keys)
            {
                if (firstOwner.TryGetValue(sprite, out SpriteInformationObject? keeper))
                {
                    if (!ReferenceEquals(keeper, owner))
                    {
                        surplus.Add(sprite);
                        if (samples.Count < 5)
                        {
                            samples.Add((SafeName(sprite), SafeName(owner.Texture)));
                        }
                    }
                }
                else
                {
                    firstOwner[sprite] = owner;
                }
            }

            foreach (ISprite sprite in surplus)
            {
                if (map.Remove(sprite))
                {
                    removed++;
                }
            }
        }

        foreach ((string sprite, string texture) in samples)
        {
            Console.WriteLine($"    '{sprite}' no longer claimed by texture '{texture}'");
        }

        return removed;
    }

    private static string SafeName(IUnityObjectBase asset)
    {
        try
        {
            return asset.GetBestName();
        }
        catch
        {
            return "<name threw>";
        }
    }
}
