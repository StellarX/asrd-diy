/**
 * ============================================================================
 *  [AS:RD] 电锯高速旋转 (Chainsaw Turbo)
 *  版本 1.3.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  玩家手持电锯 (asw_weapon_chainsaw) 且【按住攻击键】时, 让锯片转得更快:
 *  1. 按攻击键 → 锯片高速旋转 (旋转 + 伤害 + 音效都是游戏原生行为, 只是更快)
 *  2. 松开攻击键 → 立即恢复默认速度 (完全不按就不触发)
 *  3. 旋转速度可调 —— 通过改变电锯动画播放速率 (m_flPlaybackRate)
 *  4. 只对手持电锯的玩家生效 —— 换掉电锯后立即恢复原样
 *  5. 增强电锯: 管理员命令 / 积分购买可在玩家身边掉落一把电锯,
 *     其伤害 × sm_asrd_chainsaw_dmg_mult (默认 10.0);
 *     **仅掉落的电锯享受加成, 玩家自己携带进入的电锯保持原伤害与属性**
 *
 *  ── 管理员命令 ─────────────────────────────────────────
 *   sm_chainsaw_status   在控制台查看当前谁手持电锯、是否正在开火等状态
 *   sm_chainsaw_drop [玩家]  给指定玩家(或自己)在身边掉一把增强电锯
 *
 *  ── 玩家命令 ───────────────────────────────────────────
 *   sm_chainsawdrop      在自己身边掉一把增强电锯 (受 sm_asrd_chainsaw_drop_public 限制)
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_chainsaw_turbo.cfg) ─
 *   sm_asrd_chainsaw_enabled   总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_chainsaw_speed     锯片旋转速度倍率 (1.0~12.0, 默认 3.0)
 *                              3.0 = 按攻击键时比默认快 3 倍
 *   sm_asrd_chainsaw_public    是否对普通玩家生效 (默认 0)
 *                              0 = 仅管理员 (ADMFLAG_GENERIC) 生效
 *                              1 = 所有玩家生效
 *   sm_asrd_chainsaw_dmg_mult  增强电锯伤害倍率 (默认 10.0, 1.0=原伤害)
 *                              仅本插件掉落的增强电锯享受, 玩家自带电锯不受影响
 *   sm_asrd_chainsaw_drop_public 允许玩家用 sm_chainsawdrop 自己掉电锯 (默认 1)
 *   sm_asrd_chainsaw_debug     调试输出 (默认 0)
 *
 *  ── 实现原理 ───────────────────────────────────────────
 *   - 找到玩家控制的 marine 实体 (m_hInhabiting / m_hCommander)
 *   - 读 marine 的当前武器句柄 m_hActiveWeapon, 判断类名是否电锯
 *   - OnGameFrame 里检测玩家是否按住攻击键 (GetClientButtons & IN_ATTACK):
 *       按住 → 每帧改写 m_flPlaybackRate 加速锯片动画
 *       松开 → 恢复 m_flPlaybackRate = 1.0 (默认速度)
 *   - 旋转+开火+音效由游戏原生接管; 仅对"本插件掉落的增强电锯"额外挂
 *     OnTakeDamage 放大其 DMG_SLASH 伤害, 玩家自带的电锯不挂此逻辑, 伤害与属性完全不变
 *
 *  依赖: SourceMod 1.11+ (不依赖任何扩展, 只用核心 API + sdktools)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Chainsaw Turbo"
#define PLUGIN_VERSION "1.3.0"

// 电锯实体类名 (游戏源码: asw_weapon_chainsaw_shared.cpp)
#define CHAINSAW_CLASSNAME "asw_weapon_chainsaw"

// 增强电锯的视觉标记颜色 (金色) —— 仅作用于本插件掉落的增强电锯, 玩家自带不变
// 格式: RGB, 用于 glow 描边与模型染色
#define ENHANCED_COLOR_R 255
#define ENHANCED_COLOR_G 170
#define ENHANCED_COLOR_B 0

// 电锯的三种开火状态 (CHAINSAW_FIRE_STATE 枚举)
// 0 = 关闭  1 = 启动中(蓄力约1秒)  2 = 全速运转
#define CHAINSAW_FIRE_OFF     0
#define CHAINSAW_FIRE_STARTUP 1
#define CHAINSAW_FIRE_CHARGE  2

// 享受电锯增强所需的管理员权限 (仅当 sm_asrd_chainsaw_public 为 0 时要求)
#define CHAINSAW_ADMIN_FLAG   ADMFLAG_GENERIC

// 每 0.25 秒重新检测一次"是否手持电锯", 避免每帧都扫描实体
#define RESOLVE_INTERVAL 0.25

// ============================================================================
//  ConVar 句柄
// ============================================================================
ConVar g_cvEnabled;
ConVar g_cvSpeed;
ConVar g_cvPublic;
ConVar g_cvDebug;
ConVar g_cvDmgMult;     // 增强电锯伤害倍率 (仅本插件掉落的电锯享受; 玩家自带电锯保持原伤害)
ConVar g_cvDropPublic;  // 普通玩家能否用 sm_chainsawdrop 自己掉电锯

// ============================================================================
//  每个玩家一条状态: 当前手持电锯的实体引用 (0 = 没拿电锯)
// ============================================================================
int   g_iChainsawRef[MAXPLAYERS + 1];
float g_fNextResolve[MAXPLAYERS + 1];   // 下次允许重新检测手持状态的时间
bool  g_bLastHolding[MAXPLAYERS + 1];   // 上一次的手持状态 (调试用)
bool  g_bLastAttack[MAXPLAYERS + 1];    // 上一次的开火状态 (调试用)

// 增强电锯标记: 仅本插件掉落(asw_weapon_chainsaw)的电锯为 true;
// 玩家自己携带进入的电锯永远为 false, 保持原伤害与属性。索引即实体编号。
bool  g_bEnhancedChainsaw[2049];

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
    g_cvPublic = CreateConVar(
        "sm_asrd_chainsaw_public", "0",
        "是否对普通玩家生效 (0=仅管理员生效 1=所有玩家生效)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_chainsaw_debug", "0",
        "调试模式 (向服务器控制台输出检测日志)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDmgMult = CreateConVar(
        "sm_asrd_chainsaw_dmg_mult", "10.0",
        "增强电锯伤害倍率 (1.0=原始伤害; 仅本插件掉落的增强电锯享受, 只放大其 DMG_SLASH 伤害; 玩家自带电锯不受影响)",
        FCVAR_NOTIFY, true, 0.01, true, 100.0
    );
    g_cvDropPublic = CreateConVar(
        "sm_asrd_chainsaw_drop_public", "1",
        "普通玩家能否用 sm_chainsawdrop 自己掉一把电锯在身边 (0=仅管理员 sm_chainsaw_drop)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    RegAdminCmd("sm_chainsaw_drop",     Command_ChainsawDrop,     ADMFLAG_GENERIC, "管理员给指定玩家(或自己)在身边掉一把增强电锯");
    RegConsoleCmd("sm_chainsawdrop",    Command_ChainsawDropPublic, "在自己身边掉一把增强电锯 (受 sm_asrd_chainsaw_drop_public 限制)");

    HookExistingAliens();

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
    bool  bAll      = g_cvPublic.BoolValue;   // public 开启时对所有人生效, 否则仅管理员

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !IsPlayerAlive(i))
        {
            g_iChainsawRef[i] = 0;
            continue;
        }

        // 非 public 模式下, 跳过没有管理员权限的玩家
        if (!bAll && !CheckCommandAccess(i, "sm_chainsaw_status", CHAINSAW_ADMIN_FLAG, true))
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

// ============================================================================
//  增强电锯: 可被近战加成的虫族类名 (与 asrd_points / asrd_marine_power 一致)
// ============================================================================
char g_sAlienClasses[][] =
{
    "asw_drone", "asw_drone_jumper", "asw_drone_uber", "asw_drone_antlion",
    "asw_parasite", "asw_parasite_defanged", "asw_egg", "asw_boomer", "asw_boomer_blob",
    "asw_buzzer", "asw_harvester", "asw_mortarbug", "asw_ranger", "asw_shieldbug",
    "asw_grub", "asw_grub_sac", "asw_queen", "asw_mender", "asw_shaman", "asw_xenomite",
    "asw_antlion_guard", "npc_antlionguard", "npc_antlionguard_cavern",
    "npc_antlionguard_normal", "npc_antlion_worker"
};

// ============================================================================
//  电锯伤害倍率 (管理员可调): 挂在虫族 victim 侧, 只对电锯(DMG_SLASH)生效
// ============================================================================
public Action OnChainsawDamaged(int victim, int &attacker, int &inflictor,
    float &damage, int &damagetype, int &weapon,
    float damageForce[3], float damagePosition[3], int damagecustom)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;
    if ((damagetype & DMG_SLASH) == 0)              // 只管电锯 (普通近战 DMG_CLUB 交给强化插件)
        return Plugin_Continue;
    if (damage <= 0.0)
        return Plugin_Continue;

    // 攻击武器确为电锯才加成 (双重保险)
    if (weapon <= 0 || !IsValidEntity(weapon))
        return Plugin_Continue;
    char sWeapon[64];
    if (!GetEntityClassname(weapon, sWeapon, sizeof(sWeapon))
        || !StrEqual(sWeapon, CHAINSAW_CLASSNAME, false))
        return Plugin_Continue;

    // 仅本插件掉落的"增强电锯"享受倍率; 玩家自带的电锯未标记, 保持原伤害与属性
    if (weapon >= 0 && weapon < sizeof(g_bEnhancedChainsaw)
        && !g_bEnhancedChainsaw[weapon])
        return Plugin_Continue;

    float mult = g_cvDmgMult.FloatValue;
    if (mult <= 0.0 || mult == 1.0)
        return Plugin_Continue;

    if (g_cvDebug.BoolValue)
        PrintToServer("[电锯] 伤害倍率 x%.1f (%.1f -> %.1f)", mult, damage, damage * mult);

    damage *= mult;
    return Plugin_Changed;
}

// ============================================================================
//  虫族伤害回调挂钩: 新虫族生成时补挂 + 地图开始时横扫已有虫族
// ============================================================================
public void OnEntityCreated(int entity, const char[] classname)
{
    if (IsAlienClass(classname))
        SDKHookEx(entity, SDKHook_OnTakeDamage, OnChainsawDamaged);
}

// 实体销毁时清除增强标记, 避免索引复用把玩家自带电锯误判为增强电锯
public void OnEntityDestroyed(int entity)
{
    if (entity >= 0 && entity < sizeof(g_bEnhancedChainsaw))
        g_bEnhancedChainsaw[entity] = false;
}

bool IsAlienClass(const char[] classname)
{
    for (int c = 0; c < sizeof(g_sAlienClasses); c++)
    {
        if (StrEqual(classname, g_sAlienClasses[c], false))
            return true;
    }
    return false;
}

void HookExistingAliens()
{
    for (int c = 0; c < sizeof(g_sAlienClasses); c++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, g_sAlienClasses[c])) != -1)
            SDKHookEx(ent, SDKHook_OnTakeDamage, OnChainsawDamaged);
    }
}

// ============================================================================
//  增强电锯掉落: 在玩家身边生成一把电锯武器实体 (拾取后自动装备)
// ============================================================================
int SpawnChainsawNear(int client)
{
    int iMarine = GetPlayerMarine(client);
    if (iMarine <= 0)
        return -1;

    float fPos[3], fAng[3];
    GetEntPropVector(iMarine, Prop_Send, "m_vecOrigin", fPos);
    GetClientEyeAngles(client, fAng);
    float fYaw = DegToRad(fAng[1]);
    fPos[0] += Cosine(fYaw) * 60.0;
    fPos[1] += Sine(fYaw) * 60.0;
    fPos[2] += 20.0;

    int iWeapon = CreateEntityByName(CHAINSAW_CLASSNAME);
    if (iWeapon == -1)
        return -1;

    float fZeroAng[3];
    TeleportEntity(iWeapon, fPos, fZeroAng, NULL_VECTOR);
    DispatchSpawn(iWeapon);
    ActivateEntity(iWeapon);

    // 标记为"增强电锯": 仅此实体享受 sm_asrd_chainsaw_dmg_mult 倍率;
    // 玩家自带的电锯不会经过本函数, 标记恒为 false, 保持原伤害。
    if (iWeapon >= 0 && iWeapon < sizeof(g_bEnhancedChainsaw))
        g_bEnhancedChainsaw[iWeapon] = true;

    // 视觉标记: 金色描边光晕 + 金色染色, 让掉落的增强电锯一眼可辨
    if (iWeapon >= 0)
        MakeEnhancedVisual(iWeapon);

    return iWeapon;
}

// 命令(管理员): 在身边掉落增强电锯
public Action Command_ChainsawDrop(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "你必须存活才能使用此命令");
        return Plugin_Handled;
    }
    if (SpawnChainsawNear(client) == -1)
    {
        ReplyToCommand(client, "创建电锯失败");
        return Plugin_Handled;
    }
    ReplyToCommand(client, "已在身边掉落一把增强电锯");
    return Plugin_Handled;
}

// 命令(玩家): 经积分插件购买后转发到此 (需 sm_asrd_chainsaw_drop_public 1)
public Action Command_ChainsawDropPublic(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "你必须存活才能使用此命令");
        return Plugin_Handled;
    }
    if (!g_cvDropPublic.BoolValue)
    {
        ReplyToCommand(client, "增强电锯掉落功能未对玩家开放");
        return Plugin_Handled;
    }
    if (SpawnChainsawNear(client) == -1)
    {
        ReplyToCommand(client, "创建电锯失败");
        return Plugin_Handled;
    }
    ReplyToCommand(client, "已在身边掉落一把增强电锯, 走过去即可拾取");
    return Plugin_Handled;
}

// ============================================================================
//  增强电锯视觉标记: 仅作用于本插件掉落的增强电锯
//  - 金色描边光晕 (m_bGlowEnabled + m_glowColorOverride): 隔着墙也能看到,
//    类似 AS:RD 标记重要物品的高亮, 远处一眼可辨
//  - 金色染色 (m_bGlowEnabled 之外的 render 染色): 近看模型本身就是金色,
//    和玩家那把灰扑扑的原版电锯区分明显
//  不影响拾取/伤害逻辑; 玩家自带电锯不经过 SpawnChainsawNear, 不会有此外观
// ============================================================================
void MakeEnhancedVisual(int iWeapon)
{
    if (!IsValidEntity(iWeapon))
        return;

    // 1) 描边光晕 (send 属性, 可被其他玩家透视看到)
    SetEntProp(iWeapon, Prop_Send, "m_bGlowEnabled", 1);
    SetEntProp(iWeapon, Prop_Send, "m_nGlowRange", 4096);     // 可见光晕的距离
    SetEntProp(iWeapon, Prop_Send, "m_nGlowRangeMin", 0);
    // 颜色打包: value = R | (G << 8) | (B << 16)
    int iGlow = (ENHANCED_COLOR_B << 16) | (ENHANCED_COLOR_G << 8) | ENHANCED_COLOR_R;
    SetEntProp(iWeapon, Prop_Send, "m_glowColorOverride", iGlow);

    // 2) 模型染色 (金色)
    SetEntityRenderMode(iWeapon, RENDER_TRANSCOLOR);
    SetEntityRenderColor(iWeapon, ENHANCED_COLOR_R, ENHANCED_COLOR_G, ENHANCED_COLOR_B, 255);
}
