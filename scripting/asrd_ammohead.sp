#pragma semicolon 1
#include <sourcemod>
#include <sdktools>

// ============================================================
// asrd_ammohead.sp
// 在指定玩家头顶生成一个"已部署的弹药箱"(asw_ammo_drop)。
//
// 用法(管理员):
//   sm_ammohead <目标玩家> [弹药含量%]
//     含量为数字, 直接作为弹药箱的 percent_remaining。
//     例子: 100=原版，1000=千倍，999999999=无限。
//     不填默认 100(原版)。
//
// 目标玩家: 玩家昵称片段 / userid / #SteamID。
// 命令解析遍历所有参数, 纯数字视为含量, 其余视为目标名。
// 仅管理员可用。
//
// ── 与积分机制联动 (v1.1.0) ──────────────────────────────
//   积分插件(asrd_points)通过 native ASRDAmmoHead_PlaceDefaultOnClient
//   让玩家用 /buy 7 购买"标准弹药箱"放到自己头顶:
//     - 弹药量固定为游戏默认 (percent_remaining=100, 有限、非无限)
//     - 同一陆战队员头顶同时只能有 1 个弹药箱 (购买会替换旧的)
//     - 除"放到头顶"外, 弹药箱完全沿用游戏原版属性
//   管理员 sm_ammohead 仍可自由指定含量(含无限)与目标 (管理员设置保留)。
//
// ── 头顶唯一性 ───────────────────────────────────────────
//   每次放置前先移除该陆战队员头上已有的 asw_ammo_drop (按父级匹配),
//   保证"同一陆战队员头顶同时只能放一个", 不会叠加。
// ============================================================

#define PLUGIN_VERSION "1.1.0"

#define AMMO_ENTITY       "asw_ammo_drop"
#define AMMO_STD_UNITS    100       // 游戏默认弹药量 (CASW_Ammo_Drop 构造默认 DEFAULT_AMMO_DROP_UNITS = 100)
#define AMMO_INF_UNITS    999999999
#define HEAD_OFFSET       70.0      // 弹药箱底部相对陆战队员脚底的高度

ConVar g_cvEnabled;   // sm_asrd_ammohead_enabled  总开关 (sm_asrd_ammohead_public 由积分插件经 FindConVar 读取, 此处仅注册不保存句柄)

public Plugin myinfo =
{
	name        = "ASRD Ammo Box on Head",
	author      = "Server Admin",
	description = "在指定玩家头顶生成已部署的弹药箱; 支持积分购买(标准弹药/头顶唯一)",
	version     = PLUGIN_VERSION,
	url         = ""
};

// 向积分插件暴露 native: 在 client 自己控制的陆战队员头顶放置"标准(游戏默认)"弹药箱。
// 返回 1=已放置, 0=未放置(无陆战队员/无效)。放置前会移除该 marine 头上已有的箱子(保证唯一)。
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("ASRDAmmoHead_PlaceDefaultOnClient", Native_PlaceDefaultOnClient);
	RegPluginLibrary("asrd_ammohead");
	return APLRes_Success;
}

public void OnPluginStart()
{
	RegAdminCmd("sm_ammohead", Command_AmmoHead, ADMFLAG_SLAY, "在指定玩家头顶生成弹药箱: sm_ammohead <目标> [含量%]");

	g_cvEnabled = CreateConVar("sm_asrd_ammohead_enabled", "1",
		"头顶弹药箱总开关 (0=关 1=开; 关后管理员与积分购买均不可用)",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	CreateConVar("sm_asrd_ammohead_public", "1",
		"是否对玩家开放积分购买 (0=关 1=开; 见 asrd_points 的 /buy 7)",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "asrd_ammohead");
}

// ── native 实现 ──
int Native_PlaceDefaultOnClient(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!IsRealClient(client))
		return 0;
	int marine = GetPlayerMarine(client);
	if (marine <= 0)
		return 0;

	RemoveExistingHeadAmmo(marine);
	int box = CreateHeadAmmoBox(marine, AMMO_STD_UNITS);  // 100 = 游戏默认(有限, 非无限)
	return (box > 0) ? 1 : 0;
}

