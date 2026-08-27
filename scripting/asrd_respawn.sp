/**
 * ============================================================================
 *  [AS:RD] 重生 / 传送 (Respawn & Teleport)
 *  版本 1.0.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ──────────────────────────────────────
 *  提供两个玩家聊天命令 (默认功能关闭, 需管理员激活):
 *    /fh   阵亡后重生 (每局每个玩家仅 1 次), 落点在被观战玩家旁
 *    /tp   传送到距离自己最近的存活队友身边
 *
 *  ── 功能介绍 ───────────────────────────────────────────
 *  1. /fh 复活: 仅在你阵亡(观战)时有效。通过 SDKCall 调用引擎的
 *     CASW_Player::ResurrectMarine(Vector, bool) 复活陆战队员。
 *      - 落点 = 你当前观战对象的位置; 找不到观战对象则用自身尸体坐标,
 *        再退化为最近存活队友坐标。
 *      - 每张地图/每局每名玩家只允许使用一次。
 *  2. /tp 传送: 仅存活时有效。找出与你最近的存活队友, 传送到其旁边。
 *
 *  ── 依赖 SDKCall (重要!) ───────────────────────────────
 *  /fh 需要调用虚拟成员函数 CASW_Player::ResurrectMarine。函数在
 *  CASW_Player 虚表中的索引存放在 gamedata:
 *      addons/sourcemod/gamedata/asrd_respawn.games.txt
 *      Offsets -> "ResurrectMarine" = <虚表索引>
 *  当前为占位值 0 (未配置)。未配置时 /fh 会安全拒绝, 不会崩服。
 *  请使用游戏二进制符号/反汇编确定正确索引并填入该文件后重载插件。
 *  AS:RD 升级后该索引可能变化, 需重新核对。
 *
 *  ── 命令 ────────────────────────────────────────────────
 *   sm_fhtp_enable        管理员: 激活/关闭插件功能 (默认关闭)
 *   sm_fh                 玩家:   阵亡后重生 (每局一次)
 *   sm_tp                 玩家:   传送到最近存活队友旁
 *
 *  ── ConVar (cfg/sourcemod/asrd_respawn.cfg) ─────────────
 *   sm_asrd_fhtp_enabled   总开关 (默认 0=关 1=开)
 *   sm_asrd_fhtp_debug     调试输出 (默认 0)
 *
 *  依赖: SourceMod 1.11+ (核心 + sdktools)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Respawn / Teleport"
#define PLUGIN_VERSION "1.0.0"

// 每局重生使用标记 (每玩家独立, OnMapStart 重置)
bool g_bFhUsed[MAXPLAYERS + 1];

// ConVar
ConVar g_cvEnabled;
ConVar g_cvDebug;

// ResurrectMarine 的 SDKCall (初始化时为 INVALID_HANDLE -> /fh 拒绝)
Handle g_hResurrect = INVALID_HANDLE;

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "AS:RD 阵亡重生 (/fh) 与传送到最近队友 (/tp), 默认关闭",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件启动: ConVar、注册命令、初始化 SDKCall
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_fhtp_enabled", "0",
        "启用/禁用重生/传送功能 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_fhtp_debug", "0",
        "调试输出 (0/1)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    AutoExecConfig(true, "asrd_respawn");

    // 管理员命令: 激活功能
    RegAdminCmd("sm_fhtp_enable", Command_Toggle, ADMFLAG_GENERIC,
        "激活/关闭重生成与传送功能 (不带参数=切换, 或带 0/1)");
    // 玩家命令 (聊天输入 /fh /tp)
    RegConsoleCmd("sm_fh", Command_FH, "阵亡后重生成 (每局一次)");
    RegConsoleCmd("sm_tp", Command_TP, "传送到最近的存活队友旁边");

    BuildResurrectCall();
}

// ============================================================================
//  地图开始: 重置每局重生次数
// ============================================================================
public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
        g_bFhUsed[i] = false;
}

// ============================================================================
//  玩家离开: 重置该槽位标记
// ============================================================================
public void OnClientDisconnected(int client)
{
    g_bFhUsed[client] = false;
}

// ============================================================================
//  插件卸载: 释放 SDKCall 句柄
// ============================================================================
public void OnPluginEnd()
{
    if (g_hResurrect != INVALID_HANDLE)
    {
        CloseHandle(g_hResurrect);
        g_hResurrect = INVALID_HANDLE;
    }
}

// ============================================================================
//  SDKCall 初始化: 从 gamedata 读 ResurrectMarine 虚表索引并构建调用
// ============================================================================
void BuildResurrectCall()
{
    GameData gc = LoadGameConfigFile("asrd_respawn.games.txt");
    if (gc == null)
    {
        PrintToServer("[重生传送] 无法加载 gamedata asrd_respawn.games.txt, 插件仍可加载, /fh 不可用");
        return;
    }

    // 用 SetFromConf 读虚表索引: 键/区块不存在时只返回 false 而不会抛原生错误,
    // 避免在 OnPluginStart 里抛错导致整个插件加载失败(即"看不到插件")。
    StartPrepSDKCall(SDKCall_Player);
    if (!PrepSDKCall_SetFromConf(gc, SDKConf_Virtual, "ResurrectMarine"))
    {
        PrintToServer("[重生传送] gamedata 未匹配当前游戏或 Offsets.ResurrectMarine 未配置, /fh 不可用。请配置后 sm plugins reload asrd_respawn");
        CloseHandle(gc);
        return;
    }
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByValue);     // Vector position
    PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_ByValue);       // bool bEffect
    PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer); // -> 新 marine
    g_hResurrect = EndPrepSDKCall();

    CloseHandle(gc);

    if (g_hResurrect == INVALID_HANDLE)
    {
        PrintToServer("[重生传送] ResurrectMarine SDKCall 初始化失败, /fh 不可用");
        return;
    }

    PrintToServer("[重生传送] ResurrectMarine SDKCall 已就绪, /fh 可用");

    if (g_cvDebug.BoolValue)
        PrintToServer("[重生传送][debug] 已完成重生 SDKCall 初始化");
}

// ============================================================================
//  命令 (管理员): sm_fhtp_enable [0/1]
// ============================================================================
public Action Command_Toggle(int client, int args)
{
    if (args >= 1)
    {
        char sArg[8];
        GetCmdArg(1, sArg, sizeof(sArg));

        if (StrEqual(sArg, "1") || StrEqual(sArg, "on") || StrEqual(sArg, "enable"))
            g_cvEnabled.SetBool(true);
        else if (StrEqual(sArg, "0") || StrEqual(sArg, "off") || StrEqual(sArg, "disable"))
            g_cvEnabled.SetBool(false);
        else
        {
            ReplyToCommand(client, "[重生传送] 用法: sm_fhtp_enable [0/1|on/off] (不带参数=切换)");
            return Plugin_Handled;
        }
    }
    else
    {
        g_cvEnabled.SetBool(!g_cvEnabled.BoolValue);
    }

    ReplyToCommand(client, "[重生传送] 功能已%s (sm_asrd_fhtp_enabled=%d)",
        g_cvEnabled.BoolValue ? "开启" : "关闭", g_cvEnabled.IntValue);
    return Plugin_Handled;
}

// ============================================================================
//  命令 (玩家): /fh 阵亡后重生
// ============================================================================
public Action Command_FH(int client, int args)
{
    if (!RequireEnabled(client))
        return Plugin_Handled;

    if (g_bFhUsed[client])
    {
        PrintToChat(client, "\x04[重生传送]\x01 你本局已使用过一次重生, 无法再次使用");
        return Plugin_Handled;
    }

    if (!IsMarineDead(client))
    {
        PrintToChat(client, "\x04[重生传送]\x01 只有阵亡后才能使用 /fh");
        return Plugin_Handled;
    }

    if (g_hResurrect == INVALID_HANDLE)
    {
        PrintToChat(client, "\x04[重生传送]\x01 重生成未配置 (gamedata 偏移未填写)");
        return Plugin_Handled;
    }

    float fPos[3];
    if (!GetResurrectPos(client, fPos))
    {
        PrintToChat(client, "\x04[重生传送]\x01 找不到可用的重生坐标");
        return Plugin_Handled;
    }

    int iNewMarine = SDKCall(g_hResurrect, client, fPos, true);
    if (iNewMarine > 0)
    {
        g_bFhUsed[client] = true;
        PrintToChat(client, "\x04[重生传送]\x01 已重生, 祝好运!");
    }
    else
    {
        PrintToChat(client, "\x04[重生传送]\x01 重生失败, 请稍后再试");
    }

    return Plugin_Handled;
}

// ============================================================================
//  命令 (玩家): /tp 传送到最近存活队友旁
// ============================================================================
public Action Command_TP(int client, int args)
{
    if (!RequireEnabled(client))
        return Plugin_Handled;

    if (IsMarineDead(client))
    {
        PrintToChat(client, "\x04[重生传送]\x01 阵亡状态无法传送, 请先 /fh 重生");
        return Plugin_Handled;
    }

    float fMy[3];
    GetClientAbsOrigin(client, fMy);

    float fBestPos[3];
    int iBest = FindNearestAlive(client, fBestPos);
    if (iBest <= 0)
    {
        PrintToChat(client, "\x04[重生传送]\x01 当前没有存活的队友");
        return Plugin_Handled;
    }

    // 朝自己方向外推 60 单位, 避免与队友站位重叠
    float fFx = fMy[0] - fBestPos[0];
    float fFy = fMy[1] - fBestPos[1];
    float fLen = SquareRoot(fFx * fFx + fFy * fFy);
    if (fLen > 1.0)
    {
        fBestPos[0] += fFx / fLen * 60.0;
        fBestPos[1] += fFy / fLen * 60.0;
    }

    TeleportEntity(client, fBestPos, NULL_VECTOR, NULL_VECTOR);
    PrintToChat(client, "\x04[重生传送]\x01 已传送到最近存活队友身旁");

    return Plugin_Handled;
}

// ============================================================================
//  总开关校验: 未开启时拒绝并提示
// ============================================================================
bool RequireEnabled(int client)
{
    if (!g_cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[重生传送]\x01 该功能未开启 (需管理员执行 sm_fhtp_enable)");
        return false;
    }
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return false;
    return true;
}

// ============================================================================
//  阵亡判定: 玩家未控制存活陆战队员即为阵亡/观战
// ============================================================================
bool IsMarineDead(int client)
{
    int iMarine = GetPlayerMarine(client);
    if (iMarine <= 0)
        return true;   // 无实体 -> 观战中
    if (HasEntProp(iMarine, Prop_Data, "m_iHealth")
        && GetEntProp(iMarine, Prop_Data, "m_iHealth") <= 0)
        return true;   // 控制的陆战队员已阵亡
    return false;
}

// ============================================================================
//  重生落点: 被观战玩家旁 -> 自身尸体 -> 最近存活队友 (优先级递减)
// ============================================================================
bool GetResurrectPos(int client, float fOut[3])
{
    // 1) 被观战目标旁
    int iTarget = GetObserverTarget(client);
    if (iTarget > 0 && GetEntityOrigin(iTarget, fOut))
        return true;

    // 2) 自身死亡 marine 坐标
    int iMarine = GetPlayerMarine(client);
    if (iMarine > 0 && GetEntityOrigin(iMarine, fOut))
        return true;

    // 3) 最近存活队友
    if (FindNearestAlive(client, fOut) > 0)
        return true;

    return false;
}

// ============================================================================
//  取观战目标实体 (m_hObserverTarget, 数据/网络属性双探)
// ============================================================================
int GetObserverTarget(int client)
{
    int iTarget = 0;
    if (HasEntProp(client, Prop_Data, "m_hObserverTarget"))
        iTarget = GetEntPropEnt(client, Prop_Data, "m_hObserverTarget");
    if (iTarget <= 0 && HasEntProp(client, Prop_Send, "m_hObserverTarget"))
        iTarget = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
    return (iTarget > 0 && IsValidEntity(iTarget)) ? iTarget : 0;
}

// ============================================================================
//  取实体坐标: 客户端用 GetClientAbsOrigin; 其它实体 Prop_Send->Prop_Data
// ============================================================================
bool GetEntityOrigin(int ent, float fOut[3])
{
    if (ent >= 1 && ent <= MaxClients && IsClientInGame(ent))
    {
        GetClientAbsOrigin(ent, fOut);
        return true;
    }
    if (ent > 0 && IsValidEntity(ent))
    {
        if (HasEntProp(ent, Prop_Send, "m_vecOrigin"))
        {
            GetEntPropVector(ent, Prop_Send, "m_vecOrigin", fOut);
            return true;
        }
        if (HasEntProp(ent, Prop_Data, "m_vecOrigin"))
        {
            GetEntPropVector(ent, Prop_Data, "m_vecOrigin", fOut);
            return true;
        }
    }
    return false;
}

// ============================================================================
//  查找离 client 最近的存活队友, 输出其坐标; 返回队友客户端, 无则 -1
// ============================================================================
int FindNearestAlive(int client, float fOut[3])
{
    float fMy[3];
    GetClientAbsOrigin(client, fMy);

    int   iBest = -1;
    float fBest = 1.0e9;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == client || !IsClientInGame(i) || IsFakeClient(i))
            continue;
        if (IsMarineDead(i))
            continue;

        float fPos[3];
        if (!GetAlivePos(i, fPos))
            continue;

        float fDx = fMy[0] - fPos[0];
        float fDy = fMy[1] - fPos[1];
        float fDz = fMy[2] - fPos[2];
        float fD  = fDx * fDx + fDy * fDy + fDz * fDz;
        if (fD < fBest)
        {
            fBest = fD;
            iBest = i;
            fOut  = fPos;
        }
    }

    return iBest;
}

// ============================================================================
//  取存活玩家的坐标 (优先其陆战队员实体坐标)
// ============================================================================
bool GetAlivePos(int client, float fOut[3])
{
    int iMarine = GetPlayerMarine(client);
    if (iMarine > 0 && GetEntityOrigin(iMarine, fOut))
        return true;
    return GetEntityOrigin(client, fOut);
}

// ============================================================================
//  玩家 -> 当前控制/关联的陆战队员实体 (返回 0 表示无)
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