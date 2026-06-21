/**
 * ============================================================================
 *  Plugin: [AS:RD] AFK Auto-Kick
 *  
 *  描述: 检测挂机玩家，3分钟无操作自动踢出服务器
 *  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *  
 *  修复内容 (v1.4):
 *    - 新增 OnGameFrame 逐帧检测，解决 AS:RD 中 OnPlayerRunCmd 参数不可靠的问题
 *    - 使用 GetClientAbsOrigin 检测实际位置变化（WASD 移动）
 *    - 使用 GetClientEyeAngles 检测视角变化
 *    - 使用 GetClientButtons 检测按键状态变化
 *    - 添加 AS:RD 特有事件钩子（换弹、放置物品、治疗等）
 *    - 修复浮点数精度比较问题
 *  
 *  功能:
 *    - 追踪玩家最后一次操作时间
 *    - 挂机90秒时发出警告
 *    - 挂机180秒后自动踢出
 *    - 所有时间参数可通过 CVar 实时调整
 *    - 多层活动检测：位置/视角/按键/事件
 *  
 *  安装:
 *    将编译后的 .smx 放入 addons/sourcemod/plugins/
 *  
 *  依赖:
 *    SourceMod 1.11+ (无需 SDKHooks)
 * ============================================================================
 */

#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "AFK Auto Kick"
#define PLUGIN_VERSION "1.4"

// ─── 全局变量 ───────────────────────────────────────────
float g_fLastActivity[MAXPLAYERS + 1];
bool  g_bWarned[MAXPLAYERS + 1];

// OnGameFrame 检测用变量
float g_fLastOrigin[MAXPLAYERS + 1][3];
float g_fLastEyeAngles[MAXPLAYERS + 1][3];
int   g_iLastButtons[MAXPLAYERS + 1];

// ─── CVar 句柄 ──────────────────────────────────────────
ConVar g_cvAFKKickTime;
ConVar g_cvAFKWarnTime;
ConVar g_cvAFKCheckInterval;
ConVar g_cvAFKEnabled;
ConVar g_cvAFKImmuneAdmin;
ConVar g_cvAFKDebug;
ConVar g_cvAFKPosThreshold;   // 位置变化阈值
ConVar g_cvAFKAngleThreshold; // 视角变化阈值

// ─── 定时器 ─────────────────────────────────────────────
Handle g_hCheckTimer      = null;
float  g_fCurrentInterval = 0.0;

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack (AS:RD Fix)",
    description = "自动踢出挂机超过指定时间的玩家（AS:RD 适配版）",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件加载