public Action Command_AmmoHead(int client, int args)
{
	if (!g_cvEnabled.BoolValue)
	{
		ReplyToCommand(client, "[头顶弹药箱] 功能已禁用 (sm_asrd_ammohead_enabled 0)");
		return Plugin_Handled;
	}

	if (args < 1)
	{
		ReplyToCommand(client, "[头顶弹药箱] 用法: sm_ammohead <目标玩家> [弹药含量]");
		ReplyToCommand(client, "[头顶弹药箱] 含量: 数字直接作为弹药箱含量(%),如100=原版，1000=千倍，999999999=无限");
		ReplyToCommand(client, "[头顶弹药箱] 中文昵称请直接输入，数字与昵称间留空格或不加空格均可");
		return Plugin_Handled;
	}

	// 遍历所有参数：纯数字 token 作为弹药含量，其余 token 拼成目标名。
	// 这样即使中文昵称与数字在拷贝时粘连，也能正确分离，规避中文编码错位。
	char targetName[MAX_TARGET_LENGTH];
	targetName[0] = '\0';
	int units = 100;          // 默认原版 100%

	for (int i = 1; i <= args; i++)
	{
		char token[128];
		GetCmdArg(i, token, sizeof(token));
		if (IsNumeric(token))
		{
			units = StringToInt(token);
			if (units < 1)
				units = 1;
		}
		else if (targetName[0] == '\0')
		{
			strcopy(targetName, sizeof(targetName), token);
		}
	}

	if (targetName[0] == '\0')
	{
		ReplyToCommand(client, "[头顶弹药箱] 未识别到目标玩家");
		return Plugin_Handled;
	}

	int target = ResolveTarget(client, targetName);
	if (target == -1)
		return Plugin_Handled;

	int marine = GetPlayerMarine(target);
	if (marine == -1)
	{
		ReplyToCommand(client, "[头顶弹药箱] 玩家 %N 当前没有可用的陆战队员", target);
		return Plugin_Handled;
	}

	char mode[24];
	if (units >= 999999999)
		mode = "无限";
	else if (units == 1000)
		mode = "千倍";
	else if (units == 100)
		mode = "原版";
	else
		Format(mode, sizeof(mode), "%d%%", units);

	// 头顶唯一: 先移除该 marine 已有箱子(管理员再放也替换, 不叠加)
	RemoveExistingHeadAmmo(marine);
	int box = CreateHeadAmmoBox(marine, units);
	if (box == -1)
	{
		ReplyToCommand(client, "[头顶弹药箱] 无法创建弹药箱实体");
		return Plugin_Handled;
	}

	ReplyToCommand(client, "[头顶弹药箱] 已在 %N 头顶生成弹药箱，模式: %s，弹药单位: %d", target, mode, units);

	return Plugin_Handled;
}

// 取玩家当前控制的陆战队员实体 (0=无)。沿用原插件 m_hInhabiting 读法。
static int GetPlayerMarine(int client)
{
	if (!IsRealClient(client))
		return 0;
	int marine = GetEntPropEnt(client, Prop_Send, "m_hInhabiting");
	if (marine == -1 || !IsValidEntity(marine) || marine <= MaxClients)
		return 0;
	return marine;
}

// 在 marine 头顶创建 asw_ammo_drop, percent_remaining=units。返回实体索引(-1=失败)。
static int CreateHeadAmmoBox(int marine, int units)
{
	float origin[3];
	GetEntPropVector(marine, Prop_Data, "m_vecAbsOrigin", origin);
	origin[2] += HEAD_OFFSET;

	int ammoBox = CreateEntityByName(AMMO_ENTITY);
	if (ammoBox == -1)
		return -1;

	char unitsStr[16];
	IntToString(units, unitsStr, sizeof(unitsStr));
	DispatchKeyValue(ammoBox, "percent_remaining", unitsStr);
	DispatchSpawn(ammoBox);
	// 先放到头顶，再父级绑定到陆战队员，此后跟随其位置与朝向
	TeleportEntity(ammoBox, origin, NULL_VECTOR, NULL_VECTOR);
	AttachToParent(ammoBox, marine);
	return ammoBox;
}

