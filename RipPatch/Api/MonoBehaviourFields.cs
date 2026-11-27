using System;
using System.Collections.Generic;
using System.Globalization;
using System.Reflection;
using System.Text;
using AssetRipper.Assets;
using AssetRipper.Assets.Metadata;
using AssetRipper.Import.Structure.Assembly;
using AssetRipper.Import.Structure.Assembly.Serializable;
using AssetRipper.SerializationLogic;
using AssetRipper.SourceGenerated.Classes.ClassID_114;

namespace RipPatch.Api;

/// <summary>
/// 把 MonoBehaviour 里已经解析好的字段值读出来，转成可展示的结构。
///
/// <para><b>为什么需要它。</b>AssetRipper 会把 IL2CPP 的 TypeTree 解析成
/// <see cref="SerializableStructure"/>，字段值都在内存里，但界面只暴露了原始 YAML。
/// 看 YAML 得自己对照字段名、偏移和类型，改 UI 时找「这个按钮的文案在哪」
/// 非常费劲。这里直接把字段名、类型、值列成表。</para>
///
/// <para><b>能拿到什么。</b>数值、字符串、布尔直接可读；对象引用（PPtr）会尝试
/// 解析成被引用资源的名字，便于顺着引用看下去。</para>
/// </summary>
internal static class MonoBehaviourFields
{

	/// <summary>嵌套超过这个深度就截断，避免深层结构把 JSON 撑爆。</summary>
	private const int MaxDepth = 6;

	/// <summary>单个结构的字段上限，防止异常数据导致内存暴涨。</summary>
	private const int MaxFields = 500;

	public static MonoFieldsDto Decode(IUnityObjectBase? asset)
	{
		if (asset is null)
		{
			return Unavailable("资源为空。");
		}

		SerializableStructure? structure = TryGetStructure(asset);
		if (structure is null)
		{
			return Unavailable("这个资源没有脚本字段（不是 MonoBehaviour，或元数据里没有它的结构信息）。");
		}

		SerializableValue[] fields = structure.Fields ?? Array.Empty<SerializableValue>();
		if (fields.Length == 0)
		{
			return Unavailable(
				"脚本字段为空。常见原因是 IL2CPP 元数据被加密——字段名和值都没能读出来，" +
				"此时 Prefab 里的组件引用也会失效。");
		}

		List<MonoFieldDto> children = BuildFields(structure.Type, fields, depth: 0);
		string typeName = structure.Type?.FullName ?? "(unknown)";
		MonoFieldDto root = new("$root", typeName, $"{children.Count} 个字段", false, "0", children);
		return new MonoFieldsDto(true, null, children.Count, root);
	}

	private static MonoFieldsDto Unavailable(string message) => new(false, message, 0, null);

	/// <summary>
	/// MonoBehaviour 的脚本数据挂在 <c>Structure</c> 属性上（可能是已解析的
	/// <see cref="SerializableStructure"/>，也可能是待加载的 <see cref="UnloadedStructure"/>）。
	/// 用上游的 <see cref="MonoBehaviourExtensions.LoadStructure"/> 统一处理两种情况：
	/// 它对未加载的结构会尝试按脚本类型重新解析，失败时返回 null。
	/// </summary>
	private static SerializableStructure? TryGetStructure(IUnityObjectBase asset)
	{
		return asset is IMonoBehaviour monoBehaviour ? monoBehaviour.LoadStructure() : null;
	}

	private static List<MonoFieldDto> BuildFields(
		SerializableType? type,
		SerializableValue[] values,
		int depth)
	{
		List<MonoFieldDto> list = new();
		int count = Math.Min(values.Length, MaxFields);

		for (int i = 0; i < count; i++)
		{
			// 字段名与类型来自 Type.Fields，值来自 Fields，两者按索引对应。
			string name = i.ToString(CultureInfo.InvariantCulture);
			SerializableType? fieldType = null;
			if (type is not null && i < type.Fields.Count)
			{
				SerializableType.Field meta = type.Fields[i];
				if (!string.IsNullOrEmpty(meta.Name))
				{
					name = meta.Name;
				}
				fieldType = meta.Type;
			}

			list.Add(ToMonoFieldDto(name, fieldType, values[i], depth));
		}

		if (values.Length > count)
		{
			list.Add(new MonoFieldDto(
				$"... 还有 {values.Length - count} 个字段未显示",
				"", "", false, "0", null));
		}
		return list;
	}

