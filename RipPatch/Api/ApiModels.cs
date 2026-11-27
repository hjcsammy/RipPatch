using System.Text.Json.Serialization;

namespace RipPatch.Api;

// JSON 传输对象。全部用 record + 明确的 JSON 属性名，前端不需要猜字段。
// 这些类型只描述「给 UI 看什么」，不映射 AssetRipper 的内部模型，所以不需要
// 跟着子模块的命名走。

/// <summary>应用与运行环境信息。</summary>
public sealed record StatusDto(
	string App,
	string Version,
	string? UnityVersion,
	bool Loaded,
	bool Exporting,
	string? WebView2,
	string? Shell,
	string? SettingsPath);

/// <summary>一次导入的顶层统计。</summary>
public sealed record StatsDto(
	int Collections,
	int Assets,
	int Bundles,
	int Resources,
	int FailedFiles,
	int Scenes);

/// <summary>资源树里的一级节点（bundle 或 collection）。</summary>
public sealed record TreeNodeDto(
	string Id,
	string Kind,
	string Name,
	int? Count,
	IReadOnlyList<TreeNodeDto>? Children);

/// <summary>资源列表中的一行。字段刻意保持精简：列表可能上万行。</summary>
/// <remarks>
/// <b>PathId 用 string 而不是 long。</b>Unity 的 pathId 是 64 位有符号整数，
/// 实际值经常超过 2^53（例如 2945135793888757533），而 JavaScript 的 Number
/// 是 IEEE 754 双精度，只能精确表示到 2^53。用数字传过去会被截断成
/// 2945135793888758000，前端再拿它请求详情就会「找不到资源」。
/// 这类 bug 只在部分资源上出现，特别难查，所以统一按字符串传。
/// </remarks>
public sealed record AssetRowDto(
	string PathId,
	int ClassId,
	string ClassName,
	string Name,
	string Collection,
	string CollectionPath,
	string? OriginalPath,
	string? Extension,
	int? SizeBytes,
	int? Width,
	int? Height,
	string? Preview,
	string? Audio,
	string? Model,
	string? Font,
	string? Video);

/// <summary>分页结果。</summary>
public sealed record PageDto<T>(
	IReadOnlyList<T> Items,
	int Total,
	int Offset,
	int Limit);

/// <summary>资源详情：属性表 + 可用预览。</summary>
public sealed record AssetDetailDto(
	long PathId,
	int ClassId,
	string ClassName,
	string Name,
	string Collection,
	string CollectionPath,
	string? OriginalPath,
	IReadOnlyList<PropertyDto> Properties,
	IReadOnlyList<string> Previews);

public sealed record PropertyDto(string Name, string Value);

/// <summary>
/// MonoBehaviour 字段解码结果。
/// IsAvailable = false 时 Message 说明原因（不是 MonoBehaviour、元数据加密等）。
/// </summary>
public sealed record MonoFieldsDto(
	bool IsAvailable,
	string? Message,
	int FieldCount,
	MonoFieldDto? Root);

/// <summary>一个脚本字段。Children 非空表示可展开。</summary>
public sealed record MonoFieldDto(
	string Name,
	string Type,
	string Value,
	bool IsReference,
	string RefPathId,
	IReadOnlyList<MonoFieldDto>? Children);

/// <summary>Prefab 组件树的一个节点。</summary>
/// <summary>Prefab 组件树的一个节点。PathId 用 string，理由同 AssetRowDto。</summary>
public sealed record ComponentTreeDto(
	string Name,
	string ClassName,
	string PathId,
	string? CollectionPath,
	IReadOnlyList<ComponentTreeDto> Children);

/// <summary>工程健康检查报告。</summary>
public sealed record HealthReportDto(
	int TotalAssets,
	int MonoBehaviourCount,
	int ScriptsResolved,
	int ScriptsMissing,
	int PrefabCount,
	int BrokenReferences,
	IReadOnlyList<HealthIssueDto> Issues);

public sealed record HealthIssueDto(string Severity, string Title, string Detail, int Count);

/// <summary>设置项的一个枚举选项，带显示名和说明。</summary>
public sealed record SettingOptionDto(
	string Value,
	string Label,
	string? Description);

/// <summary>设置项。type 决定前端渲染成什么控件。</summary>
public sealed record SettingDto(
	string Key,
	string Label,
	string? Description,
	string Type,
	string? Value,
	IReadOnlyList<SettingOptionDto>? Options);

public sealed record SettingsDto(
	bool ReadOnly,
	IReadOnlyList<SettingGroupDto> Groups);

public sealed record SettingGroupDto(string Id, IReadOnlyList<SettingDto> Items);

/// <summary>界面文案包：前端启动时拉一次，之后所有标签都从这儿取。</summary>
public sealed record UiTextDto(
	string Language,
	IReadOnlyList<LanguageOptionDto> Languages,
	Dictionary<string, string> Strings);

