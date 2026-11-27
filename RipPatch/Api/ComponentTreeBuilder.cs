using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using AssetRipper.Assets;
using AssetRipper.Assets.Generics;
using AssetRipper.GUI.Web.Paths;
using AssetRipper.SourceGenerated.Classes.ClassID_1;
using AssetRipper.SourceGenerated.Classes.ClassID_2;
using AssetRipper.SourceGenerated.Extensions;

namespace RipPatch.Api;

/// <summary>
/// 生成 Prefab / 场景的组件树。
///
/// <para><b>为什么需要它。</b>改 UI 时要先搞清楚层级：这个界面有哪些 GameObject，
/// 每个挂了什么组件，Text 在哪个节点上。AssetRipper 导出的 YAML 把每个对象平铺成
/// 独立文件，靠 fileID 互相引用，人眼几乎不可能顺着读。这里直接还原成树。</para>
///
/// <para><b>数据来源。</b>用 <c>GameObjectExtensions.FetchComponents</c> 拿组件列表，
/// <c>GetChildren</c> 拿子节点（内部走 Transform 的 m_Children）。</para>
/// </summary>
internal static class ComponentTreeBuilder
{
	/// <summary>节点数上限：真实场景能有几千个节点，全展开会把 JSON 撑到几 MB。</summary>
	private const int MaxNodes = 8000;

	/// <summary>从任意资源出发，尽可能还原它所在的层级树。</summary>
	public static ComponentTreeDto? Build(IUnityObjectBase asset)
	{
		try
		{
			IGameObject? root = FindRootGameObject(asset);
			if (root is null)
			{
				return null;
			}

			int budget = MaxNodes;
			return BuildNode(root, budget: ref budget);
		}
		catch (Exception)
		{
			// 结构不完整（比如 Transform 缺失）时不要抛到 API 层
			return null;
		}
	}

	/// <summary>
	/// 找到它所属的根 GameObject，并沿子节点展开。
	///
	/// 传进来的可能是 GameObject 本身、某个组件（Image、Text）、或者 Transform。
	/// 都会先爬到根，再从根往下画整棵树——比只画当前节点有用得多。
	/// </summary>
	private static IGameObject? FindRootGameObject(IUnityObjectBase asset)
	{
		if (asset is IGameObject go)
		{
			return GetRoot(go);
		}

		// 组件：取它指向的 GameObject。
		// 属性名在不同 Unity 版本上写过 GameObject 和 GameObjectP，用反射兜住。
		if (asset is IComponent component)
		{
			IGameObject? owner = TryGetOwnerGameObject(component);
			return owner is null ? null : GetRoot(owner);
		}

		return null;
	}

	private static IGameObject? TryGetOwnerGameObject(IComponent component)
	{
		System.Reflection.PropertyInfo? property = component.GetType().GetProperty("GameObject")
			?? component.GetType().GetProperty("GameObjectP");
		return property?.GetValue(component) as IGameObject;
	}

	private static IGameObject GetRoot(IGameObject gameObject)
	{
		IGameObject current = gameObject;
		// 沿父节点往上爬，最多几十层，防止数据异常导致死循环
		for (int i = 0; i < 128; i++)
		{
			IGameObject? parent = current.GetTransform()?.Father_C4P?.GameObject_C4P;
			if (parent is null)
			{
				break;
			}
			current = parent;
		}
		return current;
	}

	private static ComponentTreeDto BuildNode(IGameObject gameObject, ref int budget)
	{
		budget--;

		string name = gameObject.Name.String ?? string.Empty;
		List<ComponentTreeDto> children = new();

		// 组件以子节点形式挂在 GameObject 下面，用「类名」当名字，
		// 这样一眼能看出这个节点挂了哪些东西。
		if (budget > 0)
		{
			foreach (IComponent component in gameObject.GetComponentAccessList())
			{
				if (budget <= 0)
				{
					break;
				}
				budget--;

				string classLabel = NormalizeClassName(component.GetType().Name);
				// 组件的名字对 UI 排查有帮助（比如 Image 的 sprite 名），
				// 但很多组件没有名字，空着就行。
				string label = TryGetName(component);
				children.Add(new ComponentTreeDto(
					string.IsNullOrEmpty(label) ? classLabel : label,
					classLabel,
					component.PathID.ToString(CultureInfo.InvariantCulture),
					GetCollectionJson(component),
					null));
			}
		}

		// 再挂子 GameObject
		if (budget > 0)
		{
			foreach (IGameObject child in gameObject.GetChildren())
			{
				if (budget <= 0)
				{
					children.Add(new ComponentTreeDto(
						"... 节点过多，已截断", "", "0", null, null));
					break;
				}
				children.Add(BuildNode(child, ref budget));
			}
		}

		return new ComponentTreeDto(
			name,
			"GameObject",
			gameObject.PathID.ToString(CultureInfo.InvariantCulture),
			GetCollectionJson(gameObject),
			children);
	}

	/// <summary>
	/// 源生成器产出的类名带有 Unity 版本后缀，如 MonoBehaviour_2019_1_0_b4、
	/// RectTransform_2023_2_0_a19。展示时去掉后缀，只留类名。
	/// </summary>
	/// <summary>
	/// 集合路径（JSON）。前端点树节点时用它把 pathId 精确映射回资源，
	/// 不传的话后端得全量扫索引，慢且可能重名。
	/// </summary>
	private static string? GetCollectionJson(IUnityObjectBase asset)
	{
		try
		{
			return asset.Collection?.GetPath().ToJson();
		}
		catch
		{
			return null;
		}
	}

	private static string NormalizeClassName(string name)
	{
		int index = name.IndexOf('_');
		return index > 0 ? name.Substring(0, index) : name;
	}

	private static string TryGetName(IComponent component)
	{
		// 组件信息已经由类名表达了，这里留空即可；
		// 想补上具体资源名需要按类型分别取，价值不大。
		return string.Empty;
	}
}
