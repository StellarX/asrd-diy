/**
 * ============================================================================
 *  [AS:RD] 一键开锁 (Auto Unlock)
 *  版本 1.0.3  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  AS:RD 里"破解大门"是一个 mini-game: 地图上的门锁用实体
 *  trigger_asw_button_area (引擎类 CASW_Button_Area) 表示, 配上
 *  asw_hack_wire_tile(连线拼图) / asw_hack_computer(转盘) 两种破解小游戏。
 *  破解完成后游戏调用 InputUnlock 把门置为"已解锁"(m_bIsLocked=false,
 *  m_fHackProgress=1.0), 门才打开、任务才能继续。
 *
 *  本插件一键向目标按钮区发 AcceptEntityInput "Unlock", 直接触发引擎自带
 *  的"破解完成"解锁逻辑(InputUnlock), 实现绕过 mini-game 的开锁。
 *
 *  ── 玩家命令 (控制台输入, 或在聊天栏加 ! 前缀) ───────────
 *   sm_unlock            解锁操作者 unlock_range 内最近的一扇上锁按钮区。
 *                        范围默认设得很小, 必须贴脸靠近门锁才能解,
 *                        不做全图/大范围自动解锁。
 *
 *  ── 管理员命令 (需 ADMFLAG_GENERIC) ────────────────────
 *   sm_unlock_all        解锁整张地图所有上锁的按钮区
 *   sm_unlock_status     在控制台列出场上每个按钮区的锁/电状态(排查用)
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_unlock.cfg) ─
 *   sm_asrd_unlock_enabled     总开关 (0=关 1=开)
 *   sm_asrd_unlock_public      允许普通玩家用 sm_unlock (0=仅管理员 1=公开)
 *   sm_asrd_unlock_range       玩家 sm_unlock 的最大可解锁距离(世界单位)
 *   sm_asrd_unlock_forcepower  断电的门先送 PowerOn 再解锁(1=开 0=只解锁)
 *   sm_asrd_unlock_debug       调试输出 (0/1)
 *
 *  依赖: SourceMod 1.11+ (不依赖任何扩展)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Auto Unlock"
#define PLUGIN_VERSION "1.0.3"

// 上锁按钮区的引擎类名。该实体支持输入 "Unlock"(InputUnlock)。
#define ENT_BUTTON_AREA "trigger_asw_button_area"

// 锁/电源状态用网络属性读(引擎内都是 CNetworkVar)。
#define PROP_LOCKED   "m_bIsLocked"
#define PROP_NOPOWER  "m_bNoPower"

ConVar g_cvEnabled;
ConVar g_cvPublic;
ConVar g_cvRange;
ConVar g_cvForcePower;
ConVar g_cvDebug;

// 各统计计数, 供命令回显
int g_iMatch;   // 匹配到的上锁按钮区数
int g_iUnlocked;// 实际执行解锁的个数

// ============================================================================
//  插件启动: 注册 ConVar 与命令
// ============================================================================
public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "asrddiy",
    description = "一键破解 AS:RD 门锁 mini-game, 直接解锁大门",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    // 初始化计数
    g_iMatch = 0;
    g_iUnlocked = 0;

    g_cvEnabled = CreateConVar("sm_asrd_unlock_enabled", "1",
        "[AS:RD] 一键开锁 总开关 (0=关 1=开)");
    g_cvPublic = CreateConVar("sm_asrd_unlock_public", "1",
        "[AS:RD] 允许普通玩家使用 sm_unlock (0=仅管理员 1=公开)");
    g_cvRange = CreateConVar("sm_asrd_unlock_range", "150.0",
        "[AS:RD] 玩家 sm_unlock 的附近解锁范围(世界单位), 默认必须靠近门锁, 0=不限");
    g_cvForcePower = CreateConVar("sm_asrd_unlock_forcepower", "1",
        "[AS:RD] 断电的门先送 PowerOn 再解锁 (0=只解锁)");
    g_cvDebug = CreateConVar("sm_asrd_unlock_debug", "0",
        "[AS:RD] 调试输出 (0=关 1=开)");
    CreateConVar("sm_asrd_unlock_version", PLUGIN_VERSION,
        "[AS:RD] 一键开锁 插件版本号", FCVAR_NOTIFY);

    RegConsoleCmd("sm_unlock", Command_Unlock,    "解锁附近靠得最近的上锁按钮区");
    RegConsoleCmd("sm_unlock_all", Command_UnlockAll, "解锁全图上锁按钮区(管理员)");
    RegConsoleCmd("sm_unlock_status", Command_Status, "列出场上按钮区状态(管理员)");

    AutoExecConfig(true, "asrd_unlock");
}

// ============================================================================
//  查找玩家当前控制的 marine 实体 (失败返回 0)
//  复制自项目内公共做法: 依次尝试网络属性/数据属性, 最后遍历 marine 匹配指挥官
// ============================================================================
int GetPlayerMarine(int client)
{
    if (client <= 0 || !IsClientInGame(client))
        return 0;

    char sNetClass[64];
    if (GetEntityNetClass(client, sNetClass, sizeof(sNetClass))
        && FindSendPropInfo(sNetClass, "m_hInhabiting") > 0)
    {
        int iMarine = GetEntPropEnt(client, Prop_Send, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    if (FindDataMapInfo(client, "m_hInhabiting") > 0)
    {
        int iMarine = GetEntPropEnt(client, Prop_Data, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "asw_marine")) != -1)
    {
        if (FindDataMapInfo(ent, "m_hCommander") > 0
            && GetEntPropEnt(ent, Prop_Data, "m_hCommander") == client)
            return ent;
    }

    return 0;
}

// ============================================================================
//  读一个按钮区的锁状态 (1=上锁). 读不到属性视为 0(不处理)
//  InputUnlock 内部同样会检查 m_bIsLocked, 这里先过滤可避免无谓调用。
//  注意: 必须先确认实体是按钮区再读属性, 否则对普通实体取不存在的
//  m_bIsLocked 会往日志刷 "property not found" 报错。
// ============================================================================
bool IsButtonArea(int ent)
{
    char sClassName[64];
    return IsValidEntity(ent) && GetEntityClassname(ent, sClassName, sizeof(sClassName))
        && StrEqual(sClassName, ENT_BUTTON_AREA);
}

bool IsAreaLocked(int ent)
{
    return IsButtonArea(ent) && GetEntProp(ent, Prop_Send, PROP_LOCKED) != 0;
}

bool IsAreaPowered(int ent)
{
    return GetEntProp(ent, Prop_Send, PROP_NOPOWER) == 0;
}

// ============================================================================
//  找到按钮区直接关联的门实体 (CASW_Use_Area::m_hUseTarget 指向 door 类时)
//  读 datamap 的 m_hUseTarget, 只有目标是 door 类才返回, 否则返回 0。
// ============================================================================
int GetAreaDoor(int ent)
{
    if (ent <= 0 || FindDataMapInfo(ent, "m_hUseTarget") <= 0)
        return 0;
    int t = GetEntPropEnt(ent, Prop_Data, "m_hUseTarget");
    if (!IsValidEntity(t))
        return 0;
    char cls[64];
    GetEntityClassname(t, cls, sizeof(cls));
    return (StrContains(cls, "door") != -1) ? t : 0;
}

// ============================================================================
//  对单个按钮区执行解锁; activator 应为操作者的 marine(供引擎识别)。
//  解锁后若按钮区直接关联门, 主动给门发 Toggle 强制开门。
//  返回 true 表示确有解锁动作发生。
// ============================================================================
bool UnlockArea(int ent, int activator)
{
    if (!g_cvEnabled.BoolValue || !IsValidEntity(ent) || !IsAreaLocked(ent))
        return false;

    // 断电的门默认先通电, 避免解锁了但门因为没有电源仍然打不开
    if (g_cvForcePower.BoolValue && !IsAreaPowered(ent))
        AcceptEntityInput(ent, "PowerOn", activator, ent);

    // 引擎 InputUnlock: 置 m_bIsLocked=false, m_fHackProgress=1.0
    // (activator 是 marine 且配 useafterhack 时引擎会自动按下按钮)
    bool bUnlocked = AcceptEntityInput(ent, "Unlock", activator, ent);
    if (bUnlocked)
        g_iUnlocked++;

    // 关键修复: Unlock 通常只解锁不实开门, 门要由 ActivateUnlockedButton 给
    // 关联门发 Toggle 才真正打开; 这里主动找关联门并 Toggle, 确保门真的开。
    int iDoor = GetAreaDoor(ent);
    if (iDoor > 0)
        AcceptEntityInput(iDoor, "Toggle", activator, iDoor);

    return bUnlocked;
}

// ============================================================================
//  玩家命令 sm_unlock
//  范围判定: 解锁操作者 unlock_range 内最近的一扇上锁按钮区。
//  范围默认调得很小, 必须贴脸靠近门锁才能解, 不做全图/大范围自动解锁。
// ============================================================================
public Action Command_Unlock(int client, int args)
{
    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "[一键开锁] 功能已由服务器关闭");
        return Plugin_Handled;
    }
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;
    // 公开开关 + 管理员豁免: 管理员始终可用
    if (!g_cvPublic.BoolValue && !CheckCommandAccess(client, "sm_unlock", ADMFLAG_GENERIC))
    {
        ReplyToCommand(client, "[一键开锁] 该功能仅对管理员开放");
        return Plugin_Handled;
    }

    // 用操作者(marine)真实位置做圆心
    float fOrigin[3], fEntPos[3];
    int marine = GetPlayerMarine(client);   // 用 marine 作 activator, 门才能真正被引擎识别打开
    if (marine > 0)
        GetEntPropVector(marine, Prop_Send, "m_vecOrigin", fOrigin);
    else
        GetClientAbsOrigin(client, fOrigin);
    float fMaxDist = g_cvRange.FloatValue;
    int iBest = -1;
    float fBestDist = 999999.0;

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, ENT_BUTTON_AREA)) != -1)
    {
        if (!IsAreaLocked(ent))
            continue;

        if (fMaxDist > 0.0)
        {
            GetEntPropVector(ent, Prop_Send, "m_vecOrigin", fEntPos);
            float fDist = GetVectorDistance(fOrigin, fEntPos);
            if (fDist <= fMaxDist && fDist < fBestDist)
            {
                fBestDist = fDist;
                iBest = ent;
            }
        }
        else
        {
            iBest = ent;   // 不限范围(不建议): 取遍历到的最后一扇
        }
    }

    if (iBest == -1)
    {
        ReplyToCommand(client, "[一键开锁] 附近 (%.0f 单位) 内没有上锁的门锁，请靠近后再解", fMaxDist);
        return Plugin_Handled;
    }

    UnlockArea(iBest, marine);
    GetEntPropVector(iBest, Prop_Send, "m_vecOrigin", fEntPos);
    float fShowDist = GetVectorDistance(fOrigin, fEntPos);
    ReplyToCommand(client, "[一键开锁] 已解锁附近最近的门锁 (距你 %.0f 单位)", fShowDist);

    if (g_cvDebug.BoolValue)
        PrintToServer("[一键开锁] player#%d 解锁按钮区 #%d 距离 %.0f 位置 (%.0f %.0f %.0f)",
            client, iBest, fShowDist, fEntPos[0], fEntPos[1], fEntPos[2]);

    return Plugin_Handled;
}

// ============================================================================
//  管理员命令 sm_unlock_all: 解锁整张地图所有上锁按钮区
// ============================================================================
public Action Command_UnlockAll(int client, int args)
{
    if (!CheckCommandAccess(client, "sm_unlock_all", ADMFLAG_GENERIC))
    {
        ReplyToCommand(client, "[一键开锁] 权限不足");
        return Plugin_Handled;
    }

    g_iMatch = 0;
    g_iUnlocked = 0;

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, ENT_BUTTON_AREA)) != -1)
    {
        if (!IsAreaLocked(ent))
            continue;
        g_iMatch++;
        UnlockArea(ent, -1);   // 全图解锁, 不绑定具体 activator
    }

    ReplyToCommand(client, "[一键开锁] 全图扫描完成: 上锁按钮区 %d 个, 已解锁 %d 个", g_iMatch, g_iUnlocked);
    if (g_cvDebug.BoolValue)
        PrintToServer("[一键开锁] sm_unlock_all: 匹配 %d, 解锁 %d", g_iMatch, g_iUnlocked);

    return Plugin_Handled;
}

// ============================================================================
//  管理员命令 sm_unlock_status: 列出场上按钮区状态 (部署/排查用)
// ============================================================================
public Action Command_Status(int client, int args)
{
    if (!CheckCommandAccess(client, "sm_unlock_status", ADMFLAG_GENERIC))
    {
        ReplyToCommand(client, "[一键开锁] 权限不足");
        return Plugin_Handled;
    }

    int iCount = 0;
    PrintToConsole(client, "========== [一键开锁] 场上按钮区状态 (v%s) ==========", PLUGIN_VERSION);
    PrintToConsole(client, "启用: %s | 公开: %s | 范围: %.0f | 断电先通电: %s",
        g_cvEnabled.BoolValue ? "开" : "关",
        g_cvPublic.BoolValue ? "开" : "关",
        g_cvRange.FloatValue,
        g_cvForcePower.BoolValue ? "开" : "关");

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, ENT_BUTTON_AREA)) != -1)
    {
        iCount++;
        float fPos[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", fPos);
        PrintToConsole(client, "  #%d 锁=%s 电=%s 位置=(%.0f %.0f %.0f)",
            ent,
            IsAreaLocked(ent) ? "上锁" : "开锁",
            IsAreaPowered(ent) ? "有电" : "断电",
            fPos[0], fPos[1], fPos[2]);

        if (g_cvDebug.BoolValue)
            PrintToServer("[一键开锁] status: #%d 锁=%d 电=%d", ent,
                IsAreaLocked(ent) ? 1 : 0, IsAreaPowered(ent) ? 1 : 0);
    }
    PrintToConsole(client, "----------------------------------------------");
    PrintToConsole(client, "共 %d 个按钮区 (上锁的可再执行 sm_unlock_all 一次解锁)", iCount);
    return Plugin_Handled;
}