	private static MonoFieldDto ToMonoFieldDto(string name, SerializableType? type, SerializableValue value, int depth)
	{
		string typeName = DescribeType(type);

		// 嵌套结构：子对象或结构体。展开子字段。
		if (value.CValue is SerializableStructure nested)
		{
			if (depth >= MaxDepth)
			{
				return new MonoFieldDto(name, typeName, "(嵌套过深，已截断)", false, "0", null);
			}
			List<MonoFieldDto> children = BuildFields(
				nested.Type, nested.Fields ?? Array.Empty<SerializableValue>(), depth + 1);
			return new MonoFieldDto(name, typeName, $"{{ {children.Count} 个字段 }}", false, "0", children);
		}

		// 对象引用
		if (value.CValue is IPPtr pptr)
		{
			return ToReferenceDto(name, typeName, pptr);
		}

		return new MonoFieldDto(name, typeName, FormatScalar(value, type), false, "0", null);
	}

	private static MonoFieldDto ToReferenceDto(string name, string typeName, IPPtr pptr)
	{
		long pathId = 0;
		try
		{
			pathId = pptr.PathID;
		}
		catch
		{
			// 悬空引用很常见，不该让整个解码失败
		}

		// 解析出被引用资源的名字需要 AssetCollection，而 IPPtr 本身不带。
		// 这里只给出 pathId，前端可以据此在同集合里反查（/api/assets 支持按 pathId 找）。
		string text = pathId == 0 ? "(空引用)" : $"(pathId {pathId})";
		return new MonoFieldDto(name, typeName, text, true, pathId.ToString(CultureInfo.InvariantCulture), null);
	}

	private static string DescribeType(SerializableType? type)
	{
		if (type is null)
		{
			return "?";
		}
		try
		{
			return type.ToString() ?? type.FullName;
		}
		catch
		{
			return type.Name ?? "?";
		}
	}

	/// <summary>
	/// 把标量值转成字符串。
	///
	/// <para><b>关键：原始值在 PValue，不在 CValue。</b>
	/// <see cref="SerializableValue"/> 是个联合体：PValue 存所有标量（按位模式），
	/// CValue 只在对象引用和嵌套结构时有值。直接读 CValue 会得到 null，
	/// 表现为字段名和类型都对、值全是 null。</para>
	///
	/// <para>按 SerializableType 的具体类型决定怎么解释这 8 个字节。</para>
	/// </summary>
	private static string FormatScalar(SerializableValue value, SerializableType? type)
	{
		try
		{
			// 不是标量（对象/结构）的情况已经在上层分流出去了，这里只处理数值与字符串。
			ulong bits = value.PValue;

			// 标量的类型可能是 SerializablePrimitiveType（来自 DLL 元数据），
			// 也可能是 SerializableTreeType（来自 TypeTree）。两者都继承
			// SerializableType，都有 Type 属性，按基类判断才不会漏。
			// （之前只判 SerializablePrimitiveType，导致 TypeTree 来源的数据
			//   落到兜底分支，float 显示成 1065353216 这种原始位模式。）
			if (type is not null && type.Type.IsCSharpPrimitive())
			{
				return type.Type switch
				{
					PrimitiveType.Bool => bits != 0 ? "true" : "false",
					PrimitiveType.Char => ((char)bits).ToString(),
					PrimitiveType.SByte => unchecked((sbyte)bits).ToString(CultureInfo.InvariantCulture),
					PrimitiveType.Byte => ((byte)bits).ToString(CultureInfo.InvariantCulture),
					PrimitiveType.Short => unchecked((short)bits).ToString(CultureInfo.InvariantCulture),
					PrimitiveType.UShort => ((ushort)bits).ToString(CultureInfo.InvariantCulture),
					PrimitiveType.Int => unchecked((int)bits).ToString(CultureInfo.InvariantCulture),
					PrimitiveType.UInt => ((uint)bits).ToString(CultureInfo.InvariantCulture),
					PrimitiveType.Long => unchecked((long)bits).ToString(CultureInfo.InvariantCulture),
					PrimitiveType.ULong => bits.ToString(CultureInfo.InvariantCulture),
					PrimitiveType.Single => BitConverter.Int32BitsToSingle(unchecked((int)bits))
						.ToString("0.####", CultureInfo.InvariantCulture),
					PrimitiveType.Double => BitConverter.Int64BitsToDouble(unchecked((long)bits))
						.ToString("0.####", CultureInfo.InvariantCulture),
					PrimitiveType.String => value.CValue as string ?? "",
					_ => value.CValue?.ToString() ?? bits.ToString(CultureInfo.InvariantCulture),
				};
			}

			// type 缺失（索引越界）或不是标量类型：有对象引用就用，否则给原始位。
			return value.CValue?.ToString() ?? bits.ToString(CultureInfo.InvariantCulture);
		}
		catch (Exception ex)
		{
			return $"(读取失败: {ex.GetType().Name})";
		}
	}
}
