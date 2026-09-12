/**
 * ============================================================================
 *  [AS:RD] 守望者标准型脉冲步枪 (Watcher Standard Pulse Rifle)
 *  版本 1.2.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  游戏里这把武器 (Overwatch Standard Issue Pulse Rifle / OSIPR / AR2 / 联合军脉冲步枪)
 *  只在少数特殊模式中出现, 正常挑战不会掉落。本插件让服务器主动把它的武器实体
 *  (asw_weapon_ar2) 生成在玩家身边供拾取, 并允许管理员用 ConVar 调高它造成的伤害。
 *
 *  说明: "守望者" = Overwatch, "标准型脉冲步枪" = Standard Issue Pulse Rifle,
 *  二者拼起来就是官方武器名 Overwatch Standard Issue Pulse Rifle; 游戏脚本
 *  scripts/asw_weapon_ar2.txt 第一行注释即为该名, 实体类名 asw_weapon_ar2
 *  (Source 引擎: 武器脚本文件名 <-> 实体类名 1:1)。
 *
 *  ── 管理员命令 ─────────────────────────────────────────
 *   sm_watcher_drop [玩家]  给指定玩家(或自己)在身边掉一把守望者脉冲步枪
 *   sm_watcher_status        查看当前谁拿着本插件掉落的增强步枪 / 伤害倍率 / 配色
 *   sm_watcher_color <R> <G> <B> [A]  设置掉落步枪的染色 (例: sm_watcher_color 0 200 255)
 *   sm_watcher_color <预设名>         用预设配色 (white/gold/red/orange/yellow/green/cyan/blue/purple/pink)
 *   sm_watcher_color                  不带参数 = 查看当前配色和可用预设
 *
 *  ── 玩家命令 ───────────────────────────────────────────
 *   sm_watcherdrop      在自己身边掉一把守望者脉冲步枪 (受 sm_asrd_watcher_drop_public 限制, 默认开放)
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_watcher_pulse_rifle.cfg) ─
 *   sm_asrd_watcher_enabled          总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_watcher_dmg_mult         主武器(脉冲)伤害倍率 (默认 2.0; 仅本插件掉落的步枪享受;
 *                                    对 ALL 受害者生效: 虫族 / 场景物体 / 队友; 设为 1.0 即不改; 上限 500)
 *   sm_asrd_watcher_alt_dmg_mult     副武器(能量球)伤害倍率 (默认 2.0; 同样对所有受害者生效; 上限 500)
 *   sm_asrd_watcher_drop_public      允许玩家用 sm_watcherdrop 自己掉步枪 (0=仅管理员, 默认 1)
 *   sm_asrd_watcher_alt_ammo         副武器(能量球)弹药数量 (默认 6; 0=不覆盖, 沿用游戏默认 3; 上限 2000)
 *   sm_asrd_watcher_color_r/g/b      掉落步枪染色 RGB (各 0~255, 默认 0 200 255 = 青色, 一眼可辨)
 *   sm_asrd_watcher_color_a          染色透明度 (0~255, 默认 255=不透明)
 *   sm_asrd_watcher_debug            调试输出 (默认 0)
 *   注: 主武器弹匣弹药已写死为 200 (代码内 WATCHER_MAIN_AMMO), 掉落即填满主/副弹夹与备弹
 *
 *  ── 实现原理 ───────────────────────────────────────────
 *   - 在玩家控制的 marine 实体 (m_hInhabiting / m_hCommander) 旁边生成
 *     asw_weapon_ar2 武器实体 (Teleport + DispatchSpawn + ActivateEntity), 走过去即可拾取。
 *   - 用 g_bEnhancedWatcher[] 标记"本插件掉落的步枪": 仅这些实体享受伤害倍率;
 *     玩家用其它途径拿到的不会被标记, 保持原伤害。实体销毁时清除标记,
 *     避免索引复用把别的武器误判为增强步枪。
 *   - 能量球 (prop_combine_ball) 由本插件掉落的增强步枪发射时, 在生成瞬间标记
 *     g_bEnhancedBall[], 使副武器伤害也享受独立倍率。
 *   - 伤害修改: 给"所有可能受伤的实体"挂 SDKHook_OnTakeDamage (虫族 / 场景物体 /
 *     队友 marine 都覆盖, 用 g_bDamageHooked[] 去重防止倍率叠加); 当伤害来源是
 *     本插件标记的 asw_weapon_ar2 (主武器) 或标记过的 prop_combine_ball (副武器) 时,
 *     把 damage 乘以对应倍率。该方案与 asrd_chainsaw_turbo.sp 同源。
 *   - 弹药: 主武器弹匣写死 200 (WATCHER_MAIN_AMMO), 副武器(能量球)数量由
 *     sm_asrd_watcher_alt_ammo 控制。两者都在"武器被 marine 拾取"时写入该 marine 的
 *     m_iAmmo[对应弹药类型] 储备池 + 武器 m_iClip1/m_iClip2, 确保主/副弹夹与备弹都填满
 *     (AR2 副弹药类型由武器 m_iSecondaryAmmoType 读取, 不硬编码)。
 *     注意: m_iAmmo 在 asw_marine 上是 datamap 属性 (非 sendprop), 必须用 FindDataMapInfo
 *     走 Prop_Data 写, 用 FindSendPropInfo 查发送表会查不到导致写失败。
 *   - 视觉标记: 给掉落的步枪染上设定色 (m_clrRender); AS:RD 武器每帧会复位该属性,
 *     故 OnGameFrame 里对增强步枪持续重涂, 保证地上/手里都稳定是设定色。
 *
 *  依赖: SourceMod 1.11+ (不依赖任何扩展, 只用核心 API + sdktools + sdkhooks)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] 守望者标准型脉冲步枪 (Watcher Pulse Rifle)"
#define PLUGIN_VERSION "1.2.0"

// 武器实体类名: 游戏源码 scripts/asw_weapon_ar2.txt 对应实体 asw_weapon_ar2
// (Overwatch Standard Issue Pulse Rifle / AR2 / 联合军脉冲步枪)
#define WATCHER_CLASSNAME "asw_weapon_ar2"

// 副武器(能量球)实体类名: HL2 引擎自带实体, AR2 副武器发射的就是它
#define BALL_CLASSNAME "prop_combine_ball"

// 掉落步枪的默认视觉标记色 —— 青色, 运行时可用 ConVar 或 sm_watcher_color 命令自定义。
// 格式 RGBA, 直接给步枪模型染色 (m_clrRender); 默认青色与原版明显不同, 一眼可辨。
#define ENHANCED_COLOR_R 0
#define ENHANCED_COLOR_G 200
#define ENHANCED_COLOR_B 255
#define ENHANCED_COLOR_A 255

// 主武器弹匣弹药: 按用户要求写死 200, 不再用 ConVar 调整
#define WATCHER_MAIN_AMMO 200

// 享受增强所需的管理员权限 (仅当 sm_asrd_watcher_drop_public 为 0 时要求)
#define WATCHER_ADMIN_FLAG   ADMFLAG_GENERIC

// ============================================================================
//  ConVar 句柄
// ============================================================================
ConVar g_cvEnabled;     // 总开关
ConVar g_cvDmgMult;     // 主武器(脉冲)伤害倍率 (仅本插件掉落的步枪享受)
ConVar g_cvAltDmgMult;  // 副武器(能量球)伤害倍率 (仅本插件掉落的步枪发射的能量球享受)
ConVar g_cvDropPublic;  // 普通玩家能否用 sm_watcherdrop 自己掉步枪
ConVar g_cvAltAmmo;     // 副武器(能量球)弹药数量
ConVar g_cvDebug;
ConVar g_cvColorR;      // 掉落步枪染色 R (0~255)
ConVar g_cvColorG;      // 掉落步枪染色 G (0~255)
ConVar g_cvColorB;      // 掉落步枪染色 B (0~255)
ConVar g_cvColorA;      // 掉落步枪染色透明度 (0~255, 255=不透明)

// ============================================================================
//  增强步枪标记: 仅本插件掉落(asw_weapon_ar2)的步枪为 true;
//  玩家用其它途径拿到的不会被标记, 保持原伤害。索引即实体编号。
bool  g_bEnhancedWatcher[2049];

//  能量球标记: 仅由增强步枪发射的 prop_combine_ball 为 true, 享受副武器倍率。
bool  g_bEnhancedBall[2049];

//  伤害钩子去重: 同一实体只挂一次 SDKHook_OnTakeDamage, 避免倍率被叠加。
bool  g_bDamageHooked[2049];

//  已为哪个持枪 marine 补过弹: 避免每帧重复写 (仅在持枪者变化时补一次)
int   g_iAppliedOwner[2049];

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "AS:RD 主动掉落守望者标准型脉冲步枪(AR2)并支持可调主/副武器伤害倍率",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件启动: 创建 ConVar、注册命令
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_watcher_enabled", "1",
        "启用/禁用守望者脉冲步枪掉落与伤害增强 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDmgMult = CreateConVar(
        "sm_asrd_watcher_dmg_mult", "2.0",
        "主武器(脉冲)伤害倍率 (1.0=原始伤害; 仅本插件掉落的步枪享受; 对虫族/场景物体/队友均生效; 上限 500)",
        FCVAR_NOTIFY, true, 0.01, true, 500.0
    );
    g_cvAltDmgMult = CreateConVar(
        "sm_asrd_watcher_alt_dmg_mult", "2.0",
        "副武器(能量球)伤害倍率 (1.0=原始伤害; 仅本插件掉落的步枪发射的能量球享受; 对虫族/场景物体/队友均生效; 上限 500)",
        FCVAR_NOTIFY, true, 0.01, true, 500.0
    );
    g_cvDropPublic = CreateConVar(
        "sm_asrd_watcher_drop_public", "1",
        "普通玩家能否用 sm_watcherdrop 自己掉一把步枪在身边 (0=仅管理员 sm_watcher_drop)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvAltAmmo = CreateConVar(
        "sm_asrd_watcher_alt_ammo", "6",
        "副武器(能量球)弹药数量 (0=不覆盖, 沿用游戏默认 3; 设为其他值即强制给持枪者该数量的能量球; 上限 2000)",
        FCVAR_NOTIFY, true, 0.0, true, 2000.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_watcher_debug", "0",
        "调试模式 (向服务器控制台输出检测/掉落/弹药日志)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    // ── 掉落步枪染色 (可用 sm_watcher_color 命令一键改) ────────────────
    g_cvColorR = CreateConVar(
        "sm_asrd_watcher_color_r", "0",
        "掉落步枪染色 - 红 (0~255)",
        FCVAR_NOTIFY, true, 0.0, true, 255.0
    );
    g_cvColorG = CreateConVar(
        "sm_asrd_watcher_color_g", "200",
        "掉落步枪染色 - 绿 (0~255)",
        FCVAR_NOTIFY, true, 0.0, true, 255.0
    );
    g_cvColorB = CreateConVar(
        "sm_asrd_watcher_color_b", "255",
        "掉落步枪染色 - 蓝 (0~255)",
        FCVAR_NOTIFY, true, 0.0, true, 255.0
    );
    g_cvColorA = CreateConVar(
        "sm_asrd_watcher_color_a", "255",
        "掉落步枪染色 - 透明度 (0~255, 255=完全不透明)",
        FCVAR_NOTIFY, true, 0.0, true, 255.0
    );

    RegAdminCmd("sm_watcher_drop",     Command_WatcherDrop,     ADMFLAG_GENERIC, "管理员给指定玩家(或自己)在身边掉一把守望者脉冲步枪");
    RegConsoleCmd("sm_watcherdrop",     Command_WatcherDropPublic, "在自己身边掉一把守望者脉冲步枪 (受 sm_asrd_watcher_drop_public 限制)");

    // 地图开始时横扫所有已存在的实体并补挂伤害钩子
    HookExistingEntities();

    // 自动保存/读取配置到 cfg/sourcemod/asrd_watcher_pulse_rifle.cfg
    AutoExecConfig(true, "asrd_watcher_pulse_rifle");

    RegAdminCmd("sm_watcher_status", Command_WatcherStatus, ADMFLAG_GENERIC, "查看守望者脉冲步枪状态");
    RegAdminCmd("sm_watcher_color",  Command_WatcherColor,  ADMFLAG_GENERIC,
        "设置掉落步枪的染色: sm_watcher_color <R> <G> <B> [A] 或 <预设名>");
}

// ============================================================================
//  每游戏帧: 对增强步枪持续重涂染色 (AS:RD 武器会复位 m_clrRender, 只设一次会被刷掉)
// ============================================================================
public void OnGameFrame()
{
    if (!g_cvEnabled.BoolValue)
        return;

    int iR, iG, iB, iA;
    GetEnhancedColor(iR, iG, iB, iA);

    for (int w = MaxClients + 1; w < sizeof(g_bEnhancedWatcher); w++)
    {
        if (!g_bEnhancedWatcher[w])
            continue;
        ApplyEnhancedColor(w, iR, iG, iB, iA);

        // ── 弹药: 检测当前持枪者, 持枪者变化(含首次拾取)时补满主/副弹夹与备弹 ──
        int iOwner = GetEntPropEnt(w, Prop_Send, "m_hOwnerEntity");
        if (iOwner <= 0 || !IsValidEntity(iOwner))
            iOwner = GetEntPropEnt(w, Prop_Data, "m_hOwner");
        int iMarine = -1;
        if (iOwner > 0 && IsValidEntity(iOwner))
        {
            if (IsMarine(iOwner))
                iMarine = iOwner;
            else if (IsClientInGame(iOwner))
                iMarine = GetPlayerMarine(iOwner);
        }
        if (iMarine > 0)
        {
            if (w < sizeof(g_iAppliedOwner) && g_iAppliedOwner[w] != iMarine)
            {
                ApplyWatcherAmmo(w, iMarine);
                g_iAppliedOwner[w] = iMarine;
            }
        }
        else if (w < sizeof(g_iAppliedOwner))
        {
            g_iAppliedOwner[w] = -1; // 没人持有时, 下次被拾取再补弹
        }
    }
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
//  伤害倍率回调挂钩目标: 给"所有可能受伤的实体"挂 SDKHook_OnTakeDamage ——
//  虫族 / 场景物体(门/可破坏物) / 队友(marine) 全覆盖。
//  用 g_bDamageHooked[] 防止重复挂钩导致倍率叠加。
// ============================================================================
void TryHookDamage(int entity)
{
    if (entity <= 0 || entity >= sizeof(g_bDamageHooked))
        return;
    if (!IsValidEntity(entity))
        return;
    // 世界(spawn)不需要挂: 墙体没有血量, 且世界实体收 OnTakeDamage 易异常
    char sClass[16];
    if (GetEntityClassname(entity, sClass, sizeof(sClass)) && StrEqual(sClass, "worldspawn"))
        return;
    if (g_bDamageHooked[entity])
        return;
    if (SDKHookEx(entity, SDKHook_OnTakeDamage, OnWatcherDamaged))
        g_bDamageHooked[entity] = true;
}

// 地图开始时横扫所有已存在的实体并补挂 (与 OnEntityCreated 互补, 靠 g_bDamageHooked 去重)
void HookExistingEntities()
{
    for (int e = 1; e < sizeof(g_bDamageHooked); e++)
        TryHookDamage(e);
}

// ============================================================================
//  掉落步枪伤害倍率 (管理员可调)
//   主武器(脉冲): 倍率 sm_asrd_watcher_dmg_mult
//   副武器(能量球 prop_combine_ball): 倍率 sm_asrd_watcher_alt_dmg_mult
//  对 ALL 受害者生效: 虫族 / 场景物体 / 队友。仅本插件掉落的"增强步枪"及其能量球享受。
// ============================================================================
public Action OnWatcherDamaged(int victim, int &attacker, int &inflictor,
    float &damage, int &damagetype, int &weapon,
    float damageForce[3], float damagePosition[3], int damagecustom)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;
    if (damage <= 0.0)
        return Plugin_Continue;
    // 不对自身伤害加成 (避免自杀/环境伤害被放大)
    if (attacker == victim)
        return Plugin_Continue;

    // ── 副武器(能量球)优先判定: inflictor 是标记过的 prop_combine_ball ──
    bool bBall = false;
    if (inflictor > 0 && IsValidEntity(inflictor))
    {
        char sInf[64];
        if (GetEntityClassname(inflictor, sInf, sizeof(sInf))
            && StrEqual(sInf, BALL_CLASSNAME, false))
        {
            if (inflictor < sizeof(g_bEnhancedBall) && g_bEnhancedBall[inflictor])
                bBall = true;
        }
    }

    // ── 主武器(脉冲直击): 伤害来源武器是标记过的 asw_weapon_ar2 ──
    bool bPrimary = false;
    if (!bBall)
    {
        int iWep = (weapon > 0 && IsValidEntity(weapon)) ? weapon : inflictor;
        if (iWep > 0 && IsValidEntity(iWep))
        {
            char sWeapon[64];
            if (GetEntityClassname(iWep, sWeapon, sizeof(sWeapon))
                && StrEqual(sWeapon, WATCHER_CLASSNAME, false)
                && iWep < sizeof(g_bEnhancedWatcher)
                && g_bEnhancedWatcher[iWep])
            {
                bPrimary = true;
            }
        }
    }

    if (!bPrimary && !bBall)
        return Plugin_Continue;

    float mult = bBall ? g_cvAltDmgMult.FloatValue : g_cvDmgMult.FloatValue;
    if (mult <= 0.0 || mult == 1.0)
        return Plugin_Continue;

    if (g_cvDebug.BoolValue)
        PrintToServer("[守望者步枪] %s 伤害倍率 x%.1f (%.1f -> %.1f) 受害者 %d",
            bBall ? "副武器(能量球)" : "主武器(脉冲)", mult, damage, damage * mult, victim);

    damage *= mult;
    return Plugin_Changed;
}

// ============================================================================
//  伤害回调挂钩: 所有实体生成即挂 + 地图开始横扫; 能量球生成时标记归属
// ============================================================================
public void OnEntityCreated(int entity, const char[] classname)
{
    TryHookDamage(entity);
    // 能量球: 延迟一帧确认归属(创建瞬间 owner 可能尚未设置), 再判断是否由增强步枪发射
    if (StrEqual(classname, BALL_CLASSNAME, false))
        RequestFrame(OnCombineBallSpawned, entity);
}

// 实体销毁: 清除增强标记/钩子标记, 避免索引复用误判
public void OnEntityDestroyed(int entity)
{
    if (entity >= 0 && entity < sizeof(g_bEnhancedWatcher))
    {
        g_bEnhancedWatcher[entity] = false;
        g_bDamageHooked[entity] = false;
    }
    if (entity >= 0 && entity < sizeof(g_iAppliedOwner))
        g_iAppliedOwner[entity] = -1;
    if (entity >= 0 && entity < sizeof(g_bEnhancedBall))
        g_bEnhancedBall[entity] = false;
}

// 能量球生成后: 若发射者手持"本插件掉落的增强步枪", 标记该球也享受副武器倍率
void OnCombineBallSpawned(any aBall)
{
    int iBall = aBall;
    if (iBall <= 0 || !IsValidEntity(iBall))
        return;

    int iOwner = GetEntPropEnt(iBall, Prop_Send, "m_hOwnerEntity");
    if (iOwner <= 0 || !IsValidEntity(iOwner))
        iOwner = GetEntPropEnt(iBall, Prop_Data, "m_hOwnerEntity");
    if (iOwner <= 0 || !IsValidEntity(iOwner))
        return;

    // 发射者可能是 marine 实体, 也可能是控制 marine 的玩家 client, 也可能直接是武器
    int iMarine = -1;
    if (IsMarine(iOwner))
    {
        iMarine = iOwner;
    }
    else if (IsWatcherRifle(iOwner))
    {
        // owner 直接是武器: 武器本身被标记过就标记球
        if (iOwner < sizeof(g_bEnhancedWatcher) && g_bEnhancedWatcher[iOwner])
            g_bEnhancedBall[iBall] = true;
        return;
    }
    else
    {
        iMarine = GetPlayerMarine(iOwner);
    }
    if (iMarine <= 0)
        return;

    int iWeapon = GetActiveWeapon(iMarine);
    if (iWeapon > 0 && iWeapon < sizeof(g_bEnhancedWatcher) && g_bEnhancedWatcher[iWeapon])
        g_bEnhancedBall[iBall] = true;
}

bool IsMarine(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;
    char sClass[32];
    if (!GetEntityClassname(entity, sClass, sizeof(sClass)))
        return false;
    return StrEqual(sClass, "asw_marine", false);
}

bool IsWatcherRifle(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;
    char sClass[64];
    if (!GetEntityClassname(entity, sClass, sizeof(sClass)))
        return false;
    return StrEqual(sClass, WATCHER_CLASSNAME, false);
}

// 解析某 marine 当前手持武器实体
int GetActiveWeapon(int iMarine)
{
    int iWeapon = GetEntPropEnt(iMarine, Prop_Data, "m_hActiveWeapon");
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        iWeapon = GetEntPropEnt(iMarine, Prop_Send, "m_hActiveWeapon");
    return iWeapon;
}

// ============================================================================
//  掉落: 在玩家身边生成一把守望者脉冲步枪武器实体 (拾取后自动装备)
// ============================================================================
int SpawnWatcherRifleNear(int client)
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

    int iWeapon = CreateEntityByName(WATCHER_CLASSNAME);
    if (iWeapon == -1)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[守望者步枪] CreateEntityByName(%s) 失败 (实体未注册?)", WATCHER_CLASSNAME);
        return -1;
    }

    float fZeroAng[3];
    TeleportEntity(iWeapon, fPos, fZeroAng, NULL_VECTOR);
    DispatchSpawn(iWeapon);
    ActivateEntity(iWeapon);

    // 主武器弹匣: 落地即填满 (写死 WATCHER_MAIN_AMMO=200); 拾取时 OnGameFrame 还会再补一次
    if (FindSendPropInfo(WATCHER_CLASSNAME, "m_iClip1") > 0)
        SetEntProp(iWeapon, Prop_Send, "m_iClip1", WATCHER_MAIN_AMMO);
    else if (FindDataMapInfo(iWeapon, "m_iClip1") > 0)
        SetEntData(iWeapon, FindDataMapInfo(iWeapon, "m_iClip1"), WATCHER_MAIN_AMMO, 4);

    // 标记为"增强步枪": 仅此实体享受 sm_asrd_watcher_dmg_mult 倍率
    if (iWeapon >= 0 && iWeapon < sizeof(g_bEnhancedWatcher))
        g_bEnhancedWatcher[iWeapon] = true;
    // 重置补弹记录: 让 OnGameFrame 在该武器被 marine 拾取时补满主/副弹夹与备弹
    if (iWeapon >= 0 && iWeapon < sizeof(g_iAppliedOwner))
        g_iAppliedOwner[iWeapon] = -1;

    // 视觉标记: 按当前配色给步枪染色, 让掉落的增强步枪一眼可辨
    if (iWeapon >= 0)
        MakeEnhancedVisual(iWeapon);

    if (g_cvDebug.BoolValue)
        PrintToServer("[守望者步枪] 已在玩家 %N 身边生成 %s (实体 %d)", client, WATCHER_CLASSNAME, iWeapon);

    return iWeapon;
}

// 读取武器实体的弹药类型索引 (CBaseCombatWeapon 标准属性 m_iPrimaryAmmoType / m_iSecondaryAmmoType)
//   先试 sendprop, 再试 datamap; 都查不到返回 -1
int GetWeaponAmmoType(int iWeapon, const char[] sProp)
{
    int off = FindSendPropInfo(WATCHER_CLASSNAME, sProp);
    if (off != -1)
        return GetEntProp(iWeapon, Prop_Send, sProp);
    if (FindDataMapInfo(iWeapon, sProp) != -1)
        return GetEntProp(iWeapon, Prop_Data, sProp);
    return -1;
}

// 给持枪 marine 的 m_iAmmo[弹药类型] 储备池写弹药数量
//   关键: asw_marine 的 m_iAmmo 是 datamap 属性 (非 sendprop), 必须用 FindDataMapInfo + SetEntData 走 Prop_Data 写;
//   用 FindSendPropInfo 查发送表会查不到 -> 写失败 (旧版副武器数量"没生效"就是这个原因)。
//   回退: 找不到 marine 的 m_iAmmo 时再试玩家 client。
void SetMarineAmmo(int iMarine, int iClient, int iAmmoType, int iCount)
{
    if (iAmmoType < 0 || iCount < 0)
        return;

    // 路径1: asw_marine 的 m_iAmmo (sendprop)
    if (iMarine > 0 && IsValidEntity(iMarine))
    {
        int off = FindSendPropInfo("asw_marine", "m_iAmmo");
        if (off != -1)
        {
            SetEntProp(iMarine, Prop_Send, "m_iAmmo", iCount, 4, iAmmoType);
            return;
        }
        // 路径2: asw_marine 的 m_iAmmo (datamap) —— 本游戏实际走这条
        int dm = FindDataMapInfo(iMarine, "m_iAmmo");
        if (dm != -1)
        {
            SetEntData(iMarine, dm + iAmmoType * 4, iCount, 4);
            return;
        }
    }

    // 回退: 玩家 client 的 m_iAmmo
    if (iClient > 0 && IsClientInGame(iClient))
    {
        int off = FindSendPropInfo("player", "m_iAmmo");
        if (off != -1)
        {
            SetEntProp(iClient, Prop_Send, "m_iAmmo", iCount, 4, iAmmoType);
            return;
        }
        int dm = FindDataMapInfo(iClient, "m_iAmmo");
        if (dm != -1)
        {
            SetEntData(iClient, dm + iAmmoType * 4, iCount, 4);
            return;
        }
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[守望者步枪] 设置弹药失败: 找不到 m_iAmmo 属性 (marine=%d client=%d 弹药类型=%d)",
            iMarine, iClient, iAmmoType);
}

// 取控制该 marine 的玩家 client (用于弹药写入回退)
int GetMarineCommander(int iMarine)
{
    if (!IsMarine(iMarine))
        return -1;
    int c = GetEntPropEnt(iMarine, Prop_Data, "m_hCommander");
    if (c > 0 && IsClientInGame(c))
        return c;
    c = GetEntPropEnt(iMarine, Prop_Send, "m_hCommander");
    if (c > 0 && IsClientInGame(c))
        return c;
    return -1;
}

// 武器被 marine 拾取时调用: 填满主武器弹匣 + 主/副备弹储备池
//   - 主武器弹匣 m_iClip1 = 200 (写死)
//   - 主武器备弹: marine.m_iAmmo[主弹药类型] = 200 (换弹有子弹, 不再"弹夹空")
//   - 副武器(能量球): marine.m_iAmmo[副弹药类型] = sm_asrd_watcher_alt_ammo; 同时填武器 m_iClip2 (若有)
void ApplyWatcherAmmo(int iWeapon, int iMarine)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon) || iMarine <= 0 || !IsValidEntity(iMarine))
        return;

    int iClient = GetMarineCommander(iMarine);

    // 主武器弹匣填满
    if (FindSendPropInfo(WATCHER_CLASSNAME, "m_iClip1") > 0)
        SetEntProp(iWeapon, Prop_Send, "m_iClip1", WATCHER_MAIN_AMMO);
    else if (FindDataMapInfo(iWeapon, "m_iClip1") != -1)
        SetEntData(iWeapon, FindDataMapInfo(iWeapon, "m_iClip1"), WATCHER_MAIN_AMMO, 4);

    // 主武器备弹(储备)填满, 让换弹后有子弹
    int iPri = GetWeaponAmmoType(iWeapon, "m_iPrimaryAmmoType");
    if (iPri >= 0)
        SetMarineAmmo(iMarine, iClient, iPri, WATCHER_MAIN_AMMO);

    // 副武器(能量球)弹药
    int iAlt = g_cvAltAmmo.IntValue;
    if (iAlt > 0)
    {
        int iSec = GetWeaponAmmoType(iWeapon, "m_iSecondaryAmmoType");
        if (iSec < 0)
            iSec = 6; // 回退: HL2 AMMO_AR2_ALTFIRE 常见值, 仅当读不到属性时用
        SetMarineAmmo(iMarine, iClient, iSec, iAlt);
        // 顺便填满副武器 clip (部分武器用 m_iClip2 存副弹药)
        if (FindSendPropInfo(WATCHER_CLASSNAME, "m_iClip2") > 0)
            SetEntProp(iWeapon, Prop_Send, "m_iClip2", iAlt);
        else if (FindDataMapInfo(iWeapon, "m_iClip2") != -1)
            SetEntData(iWeapon, FindDataMapInfo(iWeapon, "m_iClip2"), iAlt, 4);
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[守望者步枪] 已为 marine %d 补弹: 主弹匣=%d(备弹类型=%d) 副弹数=%d(副弹类型=%d) client=%d",
            iMarine, WATCHER_MAIN_AMMO, iPri, iAlt,
            (iAlt > 0) ? GetWeaponAmmoType(iWeapon, "m_iSecondaryAmmoType") : -1, iClient);
}

// 命令(管理员): 在身边掉落增强步枪
public Action Command_WatcherDrop(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "你必须存活才能使用此命令");
        return Plugin_Handled;
    }
    if (SpawnWatcherRifleNear(client) == -1)
    {
        ReplyToCommand(client, "创建守望者步枪失败 (实体 asw_weapon_ar2 可能未加载)");
        return Plugin_Handled;
    }
    ReplyToCommand(client, "已在身边掉落一把守望者标准型脉冲步枪");
    return Plugin_Handled;
}

// 命令(玩家): 经积分插件购买后转发到此 (需 sm_asrd_watcher_drop_public 1)
public Action Command_WatcherDropPublic(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "你必须存活才能使用此命令");
        return Plugin_Handled;
    }
    if (!g_cvDropPublic.BoolValue)
    {
        ReplyToCommand(client, "守望者步枪掉落功能未对玩家开放");
        return Plugin_Handled;
    }
    if (SpawnWatcherRifleNear(client) == -1)
    {
        ReplyToCommand(client, "创建守望者步枪失败 (实体 asw_weapon_ar2 可能未加载)");
        return Plugin_Handled;
    }
    ReplyToCommand(client, "已在身边掉落一把守望者标准型脉冲步枪, 走过去即可拾取");
    return Plugin_Handled;
}

// ============================================================================
//  状态命令(管理员): 查询时直接解析谁手持增强步枪 / 伤害倍率 / 配色
// ============================================================================
public Action Command_WatcherStatus(int client, int args)
{
    PrintToConsole(client, "========== 守望者脉冲步枪状态 (v%s) ==========", PLUGIN_VERSION);
    PrintToConsole(client, "启用: %s", g_cvEnabled.BoolValue ? "开" : "关");
    PrintToConsole(client, "主武器(脉冲)伤害倍率: x%.1f | 副武器(能量球)伤害倍率: x%.1f",
        g_cvDmgMult.FloatValue, g_cvAltDmgMult.FloatValue);
    PrintToConsole(client, "主武器弹匣(写死): %d | 副武器弹药: %s",
        WATCHER_MAIN_AMMO, g_cvAltAmmo.IntValue > 0 ? "自定义" : "游戏默认(3)");
    if (g_cvAltAmmo.IntValue > 0)
        PrintToConsole(client, "  (副武器弹药数量 = %d)", g_cvAltAmmo.IntValue);
    PrintToConsole(client, "玩家自掉: %s", g_cvDropPublic.BoolValue ? "开" : "关");

    int cR, cG, cB, cA;
    GetEnhancedColor(cR, cG, cB, cA);
    PrintToConsole(client, "掉落步枪染色: %d %d %d (透明度 %d)", cR, cG, cB, cA);
    PrintToConsole(client, "------------------------------");

    int iCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !IsPlayerAlive(i))
            continue;

        int iWeapon = GetHeldWatcher(i);
        if (iWeapon > 0)
        {
            iCount++;
            bool bEnhanced = (iWeapon < sizeof(g_bEnhancedWatcher) && g_bEnhancedWatcher[iWeapon]);
            PrintToConsole(client, "[%N] 手持步枪实体 %d | 增强标记=%d",
                i, iWeapon, bEnhanced ? 1 : 0);
        }
    }
    if (iCount == 0)
        PrintToConsole(client, "当前没有玩家手持本插件掉落的步枪");

    PrintToConsole(client, "==============================");
    return Plugin_Handled;
}

// 解析某玩家当前手持的守望者步枪 (没拿返回 -1)
int GetHeldWatcher(int client)
{
    int iMarine = GetPlayerMarine(client);
    if (iMarine <= 0)
        return -1;

    int iWeapon = GetEntPropEnt(iMarine, Prop_Data, "m_hActiveWeapon");
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        iWeapon = GetEntPropEnt(iMarine, Prop_Send, "m_hActiveWeapon");
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        return -1;

    char sClass[64];
    if (!GetEntityClassname(iWeapon, sClass, sizeof(sClass)))
        return -1;
    if (StrEqual(sClass, WATCHER_CLASSNAME))
        return iWeapon;

    return -1;
}

// ============================================================================
//  视觉标记: 仅作用于本插件掉落的增强步枪
//  - 直接给步枪模型染色 (m_clrRender + RENDER_TRANSCOLOR); 这是步枪自身属性,
//    天然跟着步枪走 —— 在地上、被捡起、被持有时都显示, 不会和步枪分离。
//  - 同时给持有者的第一人称视图模型 (m_hViewModel) 上同色, 让持枪者自己也能看出不同。
//  不影响拾取/伤害逻辑; 非本插件掉落的步枪不经过 SpawnWatcherRifleNear, 不会有此染色。
// ============================================================================
void MakeEnhancedVisual(int iWeapon)
{
    int iR, iG, iB, iA;
    GetEnhancedColor(iR, iG, iB, iA);
    ApplyEnhancedColor(iWeapon, iR, iG, iB, iA);
}

void GetEnhancedColor(int &iR, int &iG, int &iB, int &iA)
{
    iR = g_cvColorR.IntValue;
    iG = g_cvColorG.IntValue;
    iB = g_cvColorB.IntValue;
    iA = g_cvColorA.IntValue;
}

// 给增强步枪及其持有者的视图模型染上标记色 (每帧调用以对抗引擎复位)
void ApplyEnhancedColor(int iWeapon, int iR, int iG, int iB, int iA)
{
    if (!IsValidEntity(iWeapon))
        return;

    SetEntityRenderMode(iWeapon, RENDER_TRANSCOLOR);
    SetEntityRenderColor(iWeapon, iR, iG, iB, iA);

    // 持有者的第一人称视图模型也上色, 持枪者自己视角里同样是标记色
    int iOwner = GetEntPropEnt(iWeapon, Prop_Send, "m_hOwnerEntity");
    if (iOwner > 0 && IsValidEntity(iOwner))
    {
        int iVM = GetEntPropEnt(iOwner, Prop_Send, "m_hViewModel", 0);
        if (iVM > 0 && IsValidEntity(iVM))
        {
            SetEntityRenderMode(iVM, RENDER_TRANSCOLOR);
            SetEntityRenderColor(iVM, iR, iG, iB, iA);
        }
    }
}

// ---------------------------------------------------------------------------
//  预设配色表: sm_watcher_color <预设名> 直接套用
// ---------------------------------------------------------------------------
char g_sColorPresets[][] = {
    "white", "gold", "red", "orange", "yellow",
    "green", "cyan", "blue", "purple", "pink"
};
int  g_iColorPresets[][] = {
    {255, 255, 255},   // white  纯白
    {255, 215, 0},     // gold   金色
    {255, 0, 0},       // red    红色
    {255, 128, 0},     // orange 橙色
    {255, 255, 0},     // yellow 黄色
    {0, 255, 0},       // green  绿色
    {0, 255, 255},     // cyan   青色 (默认)
    {0, 128, 255},     // blue   蓝色
    {160, 32, 240},    // purple 紫色
    {255, 105, 180}    // pink   粉色
};

// 命令(管理员): 设置/查看掉落步枪的染色
public Action Command_WatcherColor(int client, int args)
{
    if (args == 0)
    {
        int iR, iG, iB, iA;
        GetEnhancedColor(iR, iG, iB, iA);
        ReplyToCommand(client, "当前掉落步枪染色: %d %d %d (透明度 %d)", iR, iG, iB, iA);
        ReplyToCommand(client, "用法: sm_watcher_color <R> <G> <B> [A]   例: sm_watcher_color 0 200 255");
        ReplyToCommand(client, "或:   sm_watcher_color <预设名>          可选: white gold red orange yellow green cyan blue purple pink");
        return Plugin_Handled;
    }

    char sArg[32];
    GetCmdArg(1, sArg, sizeof(sArg));

    // 预设名 (英文)
    int iPreset = FindColorPreset(sArg);
    if (iPreset >= 0)
    {
        g_cvColorR.IntValue = g_iColorPresets[iPreset][0];
        g_cvColorG.IntValue = g_iColorPresets[iPreset][1];
        g_cvColorB.IntValue = g_iColorPresets[iPreset][2];
        ReplyToCommand(client, "掉落步枪染色已设为 %s (%d %d %d)",
            g_sColorPresets[iPreset], g_iColorPresets[iPreset][0],
            g_iColorPresets[iPreset][1], g_iColorPresets[iPreset][2]);
        return Plugin_Handled;
    }

    // 自定义 RGB(A)
    if (args < 3)
    {
        ReplyToCommand(client, "参数不足: 需要 <R> <G> <B> [A], 或给一个预设名 (如 cyan)");
        return Plugin_Handled;
    }

    char sG[16], sB[16], sA[16];
    GetCmdArg(2, sG, sizeof(sG));
    GetCmdArg(3, sB, sizeof(sB));
    sA = "255";
    if (args >= 4)
        GetCmdArg(4, sA, sizeof(sA));

    int iR = Clamp255(StringToInt(sArg));
    int iG = Clamp255(StringToInt(sG));
    int iB = Clamp255(StringToInt(sB));
    int iA = Clamp255(StringToInt(sA));

    g_cvColorR.IntValue = iR;
    g_cvColorG.IntValue = iG;
    g_cvColorB.IntValue = iB;
    g_cvColorA.IntValue = iA;

    ReplyToCommand(client, "掉落步枪染色已设为 %d %d %d (透明度 %d)", iR, iG, iB, iA);
    return Plugin_Handled;
}

int FindColorPreset(const char[] sName)
{
    for (int i = 0; i < sizeof(g_sColorPresets); i++)
    {
        if (StrEqual(sName, g_sColorPresets[i], false))
            return i;
    }
    // 中文别名
    if (StrEqual(sName, "白色", false)) return 0;
    if (StrEqual(sName, "金色", false)) return 1;
    if (StrEqual(sName, "红色", false)) return 2;
    if (StrEqual(sName, "橙色", false)) return 3;
    if (StrEqual(sName, "黄色", false)) return 4;
    if (StrEqual(sName, "绿色", false)) return 5;
    if (StrEqual(sName, "青色", false)) return 6;
    if (StrEqual(sName, "蓝色", false)) return 7;
    if (StrEqual(sName, "紫色", false)) return 8;
    if (StrEqual(sName, "粉色", false)) return 9;
    return -1;
}

int Clamp255(int iValue)
{
    if (iValue < 0)   return 0;
    if (iValue > 255) return 255;
    return iValue;
}
