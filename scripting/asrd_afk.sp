/**
 * ============================================================================
 *  [AS:RD] 挂机检测与踢出 (Auto-AFK Kicker)
 *  版本 1.0.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  检测长时间无任何操作(键盘/鼠标)的玩家, 超时后自动踢出, 并支持
 *  服务器通过 ConVar 动态调整超时时间。
 *
 *  判定"操作"的依据:
 *    - 主线: 每游戏帧(OnGameFrame)比较每个玩家的 视角角度(GetClientEyeAngles)
 *      + 绝对位置(GetClientAbsOrigin)。动鼠标转视角 → 角度变; 游戏内走路/被
 *      传送 → 位置变。任一路有变化即判定为活动。AS:RD 的玩家输入不依赖标准
 *      OnPlayerRunCmd, 故这条主线同时可靠覆盖"游玩中"与"观战/等待"状态。
 *    - 鼠标点击: 监听官方游戏事件 player_shoot / player_alt_fire /
 *      weapon_fire —— 原地点鼠标(不转视角不移动)也能刷新计时。
 *    - 辅助: 保留 OnPlayerRunCmd 读 buttons(按键)/mouse(鼠标)/impulse(使用),
 *      能触发时作为补充通道(如只站在原地按键不转视角)。
 *  任何一项出现即刷新该玩家的"最后活动时间"。因此只要玩家 5 分钟
 *  内既没按键也没动鼠标, 就会被判定为挂机。
 *
 *  观战玩家同样适用: 观战时无自己控制的角色实体, 全靠视角角度变化
 *  (动鼠标转观战视角)来判定活动, 一动不动则照常被判定挂机。
 *
 *  ── ConVar (自动生成 cfg/sourcemod/asrd_afk.cfg) ────────
 *   sm_asrd_afk_enabled    总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_afk_timeout    挂机超时时间(秒), 默认 300 = 5 分钟
 *   sm_asrd_afk_interval   检查扫描间隔(秒), 默认 1.0
 *   sm_asrd_afk_warn       踢出前提前多少秒进入警告窗口, 窗口内每秒
 *                          提醒 (0=不提醒), 默认 20
 *   sm_asrd_afk_adm_exempt 是否豁免管理员 (0=不豁免 1=豁免, 默认 0)
 *   sm_asrd_afk_version    插件版本号(只读)
 *
 *  命令: sm_afk  查看当前超时设置
 *
 *  依赖: SourceMod 1.11+ (OnPlayerRunCmd 带 mouse[2] 参数), 不依赖扩展。
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <events>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Auto-AFK"
#define PLUGIN_VERSION "1.0.0"

ConVar g_cvEnabled;
ConVar g_cvTimeout;
ConVar g_cvInterval;
ConVar g_cvWarn;
ConVar g_cvAdmExempt;

float g_fLastActive[MAXPLAYERS + 1]; // 玩家最后活动时间(游戏时间)
float g_fLastAng[MAXPLAYERS + 1][3]; // 玩家上帧视角角度
float g_fLastPos[MAXPLAYERS + 1][3]; // 玩家上一记录的绝对位置
bool  g_bAngInit[MAXPLAYERS + 1];    // 视角角度是否已初始化
bool  g_bPosInit[MAXPLAYERS + 1];    // 位置是否已初始化
Handle g_hCheckTimer = INVALID_HANDLE;

// 视角角度变化超过该值(度)视为动了鼠标/视角。
// 阈值过小可能把引擎的微小角度噪声误判为活动, 0.5 度足够灵敏又不误报。
#define VIEW_DELTA 0.5
// 位置移动超过该单位视为走动/被传送(游戏内"只走路不转视角"也能识别)。
#define POS_DELTA 5.0

// ============================================================================
//  插件启动
// ============================================================================
public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "asrddiy",
    description = "检测长时间无操作的玩家(含观战)并自动踢出",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("sm_asrd_afk_enabled", "1",
        "[AS:RD] 挂机检测 总开关 (0=关 1=开)");
    g_cvTimeout = CreateConVar("sm_asrd_afk_timeout", "300.0",
        "[AS:RD] 挂机超时时间(秒), 默认 300=5 分钟");
    g_cvInterval = CreateConVar("sm_asrd_afk_interval", "1.0",
        "[AS:RD] 挂机检查扫描间隔(秒), 默认 1.0");
    g_cvWarn = CreateConVar("sm_asrd_afk_warn", "20.0",
        "[AS:RD] 踢出前提前多少秒进入警告窗口, 窗口内每秒提醒 (0=不提醒), 默认 20");
    g_cvAdmExempt = CreateConVar("sm_asrd_afk_adm_exempt", "0",
        "[AS:RD] 是否豁免管理员 (0=不豁免 1=豁免, 默认 0)");
    CreateConVar("sm_asrd_afk_version", PLUGIN_VERSION,
        "[AS:RD] 挂机检测 插件版本号", FCVAR_NOTIFY);

    // 修改扫描间隔 ConVar 时即时重建定时器, 做到动态调整
    g_cvInterval.AddChangeHook(OnIntervalChanged);

    RegConsoleCmd("sm_afk", Command_AFKStatus, "查看挂机检测的当前超时设置");

    // 第三路: 鼠标点击(开火/右键辅助)也能作为活动 —— 听官方游戏事件。
    // 原地点鼠标(不转视角不移动)可通过这一路刷新计时。
    HookEventEx("player_shoot",    Event_Shot, EventHookMode_Post);
    HookEventEx("player_alt_fire", Event_Shot, EventHookMode_Post);
    HookEventEx("weapon_fire",     Event_Shot, EventHookMode_Post);

    // 非 repeated, 每次回调末尾自行重排, 从而支持间隔动态生效
    if (g_hCheckTimer == INVALID_HANDLE)
        g_hCheckTimer = CreateTimer(g_cvInterval.FloatValue, Timer_AFKCheck);

    AutoExecConfig(true, "asrd_afk");
}

// ============================================================================
//  鼠标点击(开火)事件回调: 射出一发子弹 / 右键辅助也算活动
// ============================================================================
public Action Event_Shot(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    if (userid <= 0)
        userid = event.GetInt("attacker");
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
        g_fLastActive[client] = GetGameTime();
    return Plugin_Continue;
}

public void OnPluginEnd()
{
    if (g_hCheckTimer != INVALID_HANDLE)
    {
        KillTimer(g_hCheckTimer);
        g_hCheckTimer = INVALID_HANDLE;
    }
}

public void OnIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    // 重置现有定时器, 让新间隔立即生效
    if (g_hCheckTimer != INVALID_HANDLE)
    {
        KillTimer(g_hCheckTimer);
        g_hCheckTimer = INVALID_HANDLE;
    }
    g_hCheckTimer = CreateTimer(g_cvInterval.FloatValue, Timer_AFKCheck);
}

// ============================================================================
//  玩家进入游戏时初始化其最后活动时间, 防止刚连上就被误判
// ============================================================================
public void OnClientPutInServer(int client)
{
    g_fLastActive[client] = GetGameTime();
    g_bAngInit[client] = false;
    g_bPosInit[client] = false;
}

public void OnClientDisconnect(int client)
{
    g_fLastActive[client] = 0.0;
    g_bAngInit[client] = false;
    g_bPosInit[client] = false;
}

// ============================================================================
//  活动检测: 每游戏帧比较每个玩家的视角角度 + 绝对位置。
//  AS:RD 对玩家输入不依赖标准 OnPlayerRunCmd, 因此仅靠它检测活动在实际
//  游玩中也不可靠; 改用"动鼠标转视角(角度变) / 走路或被传送(位置变)"
//  两路判断, 游戏内与观战都覆盖。任一路有变化即刷新最后活动时间。
// ============================================================================
public void OnGameFrame()
{
    if (!g_cvEnabled.BoolValue)
        return;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            g_bAngInit[client] = false;
            g_bPosInit[client] = false;
            continue;
        }

        bool bActive = false;

        // 路1: 视角角度变化(动鼠标转视角, 游戏内与观战通用)
        float ang[3];
        GetClientEyeAngles(client, ang);
        if (g_bAngInit[client])
        {
            if (FloatAbs(ang[0] - g_fLastAng[client][0]) > VIEW_DELTA ||
                FloatAbs(ang[1] - g_fLastAng[client][1]) > VIEW_DELTA)
                bActive = true;
        }
        else
        {
            g_bAngInit[client] = true;
        }
        g_fLastAng[client][0] = ang[0];
        g_fLastAng[client][1] = ang[1];
        g_fLastAng[client][2] = ang[2];

        // 路2: 位置移动(游戏内走路/被传送)
        float pos[3];
        GetClientAbsOrigin(client, pos);
        if (g_bPosInit[client])
        {
            if (GetVectorDistance(pos, g_fLastPos[client]) > POS_DELTA)
                bActive = true;
        }
        else
        {
            g_bPosInit[client] = true;
        }
        g_fLastPos[client][0] = pos[0];
        g_fLastPos[client][1] = pos[1];
        g_fLastPos[client][2] = pos[2];

        // 活动 → 刷新最后活动时间; 刷新后即离开警告窗口, 提醒自动停止并重新计时
        if (bActive)
            g_fLastActive[client] = GetGameTime();
    }
}

// ============================================================================
//  核心: 每一玩家帧回调, 检测键盘/鼠标/使用操作
//  mouse[2] = 本帧鼠标移动量(两轴), 只要动鼠标即为活动状态
// ============================================================================
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse,
        float vel[3], float angles[3], int &weapon, int &subtype,
        int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    // 有按键 / 有鼠标移动 / 有使用操作 → 刷新活动时间。
    // 刷新后离开警告窗口, 每秒提醒随之自动停止(见 Timer_AFKCheck)。
    if (buttons != 0 || mouse[0] != 0 || mouse[1] != 0 || impulse != 0)
        g_fLastActive[client] = GetGameTime();
    return Plugin_Continue;
}

// ============================================================================
//  周期扫描: 判定挂机 → 先警告, 超过超时时间则踢出
//  每次执行后自行重排, 间隔取自 ConVar, 支持动态调整
// ============================================================================
public Action Timer_AFKCheck(Handle timer)
{
    float now = GetGameTime();
    float timeout = g_cvTimeout.FloatValue;

    if (timeout > 0.0 && g_cvEnabled.BoolValue)
    {
        for (int client = 1; client <= MaxClients; client++)
        {
            // 只看真实在线玩家, 跳过机器人
            if (client > MaxClients || !IsClientInGame(client) ||
                IsFakeClient(client) || g_fLastActive[client] <= 0.0)
                continue;

            // 管理员豁免
            if (g_cvAdmExempt.BoolValue &&
                GetAdminFlag(GetUserAdmin(client), Admin_Generic))
                continue;

            float diff = now - g_fLastActive[client];

            if (diff >= timeout)
            {
                char name[64];
                GetClientName(client, name, sizeof(name));
                KickClient(client,
                    "长时间未操作(%.0f 秒)被判定挂机, 已被自动踢出, 欢迎重连", timeout);
                PrintToServer("[挂机检测] 已踢出挂机玩家 %s (idle %.0fs / %.0fs)",
                    name, diff, timeout);
            }
            else if (g_cvWarn.FloatValue > 0.0 &&
                     (timeout - diff) <= g_cvWarn.FloatValue)
            {
                // 警告窗口内(默认踢出前 20 秒)每次扫描都提醒一次。
                // 默认扫描间隔 1 秒 → 等效于每秒提醒。
                PrintToChat(client,
                    "[挂机检测] 你已经 %.0f 秒没有操作, 还有 %.0f 秒将被踢出, 请动一动鼠标或键盘",
                    diff, timeout - diff);
            }
        }
    }

    // 自行重排下一次, 支持动态间隔
    g_hCheckTimer = CreateTimer(g_cvInterval.FloatValue, Timer_AFKCheck);
    return Plugin_Handled;
}

public Action Command_AFKStatus(int client, int args)
{
    ReplyToCommand(client,
        "[挂机检测] 超时: %.0f 秒 (%.1f 分钟) | 警告提前: %.0f 秒 | 启用: %s",
        g_cvTimeout.FloatValue, g_cvTimeout.FloatValue / 60.0,
        g_cvWarn.FloatValue, g_cvEnabled.BoolValue ? "是" : "否");
    return Plugin_Handled;
}