// ============================================================================
public void OnPluginStart()
{
    g_cvAFKEnabled = CreateConVar(
        "sm_asrd_afk_enabled", "1",
        "启用/禁用 AFK 自动踢人 (0=禁用, 1=启用)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvAFKKickTime = CreateConVar(
        "sm_asrd_afk_kick_time", "180",
        "挂机多少秒后踢出 (默认 180 = 3分钟)",
        FCVAR_NOTIFY, true, 10.0
    );

    g_cvAFKWarnTime = CreateConVar(
        "sm_asrd_afk_warn_time", "90",
        "挂机多少秒后发出警告 (默认 90 = 1.5分钟)",
        FCVAR_NOTIFY, true, 5.0
    );

    g_cvAFKCheckInterval = CreateConVar(
        "sm_asrd_afk_check_interval", "2",
        "检测间隔秒数 (默认 2秒)",
        FCVAR_NOTIFY, true, 1.0, true, 60.0
    );

    g_cvAFKImmuneAdmin = CreateConVar(
        "sm_asrd_afk_immune_admin", "1",
        "是否豁免管理员 (0=不豁免, 1=豁免)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvAFKDebug = CreateConVar(
        "sm_asrd_afk_debug", "0",
        "调试模式，服务器控制台输出检测信息",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    // 位置变化阈值（单位：游戏单位）
    g_cvAFKPosThreshold = CreateConVar(
        "sm_asrd_afk_pos_threshold", "1.0",
        "位置变化检测阈值，超过此值视为活动 (默认 1.0)",
        FCVAR_NOTIFY, true, 0.1
    );

    // 视角变化阈值（单位：度）
    g_cvAFKAngleThreshold = CreateConVar(
        "sm_asrd_afk_angle_threshold", "0.5",
        "视角变化检测阈值，超过此值视为活动 (默认 0.5度)",
        FCVAR_NOTIFY, true, 0.1
    );

    // 启动检测定时器
    g_fCurrentInterval = g_cvAFKCheckInterval.FloatValue;
    g_hCheckTimer = CreateTimer(g_fCurrentInterval, Timer_CheckAFK, _, TIMER_REPEAT);

    // 监听检测间隔变更
    g_cvAFKCheckInterval.AddChangeHook(OnCheckIntervalChanged);

    // 自动生成配置文件
    AutoExecConfig(true, "asrd_afk_kick");

    RegAdminCmd("sm_afkstatus", Command_AFKStatus, ADMFLAG_GENERIC, "查看所有玩家挂机状态");

    // === 标准事件 ===
    HookEventEx("weapon_fire",      Event_PlayerActivity);
    HookEventEx("player_use",       Event_PlayerActivity);
    HookEventEx("player_hurt",      Event_PlayerActivity);
    HookEventEx("player_say",       Event_PlayerActivity);
    HookEventEx("player_chat",      Event_PlayerActivity);

    // === AS:RD 特有事件（核心操作都会触发） ===
    HookEventEx("weapon_reload",           Event_PlayerActivity);
    HookEventEx("weapon_reload_finish",    Event_PlayerActivity);
    HookEventEx("weapon_offhanded",        Event_PlayerActivity);
    HookEventEx("weapon_offhand_activate", Event_PlayerActivity);
    HookEventEx("player_heal",             Event_PlayerActivity);
    HookEventEx("player_heal_target",      Event_PlayerActivity);
    HookEventEx("player_give_ammo",        Event_PlayerActivity);
    HookEventEx("player_deploy_ammo",      Event_PlayerActivity);
    HookEventEx("player_dropped_weapon",   Event_PlayerActivity);
    HookEventEx("marine_selected",         Event_PlayerActivity);
    HookEventEx("ammo_pickup",             Event_PlayerActivity);
    HookEventEx("item_pickup",             Event_PlayerActivity);
    HookEventEx("sentry_placed",           Event_PlayerActivity);
    HookEventEx("sentry_rotated",          Event_PlayerActivity);
    HookEventEx("sentry_dismantled",       Event_PlayerActivity);
    HookEventEx("sentry_start_building",   Event_PlayerActivity);
    HookEventEx("sentry_stop_building",    Event_PlayerActivity);
    HookEventEx("heal_beacon_placed",      Event_PlayerActivity);
    HookEventEx("damage_amplifier_placed", Event_PlayerActivity);
    HookEventEx("laser_mine_placed",       Event_PlayerActivity);
    HookEventEx("gas_grenade_placed",      Event_PlayerActivity);
    HookEventEx("flare_placed",            Event_PlayerActivity);
    HookEventEx("rocket_fired",            Event_PlayerActivity);
    HookEventEx("cluster_grenade_create",  Event_PlayerActivity);
    HookEventEx("tesla_trap_placed",       Event_PlayerActivity);
    HookEventEx("fire_mine_placed",        Event_PlayerActivity);
    HookEventEx("button_area_used",        Event_PlayerActivity);
    HookEventEx("door_recommend_weld",     Event_PlayerActivity);
    HookEventEx("door_recommend_destroy",  Event_PlayerActivity);
    HookEventEx("fast_reload",             Event_PlayerActivity);
    HookEventEx("fast_reload_fail",        Event_PlayerActivity);
    HookEventEx("player_commanding",       Event_PlayerActivity);
    HookEventEx("player_command_follow",   Event_PlayerActivity);
    HookEventEx("player_command_hold",     Event_PlayerActivity);
    HookEventEx("player_alt_fire",         Event_PlayerActivity);
    HookEventEx("alien_died",              Event_PlayerActivity);
    HookEventEx("marine_hurt",             Event_PlayerActivity);
    HookEventEx("marine_healed",           Event_PlayerActivity);
    HookEventEx("marine_ignited",          Event_PlayerActivity);
    HookEventEx("marine_extinguished",     Event_PlayerActivity);
    HookEventEx("marine_infested",         Event_PlayerActivity);
    HookEventEx("marine_infested_cured",   Event_PlayerActivity);
    HookEventEx("marine_no_ammo",          Event_PlayerActivity);

    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClientData(i);
    }
}

