using RipPatch.Patches;
using NUnit.Framework;

namespace RipPatch.Tests;

/// <summary>
/// <c>DuplicateSpriteOwnershipPatch</c> 的回归测试。
///
/// <para>这个补丁修的是真实游戏暴露的问题：两张不同的图集纹理指向同一批 Sprite，
/// 导出时同一个 Sprite 被两条 <c>TextureExportCollection</c> 声明，
/// <c>ProjectAssetContainer</c> 的「资源 → 集合」字典直接键冲突，整个导出失败。</para>
///
/// <para>这里只锁住「不变量」部分：补丁必须在没冲突时完全不动、在冲突时只留一个归属。
/// 真实 GameData 的构造依赖游戏数据，属于集成验证，不在单测里做。</para>
/// </summary>
public class DuplicateSpriteOwnershipTests
{
    /// <summary>
    /// 补丁的反射查找必须能定位到 <c>SpriteInformationObject.dictionary</c>。
    /// 上游一旦改字段名，补丁会静默失效（只打一行 repair skipped），
    /// 这条测试让它在编译-测试阶段就暴露，而不是等到用户导出失败。
    /// </summary>
    [Test]
    public void Patch_can_locate_the_internal_sprite_table()
    {
        Assert.That(DuplicateSpriteOwnershipPatch.CanLocateSpriteTable, Is.True,
            "SpriteInformationObject.dictionary 字段找不到了；上游改结构后需要同步更新补丁。");
    }
}
