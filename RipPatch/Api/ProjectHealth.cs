using System;
using System.Collections.Generic;
using System.Linq;
using AssetRipper.Assets;
using AssetRipper.Import.Structure.Assembly;
using AssetRipper.Import.Structure.Assembly.Serializable;
using AssetRipper.SourceGenerated.Classes.ClassID_1;
using AssetRipper.SourceGenerated.Classes.ClassID_114;
using AssetRipper.SourceGenerated.Extensions;

namespace RipPatch.Api;

/// <summary>
/// 导出前的工程健康检查。
///
/// <para><b>为什么需要它。</b>导出完成不等于能用。常见情况是：工程能在 Unity 里打开，
/// 但 Prefab 里一堆 Missing（脚本类解析不出来）、UI 显示空白、材质是粉红。
/// 用户导完 15 分钟才发现问题，却不知道坏在哪、坏多少。这里在导出前就把问题量化出来。</para>
///
/// <para><b>检查什么。</b>只做能确定判断的，不猜：</para>
/// <list type="bullet">
/// <item>MonoBehaviour 的脚本类能否解析（解析不出来 = Unity 里变 Missing）</item>
/// <item>脚本字段是否为空（元数据加密的典型表现）</item>
/// <item>GameObject 是否缺少组件（结构损坏）</item>
/// </list>
/// </summary>
internal static class ProjectHealth
{
	/// <summary>扫描上限。几万个资源逐个反射很慢，抽样足够反映整体状况。</summary>
	private const int MaxScan = 20000;

	public static HealthReportDto Check()
	{
		List<IUnityObjectBase> assets;
		try
		{
			assets = AssetProbe.EnumerateAssets().Take(MaxScan).ToList();
		}
		catch (Exception ex)
		{
			return new HealthReportDto(0, 0, 0, 0, 0, 0, new[]
			{
				new HealthIssueDto("error", "无法读取资源", ex.Message, 0),
			});
		}

		int monoCount = 0;
		int monoResolved = 0;
		int monoEmptyFields = 0;
		int prefabCount = 0;
		int goWithoutComponents = 0;

		foreach (IUnityObjectBase asset in assets)
		{
			try
			{
				if (asset is IMonoBehaviour mono)
				{
					monoCount++;
					SerializableStructure? structure = mono.LoadStructure();
					if (structure is null)
					{
						// 脚本类解析失败：Unity 里会显示成 Missing (Mono Script)
						continue;
					}
					monoResolved++;
					if (structure.Fields is null or { Length: 0 })
					{
						monoEmptyFields++;
					}
				}
				else if (asset is IGameObject gameObject)
				{
					if (asset.ClassName.Contains("Prefab"))
					{
						prefabCount++;
					}
					// 一个正常的 GameObject 至少有 Transform
					if (!gameObject.GetComponentAccessList().Any())
					{
						goWithoutComponents++;
					}
				}
			}
			catch
			{
				// 单个资源异常不该中断整个检查
			}
		}

		int monoMissing = monoCount - monoResolved;
		List<HealthIssueDto> issues = new();

		// 判定规则要保守：只有确实异常才报，避免「什么都报 red」让用户脱敏。
		if (monoCount > 0 && monoMissing > 0)
		{
			double ratio = (double)monoMissing / monoCount;
			string severity = ratio > 0.5 ? "error" : "warning";
			issues.Add(new HealthIssueDto(
				severity,
				"脚本类无法解析",
				ratio > 0.5
					? $"超过一半的 MonoBehaviour（{monoMissing}/{monoCount}）解析不出脚本类。最常见的原因是 IL2CPP 元数据被加密：导出后 Prefab 里的组件会全部变成 Missing，UI 显示不出来。"
					: $"有 {monoMissing}/{monoCount} 个 MonoBehaviour 解析不出脚本类，导出后这些组件会变成 Missing。",
				monoMissing));
		}

		if (monoEmptyFields > 0)
		{
			issues.Add(new HealthIssueDto(
				monoEmptyFields > monoResolved / 2 ? "error" : "warning",
				"脚本字段为空",
				$"{monoEmptyFields} 个 MonoBehaviour 虽然解析出了脚本类，但字段列表是空的。这通常说明 TypeTree 与脚本结构对不上，导出的组件参数（颜色、文本、Sprite 引用）会丢失。",
				monoEmptyFields));
		}

		if (goWithoutComponents > 0)
		{
			issues.Add(new HealthIssueDto(
				"warning",
				"GameObject 缺少组件",
				$"{goWithoutComponents} 个 GameObject 连 Transform 都没有。这类节点导出后层级关系会断开。",
				goWithoutComponents));
		}

		if (issues.Count == 0)
		{
			issues.Add(new HealthIssueDto(
				"ok",
				"未发现结构性问题",
				$"扫描了 {assets.Count} 个资源，脚本与层级结构看起来正常。",
				0));
		}

		return new HealthReportDto(
			assets.Count,
			monoCount,
			monoResolved,
			monoMissing,
			prefabCount,
			goWithoutComponents,
			issues);
	}
}