public void OnPluginEnd()
{
    if (g_hCheckTimer != null)
    {
        KillTimer(g_hCheckTimer);
        g_hCheckTimer = null;
    }
}

// ============================================================================
//  重置玩家数据
// ============================================================================
void ResetClientData(int client)
{
    g_fLastActivity[client] = 0.0;
    g_bWarned[client]       = false;
    g_fLastOrigin[client]   = view_as<float>({0.0, 0.0, 0.0});
    g_fLastEyeAngles[client]= view_as<float>({0.0, 0.0, 0.0});
    g_iLastButtons[client]  = 0;
}

// ============================================================================
//  CVar 变更：重建定时器
// ============================================================================
public void OnCheckIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    float newInterval = StringToFloat(newValue);
    if (newInterval != g_fCurrentInterval)
    {
        if (g_hCheckTimer != null)
            KillTimer(g_hCheckTimer);

        g_fCurrentInterval = newInterval;
        g_hCheckTimer = CreateTimer(g_fCurrentInterval, Timer_CheckAFK, _, TIMER_REPEAT);
    }
}

// ============================================================================
//  客户端事件
// ============================================================================
public void OnClientPutInServer(int client)
{
    g_fLastActivity[client] = GetGameTime();
    g_bWarned[client]       = false;

    // 初始化位置和角度记录
    if (IsClientInGame(client) && IsPlayerAlive(client))
    {
        GetClientAbsOrigin(client, g_fLastOrigin[client]);
        GetClientEyeAngles(client, g_fLastEyeAngles[client]);
    }
    else
    {
        g_fLastOrigin[client]    = view_as<float>({0.0, 0.0, 0.0});
        g_fLastEyeAngles[client] = view_as<float>({0.0, 0.0, 0.0});
    }
    g_iLastButtons[client] = 0;
}

public void OnClientDisconnect(int client)
{
    ResetClientData(client);
}

// ============================================================================
//  核心修复：OnGameFrame 逐帧检测（绕过 OnPlayerRunCmd 兼容性问题）
// ============================================================================
public void OnGameFrame()
{
    if (!g_cvAFKEnabled.BoolValue)
        return;

    float fGameTime = GetGameTime();
    float posThreshold = g_cvAFKPosThreshold.FloatValue;
    float angleThreshold = g_cvAFKAngleThreshold.FloatValue;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !IsPlayerAlive(i))
            continue;

        bool bActive = false;
        char sReason[128];
        sReason = "";

        // ─── 1. 检测位置变化（WASD 移动） ───
        float fCurrentOrigin[3];
        GetClientAbsOrigin(i, fCurrentOrigin);

        float fPosDiff = GetVectorDistance(g_fLastOrigin[i], fCurrentOrigin);
        if (fPosDiff > posThreshold)
        {
            bActive = true;
            StrCat(sReason, sizeof(sReason), "位置移动 ");
        }

        // ─── 2. 检测视角变化（鼠标瞄准） ───
        float fCurrentAngles[3];
        GetClientEyeAngles(i, fCurrentAngles);

        float fAngleDiff = AngleDistance(g_fLastEyeAngles[i], fCurrentAngles);
        if (fAngleDiff > angleThreshold)
        {
            bActive = true;
            StrCat(sReason, sizeof(sReason), "视角转动 ");
        }

        // ─── 3. 检测按键状态变化 ───
        int iCurrentButtons = GetClientButtons(i);
        if (iCurrentButtons != g_iLastButtons[i])
        {
            bActive = true;
            StrCat(sReason, sizeof(sReason), "按键变化 ");
        }

        // 如果检测到活动，更新时间
        if (bActive)
        {
            g_fLastActivity[i] = fGameTime;
            g_bWarned[i]       = false;

            if (g_cvAFKDebug.BoolValue)
            {
                PrintToServer("[AFK检测-OnGameFrame] 玩家 %N 活动: %s | 位置差: %.2f | 视角差: %.2f | 按钮: %d",
                    i, sReason, fPosDiff, fAngleDiff, iCurrentButtons);
            }
        }

        // 更新记录（无论是否活跃都更新，以便下次比较）
        g_fLastOrigin[i]    = fCurrentOrigin;
        g_fLastEyeAngles[i] = fCurrentAngles;
        g_iLastButtons[i]   = iCurrentButtons;
    }
}

