/**
 * ============================================================================
 *  [AS:RD] 挂机检测与踢出 (Auto-AFK Kicker)
 *  版本 1.0.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  检测长时间无任何操作(键盘/鼠标)的玩家, 超时后自动踢出, 并支持
 *  服务器通过 ConVar 动态调整超时时间。
 *
 *  判定"操作"的依据(来自引擎 per 客户端 usercmd):
 *    - keyboard:  OnPlayerRunCmd 的 buttons 非 0 (按了任何键)
 *    - mouse:     mouse[0]/mouse[1] 非 0 (鼠标移动)
 *    - use/道具:  impulse 非 0 (按了使用/解包等)
 *  任何一项出现即刷新该玩家的"最后活动时间"。因此只要玩家 5 分钟
 *  内既没按键也没动鼠标, 就会被判定为挂机。
 *
 *  观战玩家同样适用: 观战时引擎依然持续接收该玩家的 usercmd(含视角
 *  移动), 动鼠标/按键会刷新活动时间, 一动不动则照常被判定挂机。
 *  (SourceMod 的 OnPlayerRunCmd 对所有客户端本帧 usercmd 都会触发,
 *   这也是社区 AFK 检测的标准做法。)
 *
 *  ── ConVar (自动生成 cfg/sourcemod/asrd_afk.cfg) ────────
 *   sm_asrd_afk_enabled    总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_afk_timeout    挂机超时时间(秒), 默认 300 = 5 分钟
 *   sm_asrd_afk_interval   检查扫描间隔(秒), 默认 1.0
 *   sm_asrd_afk_warn       踢出前提前多少秒给玩家警告 (0=不警告), 默认 20
 *   sm_asrd_afk_adm_exempt 是否豁免管理员 (0=不豁免 1=豁免, 默认 1)
 *   sm_asrd_afk_version    插件版本号(只读)
 *
 *  命令: sm_afk  查看当前超时设置
 *
 *  依赖: SourceMod 1.11+ (OnPlayerRunCmd 带 mouse[2] 参数), 不依赖扩展。
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

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
bool  g_bWarned[MAXPLAYERS + 1];     // 该玩家是否已收到过挂机警告
Handle g_hCheckTimer = INVALID_HANDLE;

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
        "[AS:RD] 踢出前提前多少秒给玩家警告 (0=不警告), 默认 20");
    g_cvAdmExempt = CreateConVar("sm_asrd_afk_adm_exempt", "0",
        "[AS:RD] 是否豁免管理员 (0=不豁免 1=豁免, 默认 0)");
    CreateConVar("sm_asrd_afk_version", PLUGIN_VERSION,
        "[AS:RD] 挂机检测 插件版本号", FCVAR_NOTIFY);

    // 修改扫描间隔 ConVar 时即时重建定时器, 做到动态调整
    g_cvInterval.AddChangeHook(OnIntervalChanged);

    RegConsoleCmd("sm_afk", Command_AFKStatus, "查看挂机检测的当前超时设置");

    // 非 repeated, 每次回调末尾自行重排, 从而支持间隔动态生效
    if (g_hCheckTimer == INVALID_HANDLE)
        g_hCheckTimer = CreateTimer(g_cvInterval.FloatValue, Timer_AFKCheck);

    AutoExecConfig(true, "asrd_afk");
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
    g_bWarned[client] = false;
}

public void OnClientDisconnect(int client)
{
    g_fLastActive[client] = 0.0;
    g_bWarned[client] = false;
}

// ============================================================================
//  核心: 每一玩家帧回调, 检测键盘/鼠标/使用操作
//  mouse[2] = 本帧鼠标移动量(两轴), 只要动鼠标即为活动状态
// ============================================================================
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse,
        float vel[3], float angles[3], int &weapon, int &subtype,
        int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    // 有按键 / 有鼠标移动 / 有使用操作 → 标记为活动, 重置活动时间与警告
    if (buttons != 0 || mouse[0] != 0 || mouse[1] != 0 || impulse != 0)
    {
        g_fLastActive[client] = GetGameTime();
        if (g_bWarned[client])
            g_bWarned[client] = false;
    }
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
                     (timeout - diff) <= g_cvWarn.FloatValue &&
                     !g_bWarned[client])
            {
                g_bWarned[client] = true;
                PrintToChat(client,
                    "[挂机检测] 你已经 %.0f 秒没有操作, 还差 %.0f 秒将被踢出, 请动一动鼠标或键盘",
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