/**
 * ============================================================================
 *  [AS:RD] 全民开锁 / 非技术员也能破解 (Hack For Everyone)
 *  版本 1.1.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  AS:RD 默认规则里,"破解门锁"(开锁)要求操作者是有 [技术员] 能力的陆战队员
 *  (marine profile CanHack()==true)。很多自定义挑战通过让所有人都能开锁来通关。
 *
 *  实现用两条通道(双保险), 默认关闭, 由管理员开启:
 *
 *  通道①: 打开官方 ConVar rd_hackall = 1
 *     asw_marine_profile.h  CanHack(): return GetMarineClass()==MARINE_CLASS_TECH
 *                                      || rd_hackall.GetBool();
 *     这是服务端判定的唯一权威开关: rd_hackall=1 后所有职业 CanHack() 都返回
 *     true。它同时覆盖 门锁按钮区 与 电脑终端 两处的破解(两处都走 CanHack())。
 *     它带 FCVAR_CHEAT, 但服务端用 SourceMod 写不依赖 sv_cheats, 直接生效。
 *
 *  通道②: 把每个门锁按钮区 m_bNeedsTech 清 0
 *     asw_button_area.cpp   ActivateUseIcon: if( CanHack() || !m_bNeedsTech )
 *     c_asw_button_area.cpp GetUseAction:    if( CanHack() || !NeedsTech() )
 *     m_bNeedsTech 是两侧同步的普通网络属性(server SendPropBool / client
 *     RecvPropBool), 服务端改完会可靠下发客户端。这条保证即使客户端收不到
 *     cheat 型的 rd_hackall, 客户端提示也会从"需要技术员"变成"破解面板",
 *     且原地弹出破解小游戏。等价于官方挑战把 needstech 置 false。
 *
 *  ── 设计要点 ──────────────────────────────────────────
 *  - 只把 m_bNeedsTech 原本 ==1 的按钮区清成 0 并记录原值; 地图里本来就
 *    needstech false 的按钮区不会被"还原成需要技术员"。
 *  - 关闭时精确还原: 还原被改过的按钮区 + 把 rd_hackall 设回它的原值。
 *  - 默认关闭 (sm_asrd_hackall_enabled=0), 管理员可命令或 ConVar 开启。
 *  - 换图会自动对当前地图重新应用。
 *
 *  ── 管理员命令 (需 ADMFLAG_GENERIC) ────────────────────
 *   sm_hackall           不带参数 = 在 开/关 间切换
 *   sm_hackall on        开启 (1)
 *   sm_hackall off       关闭 (0)
 *   sm_hackall_status    诊断: 列出 rd_hackall 值、按钮区数量/锁状态/是否已改
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_hackall.cfg) ─
 *   sm_asrd_hackall_enabled    总开关 (0=关 1=开, 默认 0=关)
 *   sm_asrd_hackall_debug      调试输出 (0=关 1=开)
 *
 *  依赖: SourceMod 1.11+ (不依赖任何扩展)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Hack For Everyone"
#define PLUGIN_VERSION "1.1.0"

// 上锁按钮区的引擎类名, 即"需要破解的门锁面板"实体。
#define ENT_BUTTON_AREA "trigger_asw_button_area"

// "需要技术员" 标志(服务端/客户端两端都用它做能否破解的判定)。
#define PROP_NEEDS_TECH "m_bNeedsTech"

ConVar g_cvEnabled;
ConVar g_cvDebug;

// 官方"所有人可破解"开关。带 FCVAR_CHEAT, 服务端 SourceMod 直接可写。
ConVar g_cvRDHackAll;
bool   g_bRdHackAllOrig;   // 插件加载时 rd_hackall 的原值, 关闭时还原

// 记录被本插件从 1 清成 0 的按钮区(存实体引用 SEntRef + 原值)。
// 每项占 2 个格子: [0]=entref [1]=原值。关闭时按记录精确还原。
ArrayList g_Changed;

// ============================================================================
//  插件启动
// ============================================================================
public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "asrddiy",
    description = "让非技术员也能破解门锁/电脑(开锁); 默认关闭, 管理员可开启",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_Changed = new ArrayList(2);

    g_cvEnabled = CreateConVar("sm_asrd_hackall_enabled", "0",
        "[AS:RD] 全民开锁 总开关 (0=关 1=开, 默认 0=关; 开启后任意职业都能破解)");
    g_cvDebug = CreateConVar("sm_asrd_hackall_debug", "0",
        "[AS:RD] 全民开锁 调试输出 (0=关 1=开)");
    CreateConVar("sm_asrd_hackall_version", PLUGIN_VERSION,
        "[AS:RD] 全民开锁 插件版本号", FCVAR_NOTIFY);

    g_cvEnabled.AddChangeHook(ConVarChanged_Enabled);

    // 记下官方 rd_hackall 的原值, 以便关闭时还原
    g_cvRDHackAll = FindConVar("rd_hackall");
    if (g_cvRDHackAll != null)
        g_bRdHackAllOrig = g_cvRDHackAll.IntValue != 0;

    RegAdminCmd("sm_hackall", Command_HackAll, ADMFLAG_GENERIC,
        "开启/关闭 全民开锁: sm_hackall [on|off|1|0] (不带参数=切换)");
    RegAdminCmd("sm_hackall_status", Command_HackAllStatus, ADMFLAG_GENERIC,
        "诊断 全民开锁: 显示 rd_hackall 与按钮区状态");

    AutoExecConfig(true, "asrd_hackall");
}

public void OnMapStart()
{
    // 换图后按钮区网络属性会重置为地图默认, 需要重新应用。
    g_Changed.Clear();
    if (g_cvEnabled.BoolValue)
        ApplyAll();
}

// 地图里/脚本里可能动态生成门锁按钮区, 生成后同样清除其技术员限制。
public void OnEntitySpawned(int entity)
{
    if (!g_cvEnabled.BoolValue)
        return;
    if (!IsButtonArea(entity))
        return;
    ApplyToArea(entity);
}

// ============================================================================
//  开启/关闭
// ============================================================================
void ConVarChanged_Enabled(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (convar.BoolValue)
    {
        ApplyAll();
        if (g_cvDebug.BoolValue)
            PrintToServer("[全民开锁] 已开启");
    }
    else
    {
        RestoreAll();
        if (g_cvDebug.BoolValue)
            PrintToServer("[全民开锁] 已关闭并还原");
    }
}

// 开启: 打开 rd_hackall(覆盖门锁+电脑), 再清场上门锁按钮区的技术员限制。
void ApplyAll()
{
    if (g_cvRDHackAll != null)
    {
        g_cvRDHackAll.IntValue = 1;
        if (g_cvDebug.BoolValue)
            PrintToServer("[全民开锁] 已把 rd_hackall 设为 1 (当前值=%d)", g_cvRDHackAll.IntValue);
    }
    else if (g_cvDebug.BoolValue)
        PrintToServer("[全民开锁] 警告: 找不到 rd_hackall ConVar, 仅靠按钮区属性通道");

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, ENT_BUTTON_AREA)) != -1)
        ApplyToArea(ent);
}

// 关闭: 还原被改过的按钮区, 并把 rd_hackall 设回原值。
void RestoreAll()
{
    for (int i = 0; i < g_Changed.Length; i += 2)
    {
        int ref = g_Changed.Get(i);
        int orig = g_Changed.Get(i + 1);
        int ent = EntRefToEntIndex(ref);
        if (ent != INVALID_ENT_REFERENCE && IsButtonArea(ent))
            SetEntProp(ent, Prop_Send, PROP_NEEDS_TECH, orig);
    }
    g_Changed.Clear();

    if (g_cvRDHackAll != null)
    {
        g_cvRDHackAll.IntValue = g_bRdHackAllOrig ? 1 : 0;
        if (g_cvDebug.BoolValue)
            PrintToServer("[全民开锁] 已把 rd_hackall 还原为 %d", g_cvRDHackAll.IntValue);
    }
}

// ============================================================================
//  工具函数
// ============================================================================
bool IsButtonArea(int ent)
{
    char sClassName[64];
    return IsValidEntity(ent) && GetEntityClassname(ent, sClassName, sizeof(sClassName))
        && StrEqual(sClassName, ENT_BUTTON_AREA);
}

int FindTracked(int ent)
{
    int ref = EntIndexToEntRef(ent);
    for (int i = 0; i < g_Changed.Length; i += 2)
    {
        if (g_Changed.Get(i) == ref)
            return i;
    }
    return -1;
}

// 清单个按钮区的技术员限制并记录原值。原本就不需要技术员的(needstech 已为
// false)不处理、不记录, 避免关闭时把它误改回 true。
void ApplyToArea(int ent)
{
    if (!IsButtonArea(ent))
        return;

    int orig = GetEntProp(ent, Prop_Send, PROP_NEEDS_TECH);
    if (orig == 0)
        return;

    if (FindTracked(ent) != -1)
    {
        SetEntProp(ent, Prop_Send, PROP_NEEDS_TECH, 0);
        return;
    }

    g_Changed.Push(EntIndexToEntRef(ent));
    g_Changed.Push(orig);
    SetEntProp(ent, Prop_Send, PROP_NEEDS_TECH, 0);

    if (g_cvDebug.BoolValue)
        PrintToServer("[全民开锁] 清除按钮区 #%d 的技术员限制", ent);
}

// ============================================================================
//  管理员命令 sm_hackall
// ============================================================================
public Action Command_HackAll(int client, int args)
{
    if (!CheckCommandAccess(client, "sm_hackall", ADMFLAG_GENERIC))
    {
        ReplyToCommand(client, "[全民开锁] 权限不足");
        return Plugin_Handled;
    }

    if (args >= 1)
    {
        char sArg[16];
        GetCmdArg(1, sArg, sizeof(sArg));

        if (StrEqual(sArg, "on") || StrEqual(sArg, "1"))
            g_cvEnabled.SetBool(true);
        else if (StrEqual(sArg, "off") || StrEqual(sArg, "0"))
            g_cvEnabled.SetBool(false);
        else
        {
            ReplyToCommand(client,
                "[全民开锁] 用法: sm_hackall [on|off|1|0] (不带参数 = 切换); 当前状态: %s",
                g_cvEnabled.BoolValue ? "开" : "关");
            return Plugin_Handled;
        }
    }
    else
    {
        g_cvEnabled.SetBool(!g_cvEnabled.BoolValue);   // 不带参数: 切换
    }

    ReplyToCommand(client,
        "[全民开锁] 已%s。rd_hackall=%d, 已解除 %d 个门锁按钮区的技术员限制, 任意职业现在均可破解门锁/电脑。",
        g_cvEnabled.BoolValue ? "开启" : "关闭(已还原)",
        g_cvRDHackAll == null ? -1 : g_cvRDHackAll.IntValue,
        CountTracked());

    LogMessage("管理员 %s 将全民开锁置为 %s",
        client > 0 && IsClientInGame(client) ? "玩家" : "控制台",
        g_cvEnabled.BoolValue ? "开" : "关");
    return Plugin_Handled;
}

// ============================================================================
//  诊断命令 sm_hackall_status (排查"开了但没生效")
// ============================================================================
public Action Command_HackAllStatus(int client, int args)
{
    if (!CheckCommandAccess(client, "sm_hackall_status", ADMFLAG_GENERIC))
    {
        ReplyToCommand(client, "[全民开锁] 权限不足");
        return Plugin_Handled;
    }

    PrintToConsole(client, "========== [全民开锁] 诊断 (v%s) ==========", PLUGIN_VERSION);
    PrintToConsole(client, "本插件总开关 enabled  = %s", g_cvEnabled.BoolValue ? "开" : "关");

    if (g_cvRDHackAll == null)
    {
        PrintToConsole(client, "rd_hackall ConVar     = 找不到! (引擎未注册?)");
    }
    else
    {
        PrintToConsole(client, "rd_hackall ConVar     = %d (加载插件时原值=%d)",
            g_cvRDHackAll.IntValue, g_bRdHackAllOrig ? 1 : 0);
        PrintToConsole(client, "  说明: =1 表示任意职业 CanHack() 都返回真(门锁+电脑都能破解)");
    }

    // 扫描场上所有门锁按钮区, 列出锁状态与 needstech 状态
    int nAreas = 0, nLocked = 0, nNeedsTech = 0, nChanged = 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, ENT_BUTTON_AREA)) != -1)
    {
        nAreas++;
        int locked = GetEntProp(ent, Prop_Send, "m_bIsLocked");
        if (locked) nLocked++;
        int needs = GetEntProp(ent, Prop_Send, PROP_NEEDS_TECH);
        if (needs) nNeedsTech++;
        if (FindTracked(ent) != -1) nChanged++;

        if (g_cvDebug.BoolValue)
            PrintToServer("[全民开锁] status: 按钮区#%d 锁=%d 需要技术员=%d",
                ent, locked, needs);
    }
    PrintToConsole(client, "场上门锁按钮区        = %d 个 (其中 %d 个上锁, %d 个仍带'需要技术员'限制, 本插件已清除 %d 个)",
        nAreas, nLocked, nNeedsTech, nChanged);

    if (nAreas == 0)
        PrintToConsole(client, "⚠ 当前地图没有任何 trigger_asw_button_area —— 该图的门可能不走'按钮破解', 而是用焊接器切门(走 asw_door_area/welder)!");
    else if (nNeedsTech > 0 && g_cvEnabled.BoolValue)
        PrintToConsole(client, "⚠ 仍有个别按钮区带技术员限制(可能为插件启用前已生成且未被覆盖), 请重试 sm_hackall on 或换图");

    PrintToConsole(client, "--------------------------------------------------");
    return Plugin_Handled;
}

int CountTracked()
{
    return g_Changed.Length / 2;
}

// ============================================================================
//  插件卸载: 还原所有本插件修改, 避免残留
// ============================================================================
public void OnPluginEnd()
{
    RestoreAll();
}