// ============================================================================
//  辅助：计算角度差（处理 360 度环绕）
// ============================================================================
float AngleDistance(float fLast[3], float fCurrent[3])
{
    float fDiff = 0.0;

    for (int i = 0; i < 3; i++)
    {
        float fDelta = FloatAbs(fCurrent[i] - fLast[i]);
        if (fDelta > 180.0)
            fDelta = 360.0 - fDelta;
        fDiff += fDelta * fDelta;
    }

    return SquareRoot(fDiff);
}

// ============================================================================
//  备用检测：聊天消息
// ============================================================================
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (client > 0 && IsClientInGame(client))
    {
        g_fLastActivity[client] = GetGameTime();
        g_bWarned[client]       = false;

        if (g_cvAFKDebug.BoolValue)
            PrintToServer("[AFK检测] 玩家 %N 通过聊天刷新活动时间", client);
    }
    return Plugin_Continue;
}

// ============================================================================
//  备用检测：游戏事件
// ============================================================================
public void Event_PlayerActivity(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
    {
        g_fLastActivity[client] = GetGameTime();
        g_bWarned[client]       = false;

        if (g_cvAFKDebug.BoolValue)
            PrintToServer("[AFK检测-事件] 玩家 %N 通过事件 [%s] 刷新活动时间", client, name);
    }
}

// ============================================================================
//  保留 OnPlayerRunCmd（作为备用，但注明在 AS:RD 中可能不可靠）
// ============================================================================
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse,
    float vel[3], float angles[3],
    int &weapon, int &subtype, int &cmdnum,
    int &tickcount, int &seed, int mouse[2])
{
    if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
        return Plugin_Continue;

    bool bActive = false;

    // 注意：在 AS:RD 中，以下参数可能不被引擎正确填充
    if (FloatCompare(vel[0], 0.0) != 0 || FloatCompare(vel[1], 0.0) != 0 || FloatCompare(vel[2], 0.0) != 0)
        bActive = true;

    if (buttons != 0)
        bActive = true;

    if (impulse != 0)
        bActive = true;

    if (mouse[0] != 0 || mouse[1] != 0)
        bActive = true;

    if (bActive)
    {
        g_fLastActivity[client] = GetGameTime();
        g_bWarned[client]       = false;

        if (g_cvAFKDebug.BoolValue)
        {
            char sReason[128];
            sReason = "";
            if (FloatCompare(vel[0], 0.0) != 0 || FloatCompare(vel[1], 0.0) != 0 || FloatCompare(vel[2], 0.0) != 0)
                StrCat(sReason, sizeof(sReason), "移动 ");
            if (buttons != 0)
                StrCat(sReason, sizeof(sReason), "按键 ");
            if (impulse != 0)
                StrCat(sReason, sizeof(sReason), "脉冲 ");
            if (mouse[0] != 0 || mouse[1] != 0)
                StrCat(sReason, sizeof(sReason), "鼠标 ");

            PrintToServer("[AFK检测-OnPlayerRunCmd] 玩家 %N 活动: %s", client, sReason);
        }
    }

    return Plugin_Continue;
}