// 移除 marine 头上已有的 asw_ammo_drop (按父级匹配),
// 保证同一陆战队员头顶同时只有 1 个 (再放会替换旧的, 不叠加)。
// 注意: 只处理父级==该 marine 的箱子, 不会误伤地面上原版弹药箱或其它玩家头上的箱子。
static void RemoveExistingHeadAmmo(int marine)
{
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, AMMO_ENTITY)) != -1)
	{
		if (GetParentEnt(ent) == marine)
			AcceptEntityInput(ent, "Kill");
	}
}

// 读取实体的父级实体 (兼容本仓库两种字段名: m_hMoveParent / m_pMoveParent)
static int GetParentEnt(int ent)
{
	if (HasEntProp(ent, Prop_Data, "m_hMoveParent"))
	{
		int p = GetEntPropEnt(ent, Prop_Data, "m_hMoveParent");
		if (p > 0)
			return p;
	}
	if (HasEntProp(ent, Prop_Data, "m_pMoveParent"))
	{
		int p = GetEntPropEnt(ent, Prop_Data, "m_pMoveParent");
		if (p > 0)
			return p;
	}
	return -1;
}

// 精确解析目标玩家。修复: 服务器人多时 FindTarget 的模糊/子串匹配会命中多个
// 客户端并报"匹配的客户端数量过多"。这里改为"全名精确匹配优先 + 子串只取唯一命中":
//   - 输入玩家完整中文名 -> 直接唯一命中, 不受服务器人数影响
//   - 纯数字 -> 按 userid 匹配
//   - 子串命中多个 -> 列出候选名单, 提示用更完整昵称/userid
static int ResolveTarget(int client, const char[] target)
{
	if (IsNumeric(target))
	{
		int uid = StringToInt(target);
		int c = (uid > 0) ? GetClientOfUserId(uid) : 0;
		if (c > 0 && IsClientInGame(c))
			return c;
		return -1;
	}

	char matchedNames[MAXPLAYERS + 1][MAX_NAME_LENGTH];
	int matchCount = 0;
	int subMatch = -1;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		char name[MAX_NAME_LENGTH];
		GetClientName(i, name, sizeof(name));

		// 全名精确匹配: 优先返回, 服务器人多也不会误判
		if (StrEqual(name, target, false))
			return i;

		// 子串匹配: 仅记录, 待唯一时才采用
		if (StrContains(name, target, false) != -1)
		{
			if (matchCount <= MAXPLAYERS)
				Format(matchedNames[matchCount], MAX_NAME_LENGTH, "%N", i);
			matchCount++;
			subMatch = i;
		}
	}

	if (matchCount == 1)
		return subMatch;

	if (matchCount > 1)
	{
		char list[MAX_NAME_LENGTH * 8];
		list[0] = '\0';
		for (int i = 0; i < matchCount; i++)
		{
			if (i > 0)
				StrCat(list, sizeof(list), ", ");
			StrCat(list, sizeof(list), matchedNames[i]);
		}
		ReplyToCommand(client, "[头顶弹药箱] \"%s\" 匹配到 %d 个客户端 (%s)，请输入更完整昵称或用 userid 指定", target, matchCount, list);
		return -1;
	}

	ReplyToCommand(client, "[头顶弹药箱] 未找到玩家 \"%s\"", target);
	return -1;
}

// 将 child 父级绑定到 parent(陆战队员)，使其跟随其位置与朝向
static void AttachToParent(int child, int parent)
{
	SetVariantString("!activator");
	AcceptEntityInput(child, "SetParent", parent, parent);
}

// 判断字符串是否全部由十进制数字组成
static bool IsNumeric(const char[] str)
{
	if (str[0] == '\0')
		return false;
	for (int i = 0; str[i] != '\0'; i++)
	{
		if (str[i] < '0' || str[i] > '9')
			return false;
	}
	return true;
}

// 是否为真实玩家(在游戏、非机器人)
static bool IsRealClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}
