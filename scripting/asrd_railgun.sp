/**
 * ============================================================================
 *  [AS:RD] 导轨步枪 (Coil Assisted Rail Rifle / Railgun)
 *  版本 2.0.4  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  把导轨步枪 (武器实体 asw_weapon_railgun, 官方名 "Coil Assisted Rail Rifle")
 *  生成在玩家身边供拾取, 供积分插件购买 (#buy 6 4) 与自动掉落使用;
 *  支持 4 项可配置属性: 伤害 / 射速 / 弹夹(携带总弹药) / 弹匣容量。
 *
 *  ── 游戏原始数据 (源码 asw_equipment_list.cpp 的导轨步枪装备项) ──
 *    基础伤害 105 + 技能加成 (asw_skill_accuracy_railgun_dmg_step 默认 10/点, 满 5 点 = 155);
 *    换弹 1.3 秒; 弹匣与携带弹药默认都是 1 发;
 *    装备项 fire rate = 0, 射击节奏来自"每发后换弹 1.3 秒"。
 *    所以: 弹匣只有 1 发时, fire_interval 设多小都不会更快 (仍要换弹);
 *          把 sm_asrd_railgun_clip 调大后, 弹匣内连发才受 fire_interval 约束。
 *    穿透: 原版一发最多穿透 10 个目标 (FirePenetratingBullets iMaxPenetrate=10)。
 *
 *  ── 命令 ───────────────────────────────────────────────
 *   sm_railgun_drop    管理员: 在自己身边掉一把导轨步枪
 *   sm_railgundrop     玩家: 同上 (受 sm_asrd_railgun_drop_public 限制; 积分插件调用)
 *   sm_railgun_status  管理员: 查看配置与场上掉落状态
 *
 *  ── ConVar (自动生成 cfg/sourcemod/asrd_railgun.cfg) ──
 *   sm_asrd_railgun_enabled        总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_railgun_drop_public    玩家能否自行掉落 (0=仅管理员, 默认 1)
 *   sm_asrd_railgun_damage         基础伤害 (默认 0=原版 105; >0 时覆盖基础值,
 *                                  技能加成仍叠加: 最终 = 该值 + 10×技能点数;
 *                                  通过引擎原生 rd_railgun_dmg_base 实现, 全场生效)
 *   sm_asrd_railgun_fire_interval  两次射击最小间隔秒 (默认 1.3; 0=不限制;
 *                                  对场上所有导轨步枪生效, 含玩家从装备栏自带的枪)
 *   sm_asrd_railgun_clip           弹匣容量 (默认 1; 同时写入引擎 asw_ammo_count_railgun)
 *   sm_asrd_railgun_ammo           携带总弹药 (默认 1; 拾取时写入 marine 弹药池;
 *                                  超过引擎上限 sk_max_asw_rg(默认 72) 时会自动抬高该上限)
 *   sm_asrd_railgun_debug          调试输出 (默认 0)
 *
 *  ── 实现原理 ───────────────────────────────────────────
 *   - 掉落: CreateEntityByName("asw_weapon_railgun") + Teleport + DispatchSpawn,
 *     写入 m_iClip1 (弹匣) 与 m_iPrimaryAmmoCount (备弹), 用 g_bRailgun[] 标记;
 *     补弹(拾取时覆写弹匣/备弹)只作用于插件掉落的枪。
 *   - 射速: weapon_fire 事件 + 每帧弹匣减少检测记录开火时刻, 再把
 *     m_flNextPrimaryAttack 钳到"上次开火 + fire_interval"。
 *     该钳制对场上**所有** asw_weapon_railgun 生效 (含玩家从装备栏自带的枪),
 *     用 g_bAnyRailgun[] 标记; OnEntityCreated / OnMapStart / 插件加载时都会补标记。
 *     玩家自带的枪因此不再享受原版 fire rate=0 的"每帧可开火"。
 *   - 伤害: 引擎原生 ConVar rd_railgun_dmg_base (>0 时覆盖装备表基础伤害 105,
 *     技能加成仍叠加)。该 ConVar 是全局的, 某些挑战脚本 (如 traitors 随机设
 *     100~250) 改过后换模式不会自动还原; 插件每秒把它钉回配置值 (默认 0=原版),
 *     挑战残留因此不会生效。
 *   - 拾取: 每帧检查标记枪的持有者是否变化, 变化时把 marine 的
 *     m_iAmmo[ASW_RG] 写为配置弹药并把弹匣补满。
 *     (m_iAmmo 是 DT_ASW_Marine 的 sendprop 数组, 必须带元素下标走 Prop_Send)
 *   - 射速: weapon_fire 事件记录每把枪的开火时刻, 每帧把 m_flNextPrimaryAttack
 *     钳到 max(当前值, 上次开火 + fire_interval); 只在弹匣非空时干预,
 *     换弹期间保持游戏原节奏 (1.3 秒), 避免与引擎换弹逻辑冲突。
 *   - 弹药上限: asw_ammo_count_railgun 是装备表引用的 ConVar(弹匣/默认弹药),
 *     sk_max_asw_rg 是 ASW_RG 弹药类型的 MaxCarry。插件启动/地图开始/配置变化时
 *     写入, 并每秒校验一次 (防止难度或技能配置把它们覆盖回去)。
 *
 *  依赖: SourceMod 1.11+ (只用核心 API + sdktools)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] 导轨步枪 (Railgun)"
#define PLUGIN_VERSION "2.0.4"

// 武器实体类名: 游戏脚本 scripts/asw_weapon_railgun.txt 对应实体 asw_weapon_railgun
#define RAILGUN_CLASSNAME "asw_weapon_railgun"

// ============================================================================
//  ConVar 句柄
// ============================================================================
ConVar g_cvEnabled;       // 总开关
ConVar g_cvDropPublic;    // 普通玩家能否自己掉一把
ConVar g_cvDamage;        // 基础伤害 (0=原版 105)
ConVar g_cvClip;          // 弹匣容量
ConVar g_cvAmmo;          // 携带总弹药上限
ConVar g_cvFireInterval;  // 两次射击最小间隔 (秒)
ConVar g_cvDebug;

ConVar g_cvGameClip;      // 引擎 ConVar asw_ammo_count_railgun (弹匣/默认弹药)
ConVar g_cvGameMax;       // 引擎 ConVar sk_max_asw_rg (ASW_RG 弹药 MaxCarry)
ConVar g_cvGameDmgBase;   // 引擎 ConVar rd_railgun_dmg_base (伤害覆盖; 默认 0=用装备表 105)

// ============================================================================
//  运行时状态
// ============================================================================
// 实体索引数组容量: 必须 >= 服务器 GetMaxEntities() (AS:RD 实体上限可能超过 2048,
// 小了会导致循环越界中断 OnGameFrame 或新实体无法被标记)
#define RAILGUN_MAX_ENT 8193

// 本插件掉落的导轨步枪标记 (索引 = 实体编号; 只对这些枪补弹/覆写弹匣)
bool  g_bRailgun[RAILGUN_MAX_ENT];
// 所有导轨步枪实体标记 (含玩家从装备栏自带的枪; 射速钳制对它们全部生效)
bool  g_bAnyRailgun[RAILGUN_MAX_ENT];
// 每把标记枪的上次开火时刻 (游戏时间)
float g_fLastFire[RAILGUN_MAX_ENT];
// 已为哪个 marine 补过弹 (只在持有者变化时补一次)
int   g_iAppliedOwner[RAILGUN_MAX_ENT];
// 每把枪上一帧的弹匣数 (弹匣减少 = 开火, 用于射速钳制的开火时刻记录)
int   g_iLastClip[RAILGUN_MAX_ENT];
// 每把枪的钳制日志节流 (debug 输出最多每秒一条)
float g_fNextClampLog[RAILGUN_MAX_ENT];

// 引擎 ConVar 校验节流
float g_fNextEngineSync;

public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "掉落导轨步枪(railgun)并支持可调伤害/射速/弹药",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件启动: 创建 ConVar、注册命令、同步引擎 ConVar
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_railgun_enabled", "1",
        "启用/禁用导轨步枪掉落功能 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDropPublic = CreateConVar(
        "sm_asrd_railgun_drop_public", "1",
        "普通玩家能否用 sm_railgundrop 自己掉一把导轨步枪在身边 (0=仅管理员 sm_railgun_drop)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDamage = CreateConVar(
        "sm_asrd_railgun_damage", "0",
        "导轨步枪基础伤害 (0=原版 105; >0 时覆盖基础值, 技能加成仍叠加: 最终 = 该值 + 10x技能点数; 通过引擎 rd_railgun_dmg_base 实现, 全场生效; 上限 10000)",
        FCVAR_NOTIFY, true, 0.0, true, 10000.0
    );
    g_cvClip = CreateConVar(
        "sm_asrd_railgun_clip", "1",
        "导轨步枪弹匣容量 (每弹匣发数; 默认 1 = 游戏原值; 上限 200; 同时写入引擎 asw_ammo_count_railgun)",
        FCVAR_NOTIFY, true, 1.0, true, 200.0
    );
    g_cvAmmo = CreateConVar(
        "sm_asrd_railgun_ammo", "1",
        "导轨步枪携带总弹药 (拾取时写入 marine 弹药池; 默认 1 = 与原版掉落一致; 上限 2000). 游戏原版上限为 sk_max_asw_rg=72, 配置超过 72 时会自动抬高该上限",
        FCVAR_NOTIFY, true, 1.0, true, 2000.0
    );
    g_cvFireInterval = CreateConVar(
        "sm_asrd_railgun_fire_interval", "1.3",
        "两次射击的最小间隔秒数 (0=不限制; 默认 1.3 = 与原版换弹节奏一致). 弹匣只有 1 发时每发后仍需换弹 1.3 秒, 该值不会让它更快",
        FCVAR_NOTIFY, true, 0.0, true, 60.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_railgun_debug", "0",
        "调试输出到服务器控制台 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvGameClip = FindConVar("asw_ammo_count_railgun");
    g_cvGameMax  = FindConVar("sk_max_asw_rg");
    g_cvGameDmgBase = FindConVar("rd_railgun_dmg_base");
    if (g_cvGameClip == null)
        PrintToServer("[导轨步枪] 警告: 找不到引擎 ConVar asw_ammo_count_railgun, 弹匣容量设置不会生效");
    if (g_cvGameMax == null)
        PrintToServer("[导轨步枪] 警告: 找不到引擎 ConVar sk_max_asw_rg, 携带弹药会被游戏原上限限制");

    HookConVarChange(g_cvDamage, OnSettingsChanged);
    HookConVarChange(g_cvClip, OnSettingsChanged);
    HookConVarChange(g_cvAmmo, OnSettingsChanged);
    ApplyEngineSettings();

    RegAdminCmd("sm_railgun_drop", Command_RailgunDrop, ADMFLAG_GENERIC,
        "在自己身边掉一把导轨步枪");
    RegConsoleCmd("sm_railgundrop", Command_RailgunDropPublic,
        "在自己身边掉一把导轨步枪 (受 sm_asrd_railgun_drop_public 限制)");
    RegAdminCmd("sm_railgun_status", Command_RailgunStatus, ADMFLAG_GENERIC,
        "查看导轨步枪配置与场上掉落状态");

    HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);

    ScanExistingRailguns();   // 插件中途加载/热重载时, 场上已有的导轨步枪需要补标记

    AutoExecConfig(true, "asrd_railgun");
}

public void OnMapStart()
{
    ApplyEngineSettings();
    g_fNextEngineSync = 0.0;
    ScanExistingRailguns();
}

// 全量扫描场上已有的导轨步枪并标记 (插件中途加载/地图自带武器时补标记)
void ScanExistingRailguns()
{
    int iMaxEnt = GetMaxEntities();
    if (iMaxEnt > RAILGUN_MAX_ENT)
        iMaxEnt = RAILGUN_MAX_ENT;
    for (int e = MaxClients + 1; e < iMaxEnt; e++)
    {
        if (!IsValidEntity(e))
            continue;
        char sClass[64];
        if (!GetEntityClassname(e, sClass, sizeof(sClass)))
            continue;
        if (StrEqual(sClass, RAILGUN_CLASSNAME))
            MarkAsRailgun(e);
    }
}

// 标记实体为导轨步枪 (不区分来源: 插件掉落 / 玩家自带 / 地图预置)
void MarkAsRailgun(int entity)
{
    if (entity <= 0 || entity >= RAILGUN_MAX_ENT)
        return;
    if (g_bAnyRailgun[entity])
        return;   // 已标记

    g_bAnyRailgun[entity] = true;
    g_fLastFire[entity] = 0.0;
    g_iAppliedOwner[entity] = 0;
    g_iLastClip[entity] = -1;
    g_fNextClampLog[entity] = 0.0;
}

// 实体创建时标记导轨步枪 (玩家从装备栏带枪出生、挑战/插件生成都会经过这里)
public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity <= 0 || entity >= RAILGUN_MAX_ENT)
        return;
    if (!StrEqual(classname, RAILGUN_CLASSNAME))
        return;
    MarkAsRailgun(entity);
}

void OnSettingsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ApplyEngineSettings();
}

// 把插件配置写进两个引擎 ConVar (失败时静默, 启动时已打印警告)
void ApplyEngineSettings()
{
    if (g_cvGameClip != null)
    {
        int iClip = g_cvClip.IntValue;
        if (g_cvGameClip.IntValue != iClip)
            g_cvGameClip.IntValue = iClip;
    }
    if (g_cvGameMax != null)
    {
        // sk_max_asw_rg 是 ASW_RG 弹药的最大携带上限 (游戏默认 72),
        // 只在配置值超过它时才抬高, 绝不下调 (否则会减少原版可携带量)
        int iAmmo = g_cvAmmo.IntValue;
        if (g_cvGameMax.IntValue < iAmmo)
            g_cvGameMax.IntValue = iAmmo;
    }
    if (g_cvGameDmgBase != null)
    {
        // rd_railgun_dmg_base >0 时覆盖装备表基础伤害 105 (技能加成仍叠加).
        // 该 ConVar 是全局的, 某些挑战脚本 (如 traitors 随机设 100~250) 改过后
        // 换模式不会自动还原, 残留值会带进普通模式. 这里钉回我们的配置值
        // (默认 0=原版伤害), 挑战残留因此不会生效.
        float fDamage = g_cvDamage.FloatValue;
        if (g_cvGameDmgBase.FloatValue != fDamage)
        {
            if (g_cvDebug.BoolValue)
                PrintToServer("[导轨步枪] rd_railgun_dmg_base 被改为 %.1f, 已重置为配置值 %.1f",
                    g_cvGameDmgBase.FloatValue, fDamage);
            g_cvGameDmgBase.FloatValue = fDamage;
        }
    }
}

// ============================================================================
//  帧回调: 引擎 ConVar 校验 + 拾取补弹 + 射速钳制
// ============================================================================
public void OnGameFrame()
{
    float fNow = GetGameTime();

    // 引擎 ConVar 每秒校验一次 (难度切换/技能系统可能把它们改回默认值)
    if (fNow >= g_fNextEngineSync)
    {
        g_fNextEngineSync = fNow + 1.0;
        ApplyEngineSettings();
    }

    if (!g_cvEnabled.BoolValue)
        return;

    int iMaxEnt = GetMaxEntities();
    if (iMaxEnt > RAILGUN_MAX_ENT)
        iMaxEnt = RAILGUN_MAX_ENT;   // 双保险: 循环绝不越过数组边界
    for (int w = MaxClients + 1; w < iMaxEnt; w++)
    {
        if (!g_bAnyRailgun[w] || !IsValidEntity(w))
            continue;

        int iMarine = GetWeaponMarine(w);
        if (iMarine <= 0)
            continue;   // 还在地上没人捡

        // 拾取补弹: 只对插件掉落的枪, 且只在持有者变化时写一次
        if (g_bRailgun[w] && g_iAppliedOwner[w] != iMarine)
        {
            g_iAppliedOwner[w] = iMarine;
            ApplyRailgunAmmo(w, iMarine);
            if (g_cvDebug.BoolValue)
                PrintToServer("[导轨步枪] 武器 %d 被 marine %d 拾取, 已补弹匣/备弹", w, iMarine);
        }

        // 开火检测: 弹匣减少即开火 (不依赖 weapon_fire 事件的到达时序)
        int iClip = GetWeaponClip1(w);
        if (g_iLastClip[w] >= 0 && iClip < g_iLastClip[w])
        {
            g_fLastFire[w] = fNow;
            if (g_cvDebug.BoolValue)
                PrintToServer("[导轨步枪] 武器 %d 开火 (弹匣 %d -> %d)", w, g_iLastClip[w], iClip);
        }
        g_iLastClip[w] = iClip;

        // 射速: 弹匣非空时才钳制, 换弹中(clip=0)保持引擎原节奏
        float fInterval = g_cvFireInterval.FloatValue;
        if (fInterval <= 0.0)
            continue;
        if (g_fLastFire[w] <= 0.0)
            continue;   // 还没开过火, 不要凭空把首次开火推后
        if (iClip <= 0)
            continue;

        float fTarget = g_fLastFire[w] + fInterval;
        float fNext = GetWeaponNextAttack(w);
        if (fNext < fTarget)
        {
            SetWeaponNextAttack(w, fTarget);
            if (g_cvDebug.BoolValue && fNow >= g_fNextClampLog[w])
            {
                g_fNextClampLog[w] = fNow + 1.0;
                PrintToServer("[导轨步枪] 武器 %d 射速钳制: 下次开火 %.2f -> %.2f (间隔 %.2f)",
                    w, fNext, fTarget, fInterval);
            }
        }
    }
}

// weapon_fire: 记录导轨步枪的开火时刻 (下一帧据此限制最小间隔)
// 引擎在 asw_weapon_shared.cpp 里发该事件时已带上 weapon (武器实体索引) 与 marine 字段,
// 直接用 weapon 字段, 不再绕 userid→client→marine→m_hActiveWeapon (任一环节失败都会静默漏记)
public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int iWeapon = event.GetInt("weapon");
    if (iWeapon <= 0 || iWeapon >= RAILGUN_MAX_ENT || !g_bAnyRailgun[iWeapon])
        return;

    g_fLastFire[iWeapon] = GetGameTime();
    if (g_cvDebug.BoolValue)
        PrintToServer("[导轨步枪] 武器 %d 开火, 记开火时刻 %.2f", iWeapon, g_fLastFire[iWeapon]);
}

// 实体销毁: 清除标记, 避免索引复用误判
public void OnEntityDestroyed(int entity)
{
    if (entity >= 0 && entity < RAILGUN_MAX_ENT)
    {
        g_bRailgun[entity] = false;
        g_bAnyRailgun[entity] = false;
        g_fLastFire[entity] = 0.0;
        g_iAppliedOwner[entity] = 0;
        g_iLastClip[entity] = -1;
        g_fNextClampLog[entity] = 0.0;
    }
}

// ============================================================================
//  掉落: 在玩家身边生成一把导轨步枪武器实体 (走过去即可拾取)
// ============================================================================
int SpawnRailgunNear(int client)
{
    int iMarine = GetClientMarine(client);
    if (iMarine <= 0)
        return -1;

    float fPos[3], fAng[3];
    GetEntPropVector(iMarine, Prop_Send, "m_vecOrigin", fPos);
    GetClientEyeAngles(client, fAng);
    float fYaw = DegToRad(fAng[1]);
    fPos[0] += Cosine(fYaw) * 60.0;
    fPos[1] += Sine(fYaw) * 60.0;
    fPos[2] += 20.0;

    int iWeapon = CreateEntityByName(RAILGUN_CLASSNAME);
    if (iWeapon == -1)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[导轨步枪] CreateEntityByName(%s) 失败 (实体未注册?)", RAILGUN_CLASSNAME);
        return -1;
    }

    float fZeroAng[3];
    TeleportEntity(iWeapon, fPos, fZeroAng, NULL_VECTOR);
    DispatchSpawn(iWeapon);
    ActivateEntity(iWeapon);

    // 弹匣: 落地即填满 (弹匣不超过总弹药)
    int iClip = g_cvClip.IntValue;
    int iAmmo = g_cvAmmo.IntValue;
    if (iClip > iAmmo)
        iClip = iAmmo;
    SetWeaponClip1(iWeapon, iClip);

    // 备弹: 写武器的 m_iPrimaryAmmoCount, 拾取时游戏会把它加到 marine 的
    // m_iAmmo 储备池; 之后 ApplyRailgunAmmo 再按配置覆盖一次
    // (总弹药 = 弹匣 + 备弹, 所以备弹 = ammo - clip)
    int iReserve = iAmmo - iClip;
    if (iReserve < 0)
        iReserve = 0;
    if (GetEntitySendPropOff(iWeapon, "m_iPrimaryAmmoCount") != -1)
        SetEntProp(iWeapon, Prop_Send, "m_iPrimaryAmmoCount", iReserve);
    else
    {
        int iAmmoCountOff = FindDataMapInfo(iWeapon, "m_iPrimaryAmmoCount");
        if (iAmmoCountOff != -1)
            SetEntData(iWeapon, iAmmoCountOff, iReserve, 4, true);
    }

    if (iWeapon >= 0 && iWeapon < RAILGUN_MAX_ENT)
    {
        MarkAsRailgun(iWeapon);   // 射速控制对全部导轨步枪生效
        g_bRailgun[iWeapon] = true;   // 额外标记: 这把是插件掉落的, 拾取时补弹
    }
    else
    {
        PrintToServer("[导轨步枪] 错误: 武器实体索引 %d 超出插件容量 %d, 该枪不受插件控制",
            iWeapon, RAILGUN_MAX_ENT);
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[导轨步枪] 已在玩家 %N 身边生成导轨步枪 (实体 %d, 弹匣 %d, 总弹药 %d)",
            client, iWeapon, iClip, iAmmo);

    return iWeapon;
}

// ============================================================================
//  拾取补弹: 弹匣补满 + marine 弹药池写为配置值
// ============================================================================
void ApplyRailgunAmmo(int iWeapon, int iMarine)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon) || iMarine <= 0 || !IsValidEntity(iMarine))
        return;

    int iClip = g_cvClip.IntValue;
    int iAmmo = g_cvAmmo.IntValue;
    if (iClip > iAmmo)
        iClip = iAmmo;

    SetWeaponClip1(iWeapon, iClip);

    // 总弹药 = 弹匣 + 备弹: 弹药池写入 (ammo - clip), 只增不减
    int iReserve = iAmmo - iClip;
    if (iReserve < 0)
        iReserve = 0;
    int iAmmoType = GetWeaponAmmoType(iWeapon, "m_iPrimaryAmmoType");
    if (iAmmoType >= 0 && GetMarineAmmo(iMarine, iAmmoType) < iReserve)
        SetMarineAmmo(iMarine, iAmmoType, iReserve);
}

// marine 是否活着 (m_lifeState 0 = 活)
bool IsMarineAlive(int iMarine)
{
    if (iMarine <= 0 || !IsValidEntity(iMarine))
        return false;
    if (FindDataMapInfo(iMarine, "m_lifeState") != -1)
        return GetEntProp(iMarine, Prop_Data, "m_lifeState") == 0;
    return true;
}

// ============================================================================
//  命令(管理员): 在身边掉落导轨步枪
// ============================================================================
public Action Command_RailgunDrop(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        ReplyToCommand(client, "此命令只能由玩家执行");
        return Plugin_Handled;
    }
    if (!g_cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[导轨步枪]\x01 功能已禁用 (sm_asrd_railgun_enabled 0)");
        return Plugin_Handled;
    }
    int iMarine = GetClientMarine(client);
    if (iMarine <= 0)
    {
        PrintToChat(client, "\x04[导轨步枪]\x01 没找到你控制的陆战队员, 无法掉落 (请先进入游戏)");
        return Plugin_Handled;
    }
    if (!IsMarineAlive(iMarine))
    {
        PrintToChat(client, "\x04[导轨步枪]\x01 你的陆战队员已死亡, 无法掉落");
        return Plugin_Handled;
    }
    if (SpawnRailgunNear(client) == -1)
    {
        PrintToChat(client, "\x04[导轨步枪]\x01 创建导轨步枪失败 (实体 asw_weapon_railgun 可能未加载)");
        return Plugin_Handled;
    }
    PrintToChat(client, "\x04[导轨步枪]\x01 已在身边掉落一把导轨步枪, 走过去按 \x05E\x01 (使用键) 拾取");
    return Plugin_Handled;
}

// ============================================================================
//  命令(玩家): 经积分插件购买后转发到此 (需 sm_asrd_railgun_drop_public 1)
// ============================================================================
public Action Command_RailgunDropPublic(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        ReplyToCommand(client, "此命令只能由玩家执行");
        return Plugin_Handled;
    }
    if (!g_cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[导轨步枪]\x01 功能已禁用 (sm_asrd_railgun_enabled 0)");
        return Plugin_Handled;
    }
    if (!g_cvDropPublic.BoolValue)
    {
        PrintToChat(client, "\x04[导轨步枪]\x01 掉落功能未对玩家开放 (需 sm_asrd_railgun_drop_public 1)");
        return Plugin_Handled;
    }
    // 用 marine 实体判断是否真正在游戏中 (AS:RD 玩家本体不是 marine,
    // 不能用 IsPlayerAlive(client) 代表 marine 存活)
    int iMarine = GetClientMarine(client);
    if (iMarine <= 0)
    {
        PrintToChat(client, "\x04[导轨步枪]\x01 没找到你控制的陆战队员, 无法掉落 (请先进入游戏)");
        return Plugin_Handled;
    }
    if (!IsMarineAlive(iMarine))
    {
        PrintToChat(client, "\x04[导轨步枪]\x01 你的陆战队员已死亡, 无法掉落");
        return Plugin_Handled;
    }
    if (SpawnRailgunNear(client) == -1)
    {
        PrintToChat(client, "\x04[导轨步枪]\x01 创建导轨步枪失败 (实体 asw_weapon_railgun 可能未加载)");
        return Plugin_Handled;
    }
    PrintToChat(client, "\x04[导轨步枪]\x01 已在身边掉落一把导轨步枪, 走过去按 \x05E\x01 (使用键) 拾取");
    return Plugin_Handled;
}

// ============================================================================
//  命令(管理员): 查看配置与场上状态
// ============================================================================
public Action Command_RailgunStatus(int client, int args)
{
    PrintToConsole(client, "========== 导轨步枪状态 (v%s) ==========", PLUGIN_VERSION);
    PrintToConsole(client, "启用: %s | 玩家自掉: %s",
        g_cvEnabled.BoolValue ? "开" : "关",
        g_cvDropPublic.BoolValue ? "开" : "关");
    PrintToConsole(client, "弹匣容量: %d | 携带总弹药: %d | 射击最小间隔: %.2f 秒",
        g_cvClip.IntValue, g_cvAmmo.IntValue, g_cvFireInterval.FloatValue);
    PrintToConsole(client, "基础伤害: %s",
        g_cvDamage.FloatValue > 0.0 ? "自定义" : "原版 (105 + 技能加成)");
    if (g_cvDamage.FloatValue > 0.0)
        PrintToConsole(client, "  (基础伤害 = %.1f, 技能加成仍叠加: 最终 = 该值 + 10x技能点数)", g_cvDamage.FloatValue);
    char sClip[16] = "缺失";
    char sMax[16]  = "缺失";
    if (g_cvGameClip != null)
        Format(sClip, sizeof(sClip), "%d", g_cvGameClip.IntValue);
    if (g_cvGameMax != null)
        Format(sMax, sizeof(sMax), "%d", g_cvGameMax.IntValue);
    PrintToConsole(client, "引擎 asw_ammo_count_railgun = %s | sk_max_asw_rg = %s", sClip, sMax);
    PrintToConsole(client, "------------------------------");

    int iCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !IsPlayerAlive(i))
            continue;

        int iMarine = GetClientMarine(i);
        if (iMarine <= 0)
            continue;

        int iWeapon = GetMarineActiveWeapon(iMarine);
        if (iWeapon <= 0 || iWeapon >= RAILGUN_MAX_ENT || !g_bAnyRailgun[iWeapon])
            continue;

        iCount++;
        PrintToConsole(client, "%N 手持导轨步枪 (实体 %d, 弹匣 %d, %s)",
            i, iWeapon, GetWeaponClip1(iWeapon),
            g_bRailgun[iWeapon] ? "插件掉落" : "自带/其它来源");
    }
    if (iCount == 0)
        PrintToConsole(client, "当前没有玩家手持导轨步枪");
    PrintToConsole(client, "------------------------------");
    return Plugin_Handled;
}

// ============================================================================
//  实体/属性辅助
// ============================================================================
bool IsMarine(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;
    char sClass[32];
    if (!GetEntityClassname(entity, sClass, sizeof(sClass)))
        return false;
    return StrEqual(sClass, "asw_marine", false);
}

// 解析 marine 的控制者 client (没有则 -1)
//   注意: AS:RD 的 marine 是 CASW_Inhabitable_NPC, 控制者属性名是 m_Commander
//   (见参考源码 src/game/shared/swarm/asw_inhabitable_npc_shared.cpp 的 GetCommander),
//   并不存在 m_hCommander, 写错属性名会导致永远找不到 marine
int GetMarineCommander(int iMarine)
{
    if (!IsMarine(iMarine))
        return -1;

    if (FindDataMapInfo(iMarine, "m_Commander") != -1)
    {
        int c = GetEntPropEnt(iMarine, Prop_Data, "m_Commander");
        if (c > 0 && IsClientInGame(c) && !IsFakeClient(c))
            return c;
    }
    if (GetEntitySendPropOff(iMarine, "m_Commander") != -1)
    {
        int c = GetEntPropEnt(iMarine, Prop_Send, "m_Commander");
        if (c > 0 && IsClientInGame(c) && !IsFakeClient(c))
            return c;
    }
    return -1;
}

// marine 当前手持武器 (0=无)
int GetMarineActiveWeapon(int iMarine)
{
    if (!IsMarine(iMarine))
        return 0;

    if (FindDataMapInfo(iMarine, "m_hActiveWeapon") != -1)
    {
        int w = GetEntPropEnt(iMarine, Prop_Data, "m_hActiveWeapon");
        if (w > 0)
            return w;
    }
    if (GetEntitySendPropOff(iMarine, "m_hActiveWeapon") != -1)
    {
        int w = GetEntPropEnt(iMarine, Prop_Send, "m_hActiveWeapon");
        if (w > 0)
            return w;
    }
    return 0;
}

// 玩家当前控制的陆战队员 (0=未控制)
//   AS:RD 里玩家本体不是 marine, 需要从"marine 的控制者属性 m_Commander"
//   或"玩家实体的 m_hInhabiting"两头找; 逐个比对 marine 的 m_Commander 是
//   积分插件同一套路, 因此放在最前面
int GetClientMarine(int client)
{
    if (client <= 0 || !IsClientInGame(client))
        return 0;

    // 办法1: 遍历所有 marine, 找控制者是该玩家的那个
    int iEnt = -1;
    while ((iEnt = FindEntityByClassname(iEnt, "asw_marine")) != -1)
    {
        if (GetMarineCommander(iEnt) == client)
            return iEnt;
    }

    // 办法2: 玩家实体的 m_hInhabiting 网络属性
    if (GetEntitySendPropOff(client, "m_hInhabiting") != -1)
    {
        int iMarine = GetEntPropEnt(client, Prop_Send, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    // 办法3: 玩家实体的 m_hInhabiting 数据属性
    if (FindDataMapInfo(client, "m_hInhabiting") != -1)
    {
        int iMarine = GetEntPropEnt(client, Prop_Data, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    return 0;
}

// 解析某把武器当前被哪个 marine 持有 (没有持有者返回 -1)
int GetWeaponMarine(int iWeapon)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        return -1;

    int iOwner = GetEntPropEnt(iWeapon, Prop_Send, "m_hOwnerEntity");
    if (iOwner <= 0 && FindDataMapInfo(iWeapon, "m_hOwner") != -1)
        iOwner = GetEntPropEnt(iWeapon, Prop_Data, "m_hOwner");

    if (iOwner <= 0)
        return -1;
    if (IsMarine(iOwner))
        return iOwner;
    if (IsClientInGame(iOwner))
        return GetClientMarine(iOwner);
    return -1;
}

// 用实体实际网络类名查发送属性偏移
int GetEntitySendPropOff(int entity, const char[] sProp)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return -1;
    char sNetClass[64];
    if (!GetEntityNetClass(entity, sNetClass, sizeof(sNetClass)) || !sNetClass[0])
        return -1;
    return FindSendPropInfo(sNetClass, sProp);
}

// 读取武器弹药类型索引 (先 sendprop 再 datamap)
int GetWeaponAmmoType(int iWeapon, const char[] sProp)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        return -1;
    if (GetEntitySendPropOff(iWeapon, sProp) != -1)
        return GetEntProp(iWeapon, Prop_Send, sProp);
    int dm = FindDataMapInfo(iWeapon, sProp);
    if (dm != -1)
        return GetEntProp(iWeapon, Prop_Data, sProp);
    return -1;
}

int GetWeaponClip1(int iWeapon)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        return -1;
    if (GetEntitySendPropOff(iWeapon, "m_iClip1") != -1)
        return GetEntProp(iWeapon, Prop_Send, "m_iClip1");
    int dm = FindDataMapInfo(iWeapon, "m_iClip1");
    if (dm != -1)
        return GetEntData(iWeapon, dm, 4);
    return -1;
}

void SetWeaponClip1(int iWeapon, int iClip)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        return;
    if (GetEntitySendPropOff(iWeapon, "m_iClip1") != -1)
        SetEntProp(iWeapon, Prop_Send, "m_iClip1", iClip);
    else
    {
        int dm = FindDataMapInfo(iWeapon, "m_iClip1");
        if (dm != -1)
            SetEntData(iWeapon, dm, iClip, 4, true);
    }
}

float GetWeaponNextAttack(int iWeapon)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        return 0.0;
    if (GetEntitySendPropOff(iWeapon, "m_flNextPrimaryAttack") != -1)
        return GetEntPropFloat(iWeapon, Prop_Send, "m_flNextPrimaryAttack");
    int dm = FindDataMapInfo(iWeapon, "m_flNextPrimaryAttack");
    if (dm != -1)
        return GetEntDataFloat(iWeapon, dm);
    return 0.0;
}

void SetWeaponNextAttack(int iWeapon, float fValue)
{
    if (iWeapon <= 0 || !IsValidEntity(iWeapon))
        return;
    if (GetEntitySendPropOff(iWeapon, "m_flNextPrimaryAttack") != -1)
        SetEntPropFloat(iWeapon, Prop_Send, "m_flNextPrimaryAttack", fValue);
    else
    {
        int dm = FindDataMapInfo(iWeapon, "m_flNextPrimaryAttack");
        if (dm != -1)
            SetEntDataFloat(iWeapon, dm, fValue, true);
    }
}

// 解析 marine 实体上 m_iAmmo 发送属性偏移
//   m_iAmmo 是 DT_ASW_Marine 里的 SendPropArray3 (sendprop 数组, 不在 datamap),
//   必须走 Prop_Send, 且写入时带元素下标。
int GetMarineAmmoOffset(int iMarine)
{
    if (iMarine <= 0 || !IsValidEntity(iMarine))
        return -1;
    return GetEntitySendPropOff(iMarine, "m_iAmmo");
}

// 读取 marine 的 m_iAmmo[弹药类型] 储备池
int GetMarineAmmo(int iMarine, int iAmmoType)
{
    if (iAmmoType < 0)
        return 0;
    int off = GetMarineAmmoOffset(iMarine);
    if (off == -1)
        return 0;
    int iValue = GetEntProp(iMarine, Prop_Send, "m_iAmmo", iAmmoType);
    if (iValue < 0)
        iValue = GetEntData(iMarine, off + iAmmoType * 4, 4);
    return iValue > 0 ? iValue : 0;
}

// 给 marine 的 m_iAmmo[弹药类型] 储备池写弹药数量, 写完读回验证
void SetMarineAmmo(int iMarine, int iAmmoType, int iCount)
{
    if (iAmmoType < 0 || iCount < 0)
        return;

    int off = GetMarineAmmoOffset(iMarine);
    if (off == -1)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[导轨步枪] 设置弹药失败: 找不到 marine(%d) 的 m_iAmmo 发送属性 (弹药类型=%d)",
                iMarine, iAmmoType);
        return;
    }

    // 方案1: SourceMod 标准 sendprop 数组写入 (元素下标 = 弹药类型)
    SetEntProp(iMarine, Prop_Send, "m_iAmmo", iCount, iAmmoType);
    int iNow = GetEntProp(iMarine, Prop_Send, "m_iAmmo", iAmmoType);
    if (iNow == iCount)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[导轨步枪] 已写 marine %d m_iAmmo[%d]=%d (偏移 %d)",
                iMarine, iAmmoType, iCount, off);
        return;
    }

    // 方案2: 绝对偏移直写 (CNetworkArray 数据内联, 元素步长 4 字节, changeState=true 触发同步)
    SetEntData(iMarine, off + iAmmoType * 4, iCount, 4, true);
    int iNow2 = GetEntProp(iMarine, Prop_Send, "m_iAmmo", iAmmoType);
    if (iNow2 == iCount)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[导轨步枪] m_iAmmo[%d] SetEntProp 读回不一致, SetEntData 写入成功: %d",
                iAmmoType, iCount);
        return;
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[导轨步枪] 警告: marine %d m_iAmmo[%d] 写入读回不一致 (期望 %d, SetEntProp后=%d, SetEntData后=%d)",
            iMarine, iAmmoType, iCount, iNow, iNow2);
}