public sealed record LanguageOptionDto(string Code, string Name);

/// <summary>一条日志。</summary>
public sealed record LogEntryDto(long Seq, string Time, string Level, string Category, string Message);

/// <summary>类名直方图的一项（左侧「资源类型」面板）。</summary>
public sealed record ClassCountDto(string Name, int Count);

/// <summary>前端 → 原生窗口的 IPC 报文。</summary>
public sealed record IpcRequest(string? Id, string? Action, string[]? Args);

/// <summary>原生窗口 → 前端的 IPC 回执。</summary>
public sealed record IpcResponse(string Id, bool Unsupported, bool Canceled, IReadOnlyList<string> Paths);

/// <summary>导出/导入进度。前端轮询或 SSE 读取。</summary>
public sealed record OperationDto(
	string Id,
	string Kind,
	string State,
	double Percent,
	string? Message,
	string? OutputPath,
	string? Error,
	string StartedAt,
	string? FinishedAt);

/// <summary>目录/文件对话框的返回值。</summary>
/// <param name="Unsupported">当前平台/环境不支持原生对话框，前端应退回手输路径。</param>
/// <param name="Canceled">用户取消。</param>
public sealed record DialogResultDto(
	bool Unsupported,
	bool Canceled,
	IReadOnlyList<string> Paths);

// ---- 请求体 ----

public sealed record LoadRequest(string[] Paths);
/// <summary>
/// 整包导出请求。
/// </summary>
/// <param name="OutputPath">输出目录。</param>
/// <param name="CreateSubfolder">true = 在 OutputPath 下再建一个带时间戳的子目录。</param>
/// <param name="Only">
/// 只导出这些类名（逗号分隔，支持 <c>*</c> 通配），例如 <c>Sprite,Texture2D</c>。
/// 为空表示导出全部。与命令行的 <c>--only</c> 等价，依赖默认会一起导出。
/// </param>
/// <param name="Strict">配合 <paramref name="Only"/>：只保留匹配的类型，不跟依赖（引用会断）。</param>
public sealed record ExportRequest(string OutputPath, bool CreateSubfolder, string? Only = null, bool Strict = false);

/// <summary>
/// 单资源导出请求（右键菜单）：把资源写成一个文件放进 OutputPath 目录。
/// 不会删除目录里的任何东西。
/// </summary>
/// <param name="Path">资源的 collectionPath（与其它资源端点同一个标识）。</param>
/// <param name="PathId">资源在集合内的 PathID。</param>
/// <param name="OutputPath">输出目录；为空时后端弹系统选择框，浏览器模式下返回错误。</param>
public sealed record ExportSingleRequest(string Path, long PathId, string? OutputPath);

/// <summary>
/// 单资源导出结果：写出来的那个文件的完整路径。
/// </summary>
public sealed record ExportSingleResult(string FilePath, string Name, string ClassName);

public sealed record SettingsUpdateRequest(Dictionary<string, string?> Values);
public sealed record LanguageRequest(string? Language);

[JsonSerializable(typeof(StatusDto))]
[JsonSerializable(typeof(StatsDto))]
[JsonSerializable(typeof(TreeNodeDto))]
[JsonSerializable(typeof(AssetRowDto))]
[JsonSerializable(typeof(PageDto<AssetRowDto>))]
[JsonSerializable(typeof(AssetDetailDto))]
[JsonSerializable(typeof(PropertyDto))]
[JsonSerializable(typeof(SettingsDto))]
[JsonSerializable(typeof(SettingDto))]
[JsonSerializable(typeof(SettingOptionDto))]
[JsonSerializable(typeof(SettingGroupDto))]
[JsonSerializable(typeof(UiTextDto))]
[JsonSerializable(typeof(LanguageOptionDto))]
[JsonSerializable(typeof(LogEntryDto))]
[JsonSerializable(typeof(OperationDto))]
[JsonSerializable(typeof(ClassCountDto))]
[JsonSerializable(typeof(DialogResultDto))]
[JsonSerializable(typeof(IpcRequest))]
[JsonSerializable(typeof(IpcResponse))]
[JsonSerializable(typeof(LoadRequest))]
[JsonSerializable(typeof(ExportRequest))]
[JsonSerializable(typeof(ExportSingleRequest))]
[JsonSerializable(typeof(ExportSingleResult))]
[JsonSerializable(typeof(SettingsUpdateRequest))]
[JsonSerializable(typeof(LanguageRequest))]
[JsonSerializable(typeof(bool))]
[JsonSerializable(typeof(int))]
[JsonSerializable(typeof(string))]
[JsonSerializable(typeof(string[]))]
[JsonSerializable(typeof(object))]
internal sealed partial class ApiJsonContext : JsonSerializerContext
{
}