// ============================================================================
//  挂机检测定时器
// ============================================================================
public Action Timer_CheckAFK(Handle timer)
{
    if (!g_cvAFKEnabled.BoolValue)
        return Plugin_Continue;

    float fGameTime  = GetGameTime();
    float fKickTime  = g_cvAFKKickTime.FloatValue;
    float fWarnTime  = g_cvAFKWarnTime.FloatValue;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        // 管理员豁免（可通过 CVar 开关）
        if (g_cvAFKImmuneAdmin.BoolValue && CheckCommandAccess(i, "sm_kick", ADMFLAG_KICK))
            continue;

        if (g_fLastActivity[i] <= 0.0)
        {
            g_fLastActivity[i] = fGameTime;
            continue;
        }

        float fIdleTime = fGameTime - g_fLastActivity[i];

        // 调试输出
        if (g_cvAFKDebug.BoolValue)
        {
            PrintToServer("[AFK Debug] %N 挂机: %.1fs (警告线: %.0fs, 踢出线: %.0fs)",
                i, fIdleTime, fWarnTime, fKickTime);
        }

        // --- 达到踢出时间 ---
        if (fIdleTime >= fKickTime)
        {
            char sName[MAX_NAME_LENGTH];
            GetClientName(i, sName, sizeof(sName));

            PrintToChatAll(
                "\x04[AFK系统]\x01 玩家 \x03%s\x01 因挂机超过 \x05%d\x01 秒已被踢出",
                sName, RoundToFloor(fIdleTime)
            );

            LogAction(0, i,
                "\"%L\" was kicked for AFK (idle %.1f seconds)",
                i, fIdleTime
            );

            KickClient(i, "你因挂机超过%d秒而被踢出服务器", RoundToFloor(fIdleTime));
        }
        // --- 达到警告时间（只警告一次） ---
        else if (fIdleTime >= fWarnTime && !g_bWarned[i])
        {
            float fTimeLeft = fKickTime - fIdleTime;

            PrintToChat(i,
                "\x04[AFK警告]\x01 你已挂机 \x05%d\x01 秒！\n如果继续不操作，将在 \x04%d\x01 秒后被踢出",
                RoundToFloor(fIdleTime), RoundToFloor(fTimeLeft)
            );

            PrintCenterText(i,
                "⚠ 挂机警告！%d秒后将被踢出",
                RoundToFloor(fTimeLeft)
            );

            g_bWarned[i] = true;
        }
    }

    return Plugin_Continue;
}

// ============================================================================
//  管理命令：查看挂机状态
// ============================================================================
public Action Command_AFKStatus(int client, int args)
{
    float fGameTime = GetGameTime();
    float fKickTime = g_cvAFKKickTime.FloatValue;
    float fWarnTime = g_cvAFKWarnTime.FloatValue;

    PrintToConsole(client, "========== AFK 状态 (AS:RD 适配版 v%s) ==========", PLUGIN_VERSION);
    PrintToConsole(client, "踢出: %.0fs | 警告: %.0fs | 检测间隔: %.0fs | 位置阈值: %.1f | 视角阈值: %.1f",
        fKickTime, fWarnTime, g_cvAFKCheckInterval.FloatValue,
        g_cvAFKPosThreshold.FloatValue, g_cvAFKAngleThreshold.FloatValue);
    PrintToConsole(client, "检测方式: OnGameFrame(位置/视角/按键) + 事件 + OnPlayerRunCmd(备用)");
    PrintToConsole(client, "------------------------------");

    bool bFound = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        bFound = true;
        float fIdleTime = fGameTime - g_fLastActivity[i];
        char sName[MAX_NAME_LENGTH];
        GetClientName(i, sName, sizeof(sName));

        if (fIdleTime >= fWarnTime)
        {
            PrintToConsole(client, "[⚠] %s - 挂机 %.0f 秒 | 还剩 %.0f 秒踢出",
                sName, fIdleTime, fKickTime - fIdleTime);
        }
        else
        {
            PrintToConsole(client, "[✓] %s - 活跃 (%.0f 秒前)", sName, fIdleTime);
        }
    }

    if (!bFound)
        PrintToConsole(client, "当前没有真实玩家在线");

    PrintToConsole(client, "==============================");

    return Plugin_Handled;
}
