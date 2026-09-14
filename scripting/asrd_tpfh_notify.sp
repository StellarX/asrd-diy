/**
 * ============================================================================
 *  [AS:RD] TPFH 复活/传送 提示 (Notice)
 *  版本 1.0.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  在聊天框向玩家提示: 可以用 /fh 复活、用 /tp 传送到队友身边, 每局仅限一次
 *  (TPFH 命令本身由第三方/其他插件提供, 本插件只负责播报提示, 不实现命令)。
 *
 *  触发时机(每个都会向对应玩家发送一条定向聊天提示, 不影响全服他人):
 *    1. 玩家连接到服务器并进入游戏时 (OnClientPutInServer, 延迟确保客户端就绪)
 *    2. 玩家在游戏中阵亡时 (官方事件 player_death)
 *
 *  ── ConVar (自动生成 cfg/sourcemod/asrd_tpfh_notify.cfg) ─
 *   sm_asrd_tpfh_enabled     总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_tpfh_on_connect  玩家连入服务器时是否提示 (0=关 1=开, 默认 1)
 *   sm_asrd_tpfh_on_death    玩家在游戏中阵亡时是否提示 (0=关 1=开, 默认 1)
 *   sm_asrd_tpfh_message     提示正文(可用 {44}... 或原生颜色码穿插入聊天),
 *                            默认 "输入/fh复活，输入/tp传送到队友身边，每局仅限一次。"
 *   sm_asrd_tpfh_version     插件版本号(只读)
 *
 *  依赖: SourceMod 1.10+ (ForTranslatableString 不依赖), 不依赖扩展。
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <events>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] TPFH Notice"
#define PLUGIN_VERSION "1.0.0"

// 提示前缀(带 AS:RD 主题色 \x04), 便于在聊天流里一眼识别
#define NOTIFY_PREFIX  "\x04[TPFH]\x01 "

ConVar g_cvEnabled;
ConVar g_cvOnConnect;
ConVar g_cvOnDeath;
ConVar g_cvMessage;

// ============================================================================
//  插件启动
// ============================================================================
public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "asrddiy",
    description = "在聊天框向玩家提示可用 /fh 复活、/tp 传送(每局仅限一次)",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("sm_asrd_tpfh_enabled", "1",
        "[AS:RD] TPFH 提示 总开关 (0=关 1=开)");
    g_cvOnConnect = CreateConVar("sm_asrd_tpfh_on_connect", "1",
        "[AS:RD] 玩家连入服务器进入游戏时是否提示 (0=关 1=开)");
    g_cvOnDeath = CreateConVar("sm_asrd_tpfh_on_death", "1",
        "[AS:RD] 玩家在游戏中阵亡时是否提示 (0=关 1=开)");
    g_cvMessage = CreateConVar("sm_asrd_tpfh_message",
        "输入/fh复活，输入/tp传送到队友身边，每局仅限一次。",
        "[AS:RD] TPFH 提示正文", FCVAR_NOTIFY);
    CreateConVar("sm_asrd_tpfh_version", PLUGIN_VERSION,
        "[AS:RD] TPFH 提示 插件版本号", FCVAR_NOTIFY);

    HookEventEx("player_death", Event_PlayerDeath, EventHookMode_Post);

    AutoExecConfig(true, "asrd_tpfh_notify");
}

// ============================================================================
//  触发点 1: 玩家连接并进入游戏时提示。
//  PutInServer 瞬间客户端可能尚未完全就绪(聊天消息有时不显示), 故延迟 1 秒。
// ============================================================================
public void OnClientPutInServer(int client)
{
    if (client <= 0 || client > MaxClients)
        return;
    if (!g_cvEnabled.BoolValue || !g_cvOnConnect.BoolValue)
        return;
    if (IsFakeClient(client))
        return;

    CreateTimer(1.0, Timer_SendNotice, client);
}

public Action Timer_SendNotice(Handle timer, int client)
{
    if (!g_cvEnabled.BoolValue || !g_cvOnConnect.BoolValue)
        return Plugin_Stop;
    if (!IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Stop;

    SendNotice(client);
    return Plugin_Stop;
}

// ============================================================================
//  触发点 2: 玩家在游戏中阵亡时提示。
// ============================================================================
public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue || !g_cvOnDeath.BoolValue)
        return Plugin_Continue;

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Continue;

    SendNotice(client);
    return Plugin_Continue;
}

// ============================================================================
//  发送提示: 取配置正文, 前插主题色标签, 定向发给触发玩家本人
// ============================================================================
static void SendNotice(int client)
{
    char szMsg[512];
    g_cvMessage.GetString(szMsg, sizeof(szMsg));
    if (szMsg[0] == '\0')
        szMsg = "输入/fh复活，输入/tp传送到队友身边，每局仅限一次。";

    PrintToChat(client, "%s%s", NOTIFY_PREFIX, szMsg);
    PrintToConsole(client, "[TPFH] %s", szMsg);
}