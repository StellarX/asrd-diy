/**
 * ============================================================================
 *  [AS:RD] 电锯高速旋转 (Chainsaw Turbo)
 *  版本 1.1.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  玩家手持电锯 (asw_weapon_chainsaw) 且【按住攻击键】时, 让锯片转得更快:
 *  1. 按攻击键 → 锯片高速旋转 (旋转 + 伤害 + 音效都是游戏原生行为, 只是更快)
 *  2. 松开攻击键 → 立即恢复默认速度 (完全不按就不触发)
 *  3. 旋转速度可调 —— 通过改变电锯动画播放速率 (m_flPlaybackRate)
 *  4. 只对手持电锯的玩家生效 —— 换掉电锯后立即恢复原样
 *
 *  ── 管理员命令 ─────────────────────────────────────────
 *   sm_chainsaw_status   在控制台查看当前谁手持电锯、是否正在开火等状态
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_chainsaw_turbo.cfg) ─
 *   sm_asrd_chainsaw_enabled   总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_chainsaw_speed     锯片旋转速度倍率 (1.0~12.0, 默认 3.0)
 *                              3.0 = 按攻击键时比默认快 3 倍
 *   sm_asrd_chainsaw_debug     调试输出 (默认 0)
 *
 *  ── 实现原理 ───────────────────────────────────────────
 *   - 找到玩家控制的 marine 实体 (m_hInhabiting / m_hCommander)
 *   - 读 marine 的当前武器句柄 m_hActiveWeapon, 判断类名是否电锯
 *   - OnGameFrame 里检测玩家是否按住攻击键 (GetClientButtons & IN_ATTACK):
 *       按住 → 每帧改写 m_flPlaybackRate 加速锯片动画
 *       松开 → 恢复 m_flPlaybackRate = 1.0 (默认速度)
 *   - 完全不插手开火/伤害逻辑, 旋转+伤害+音效仍由游戏原生接管
 *
 *  依赖: SourceMod 1.11+ (不依赖任何扩展, 只用核心 API + sdktools)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Chainsaw Turbo"
#define PLUGIN_VERSION "1.1.0"

// 电锯实体类名 (游戏源码: asw_weapon_chainsaw_shared.cpp)
#define CHAINSAW_CLASSNAME "asw_weapon_chainsaw"

// 电锯的三种开火状态 (CHAINSAW_FIRE_STATE 枚举)
// 0 = 关闭  1 = 启动中(蓄力约1秒)  2 = 全速运转
#define CHAINSAW_FIRE_OFF     0
#define CHAINSAW_FIRE_STARTUP 1
#define CHAINSAW_FIRE_CHARGE  2

// 每 0.25 秒重新检测一次"是否手持电锯", 避免每帧都扫描实体
#define RESOLVE_INTERVAL 0.25

// ============================================================================
//  ConVar 句柄
// ============================================================================
ConVar g_cvEnabled;
ConVar g_cvSpeed;
ConVar g_cvDebug;

// ============================================================================
//  每个玩家一条状态: 当前手持电锯的实体引用 (0 = 没拿电锯)
// ============================================================================
int   g_iChainsawRef[MAXPLAYERS + 1];
float g_fNextResolve[MAXPLAYERS + 1];   // 下次允许重新检测手持状态的时间
bool  g_bLastHolding[MAXPLAYERS + 1];   // 上一次的手持状态 (调试用)
bool  g_bLastAttack[MAXPLAYERS + 1];    // 上一次的开火状态 (调试用)

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "AS:RD 手持电锯按攻击键时高速旋转, 转速可调",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件启动: 创建 ConVar、注册命令
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_chainsaw_enabled", "1",
        "启用/禁用电锯高速旋转 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvSpeed = CreateConVar(
        "sm_asrd_chainsaw_speed", "3.0",
        "锯片旋转速度倍率 (1.0=默认, 3.0=快3倍; 上限 12.0 是引擎网络同步上限)",
        FCVAR_NOTIFY, true, 1.0, true, 12.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_chainsaw_debug", "0",
        "调试模式 (向服务器控制台输出检测日志)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    // 自动保存/读取配置到 cfg/sourcemod/asrd_chainsaw_turbo.cfg
    AutoExecConfig(true, "asrd_chainsaw_turbo");

    RegAdminCmd("sm_chainsaw_status", Command_ChainsawStatus, ADMFLAG_GENERIC, "查看电锯高速旋转状态");
}

// ============================================================================
//  地图加载 / 玩家离开: 清空上一局留下的手持状态
// ============================================================================
public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iChainsawRef[i] = 0;
        g_fNextResolve[i] = 0.0;
        g_bLastHolding[i] = false;
        g_bLastAttack[i]  = false;
    }
}

public void OnClientDisconnected(int client)
{
    g_iChainsawRef[client] = 0;
    g_fNextResolve[client] = 0.0;
    g_bLastHolding[client] = false;
    g_bLastAttack[client]  = false;
}

// ============================================================================
//  每游戏帧执行:
//   1. 定期确认玩家是否手持电锯
//   2. 手持电锯时: 按住攻击键 → 加速锯片动画; 松开 → 恢复默认速度
// ============================================================================
public void OnGameFrame()
{
    if (!g_cvEnabled.BoolValue)
        return;

    float fGameTime = GetGameTime();
    float fSpeed    = g_cvSpeed.FloatValue;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !IsPlayerAlive(i))
        {
            g_iChainsawRef[i] = 0;
            continue;
        }

        // 定期重新解析手持状态 (限制频率, 别每帧扫实体)
        if (fGameTime >= g_fNextResolve[i])
        {
            g_fNextResolve[i] = fGameTime + RESOLVE_INTERVAL;
            int iWeapon = ResolveHeldChainsaw(i);
            g_iChainsawRef[i] = (iWeapon > 0) ? EntIndexToEntRef(iWeapon) : 0;
        }

        int iWeapon = EntRefToEntIndex(g_iChainsawRef[i]);
        bool bHolding = (iWeapon != INVALID_ENT_REFERENCE && IsValidEntity(iWeapon));
        if (!bHolding)
        {
            g_iChainsawRef[i] = 0;
        }

        // 按住攻击键 → 加速锯片旋转; 松开 → 恢复默认播放速率
        int iButtons = GetClientButtons(i);
        bool bAttack = (iButtons & IN_ATTACK) != 0;

        if (bHolding)
        {
            if (bAttack && fSpeed > 1.0)
                SetEntPropFloat(iWeapon, Prop_Send, "m_flPlaybackRate", fSpeed);
            else if (!bAttack)
                SetEntPropFloat(iWeapon, Prop_Send, "m_flPlaybackRate", 1.0);
        }

        // 调试: 手持/开火状态发生变化时输出一条日志
        if (g_cvDebug.BoolValue && (bHolding != g_bLastHolding[i] || bAttack != g_bLastAttack[i]))
            PrintToServer("[电锯] 玩家 %N: 手持=%d 开火=%d 转速=x%.1f", i, bHolding, bAttack, fSpeed);

        g_bLastHolding[i] = bHolding;
        g_bLastAttack[i]  = bAttack;
    }
}

// ============================================================================
//  解析某玩家当前手持的电锯 (没拿返回 -1)
// ============================================================================
int ResolveHeldChainsaw(int client)
{
    int iMarine = GetPlayerMarine(client);
    if (iMarine <= 0)
        return -1;

    int iWeapon = GetActiveWeapon(iMarine);
    if (iWeapon <= 0)
        return -1;

    char sClass[64];
    if (!GetEntityClassname(iWeapon, sClass, sizeof(sClass)))
        return -1;

    if (StrEqual(sClass, CHAINSAW_CLASSNAME))
        return iWeapon;

    return -1;
}

// ============================================================================
//  读 marine 当前手里的武器实体 (m_hActiveWeapon 既是数据属性也是网络属性)
// ============================================================================
int GetActiveWeapon(int iMarine)
{
    int iWeapon = GetEntPropEnt(iMarine, Prop_Data, "m_hActiveWeapon");
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        iWeapon = GetEntPropEnt(iMarine, Prop_Send, "m_hActiveWeapon");

    return (iWeapon > 0 && IsValidEntity(iWeapon)) ? iWeapon : -1;
}

// ============================================================================
//  找某个玩家当前控制的 marine 实体 (依次尝试三种办法)
// ============================================================================
int GetPlayerMarine(int client)
{
    if (client <= 0 || !IsClientInGame(client))
        return -1;

    // 办法1: 玩家身上的 m_hInhabiting 网络属性 (最快)
    char sNetClass[64];
    if (GetEntityNetClass(client, sNetClass, sizeof(sNetClass)))
    {
        if (FindSendPropInfo(sNetClass, "m_hInhabiting") > 0)
        {
            int iMarine = GetEntPropEnt(client, Prop_Send, "m_hInhabiting");
            if (iMarine > 0 && IsValidEntity(iMarine))
                return iMarine;
        }
    }

    // 办法2: 玩家身上的 m_hInhabiting 数据属性
    if (FindDataMapInfo(client, "m_hInhabiting") > 0)
    {
        int iMarine = GetEntPropEnt(client, Prop_Data, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    // 办法3: 遍历所有 marine, 找操控者是该玩家的那个
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_marine")) != -1)
    {
        if (FindDataMapInfo(entity, "m_hCommander") > 0)
        {
            if (GetEntPropEnt(entity, Prop_Data, "m_hCommander") == client)
                return entity;
        }
    }

    return -1;
}

// ============================================================================
//  命令 (管理员): 在控制台查看电锯旋转状态
// ============================================================================
public Action Command_ChainsawStatus(int client, int args)
{
    PrintToConsole(client, "========== 电锯高速旋转状态 (v%s) ==========", PLUGIN_VERSION);
    PrintToConsole(client, "启用: %s | 转速倍率: x%.1f",
        g_cvEnabled.BoolValue ? "开" : "关", g_cvSpeed.FloatValue);
    PrintToConsole(client, "------------------------------");

    int iCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        int iWeapon = EntRefToEntIndex(g_iChainsawRef[i]);
        bool bHolding = (iWeapon != INVALID_ENT_REFERENCE && IsValidEntity(iWeapon));

        if (bHolding)
        {
            iCount++;
            int iFireState = GetEntProp(iWeapon, Prop_Send, "m_fireState");
            int iButtons   = GetClientButtons(i);
            float fRate    = GetEntPropFloat(iWeapon, Prop_Send, "m_flPlaybackRate");
            char sState[16];
            switch (iFireState)
            {
                case CHAINSAW_FIRE_OFF:     sState = "关闭";
                case CHAINSAW_FIRE_STARTUP: sState = "启动中";
                case CHAINSAW_FIRE_CHARGE:  sState = "全速运转";
                default:                    Format(sState, sizeof(sState), "未知(%d)", iFireState);
            }
            PrintToConsole(client, "[%N] 手持电锯 | 开火键:%s | 状态:%s | 播放速率:x%.1f",
                i, (iButtons & IN_ATTACK) ? "按下" : "松开", sState, fRate);
        }
    }

    if (iCount == 0)
        PrintToConsole(client, "当前没有玩家手持电锯");

    PrintToConsole(client, "==============================");
    return Plugin_Handled;
}
