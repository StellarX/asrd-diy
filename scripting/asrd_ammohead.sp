#pragma semicolon 1
#include <sourcemod>
#include <sdktools>

// ============================================================
// asrd_ammohead.sp
// 在指定玩家头顶生成一个"已部署的弹药箱"(asw_ammo_drop)。
//
// 用法:
//   sm_ammohead <目标玩家> [弹药含量%]
//     含量为数字，直接作为弹药箱的 percent_remaining。
//     例子: 100=原版，1000=千倍，999999999=无限。
//     不填默认 100(原版)。
//
// 目标玩家可以是: 玩家昵称片段 / userid / #SteamID。
// 命令解析会遍历所有参数，纯数字视为含量，其余视为目标名，
// 以规避中文昵称与数字粘连导致的编码错位。
// 仅管理员可用。
// ============================================================

#define PLUGIN_VERSION "1.0.0"

#define AMMO_ENTITY       "asw_ammo_drop"
#define AMMO_STD_UNITS    100
#define AMMO_INF_UNITS    999999999
#define HEAD_OFFSET       70.0   // 弹药箱底部相对陆战队员脚底的高度

public Plugin myinfo =
{
	name        = "ASRD Ammo Box on Head",
	author      = "Server Admin",
	description = "在指定玩家头顶生成已部署的弹药箱，弹药量可设标准或无限",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	RegAdminCmd("sm_ammohead", Command_AmmoHead, ADMFLAG_SLAY, "在指定玩家头顶生成弹药箱: sm_ammohead <目标> [含量%]");
}

public Action Command_AmmoHead(int client, int args)
{
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

	char mode[24];
	if (units >= 999999999)
		mode = "无限";
	else if (units == 1000)
		mode = "千倍";
	else if (units == 100)
		mode = "原版";
	else
		Format(mode, sizeof(mode), "%d%%", units);

	// 获取目标玩家正在控制的陆战队员实体
	int marine = GetEntPropEnt(target, Prop_Send, "m_hInhabiting");
	if (marine == -1 || !IsValidEntity(marine) || marine <= MaxClients)
	{
		ReplyToCommand(client, "[头顶弹药箱] 玩家 %N 当前没有可用的陆战队员", target);
		return Plugin_Handled;
	}

	float origin[3];
	GetEntPropVector(marine, Prop_Data, "m_vecAbsOrigin", origin);
	origin[2] += HEAD_OFFSET;

	int ammoBox = CreateEntityByName(AMMO_ENTITY);
	if (ammoBox == -1)
	{
		ReplyToCommand(client, "[头顶弹药箱] 无法创建弹药箱实体");
		return Plugin_Handled;
	}

	char unitsStr[16];
	IntToString(units, unitsStr, sizeof(unitsStr));

	DispatchKeyValue(ammoBox, "percent_remaining", unitsStr);
	DispatchSpawn(ammoBox);
	// 先放到头顶，再父级绑定到陆战队员，此后跟随其位置与朝向
	TeleportEntity(ammoBox, origin, NULL_VECTOR, NULL_VECTOR);
	AttachToParent(ammoBox, marine);

	ReplyToCommand(client, "[头顶弹药箱] 已在 %N 头顶生成弹药箱，模式: %s，弹药单位: %d", target, mode, units);

	return Plugin_Handled;
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