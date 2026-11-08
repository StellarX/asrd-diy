/**
 * ============================================================================
 *  [AS:RD] AVK-36 神射手步枪 (AVK-36 Marksman Rifle)
 *  版本 1.0.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ─────────────────────────────────────
 *  把 AVK-36 神射手步枪 (游戏内部即"狙击步枪"):
 *      武器实体 asw_weapon_sniper_rifle
 *      (源码 src/game/shared/swarm/asw_weapon_sniper_rifle.cpp:74
 *       LINK_ENTITY_TO_CLASS( asw_weapon_sniper_rifle, CASW_Weapon_Sniper_Rifle );
 *       世界模型 marksmanrifle)
 *  生成在玩家身边供拾取, 供积分插件购买 (#buy 6 5) 与自动掉落使用;
 *  并支持调节它的主要属性: 伤害倍率 / 弹匣 / 备弹 / 射速。
 *
 *  ── 游戏原始数据 (源码 asw_equipment_list.cpp 的狙击步枪装备项) ──
 *    装备项 ASW_EQUIP_SNIPER_RIFLE (L320-L329):
 *      伤害 65, 射击间隔 0.72 秒, 换弹 2.0 秒;
 *      弹匣容量 / 默认弹药 = ConVar asw_ammo_count_sniper_rifle (默认 12);
 *      弹药类型 ASW_SNIPER, 携带上限 sk_max_asw_sniper (默认 60, asw_gamerules.cpp:790);
 *      开镜时: 伤害额外 + rd_sniper_rifle_dmg_zoomed_bonus (默认 186, 见
 *      asw_weapon_sniper_rifle.cpp:39), 射速乘 1.9 (GetFireRate, L247-L255);
 *      开镜穿透目标数 2 (普通 1), 穿透衰减 3.5 倍。
 *    说明: rd_sniper_rifle_dmg_zoomed_bonus 带 FCVAR_CHEAT, 不能在运行时改写,
 *          所以"开镜额外伤害"保持游戏原值; 本插件的伤害倍率对开镜后的总伤害同样生效。
 *
 *  ── 命令 ───────────────────────────────────────────────
 *   sm_avk36_drop    管理员: 在自己身边掉一把 AVK-36
 *   sm_avk36drop     玩家: 同上 (受 sm_asrd_avk36_drop_public 限制; 积分插件调用)
 *   sm_avk36_status  管理员: 查看配置与场上掉落状态
 *
 *  ── ConVar (自动生成 cfg/sourcemod/asrd_avk36.cfg) ──
 *   sm_asrd_avk36_enabled        总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_avk36_drop_public    玩家能否自行掉落 (0=仅管理员, 默认 1)
 *   sm_asrd_avk36_dmg_mult       伤害倍率 (默认 1.0 = 游戏原值 65; 仅本插件掉落的枪生效;
 *                                对虫族/场景物体/队友都生效; 上限 500)
 *   sm_asrd_avk36_clip           弹匣容量 (0=不覆盖, 沿用游戏 12; 上限 200;
 *                                设 >12 时会把引擎 asw_ammo_count_sniper_rifle 抬高,
 *                                该 ConVar 是全局的, 场上所有狙击步枪弹匣都会变大)
 *   sm_asrd_avk36_reserve        携带备弹 (0=不覆盖, 沿用游戏 60; 上限 2000;
 *                                拾取时只"补到不低于"该值, 不会清掉玩家原有备弹;
 *                                超过 60 时会把引擎 sk_max_asw_sniper 抬高)
 *   sm_asrd_avk36_fire_interval  两次射击最小间隔秒 (0=不干预, 保持游戏原节奏;
 *                                开镜射速为原值 ×1.9, 该值同样会钳制开镜后的连发)
 *   sm_asrd_avk36_debug          调试输出 (默认 0)
 *
 *  ── 实现原理 ───────────────────────────────────────────
 *   - 掉落: CreateEntityByName("asw_weapon_sniper_rifle") + Teleport + DispatchSpawn
 *     + ActivateEntity, 在 marine 身前 60 单位; 用 g_bAvk[] 标记"本插件掉的枪",
 *     玩家自带狙击步枪不受任何影响。
 *   - 拾取: 每帧检查标记枪的持有者是否变化, 变化时按配置写弹匣与 marine 弹药池
 *     (m_iAmmo 是 DT_ASW_Marine 的 SendPropArray3, 必须 Prop_Send + 元素下标)。
 *   - 伤害: 与 asrd_watcher_pulse_rifle.sp 同源方案 —— 给所有实体挂
 *     SDKHook_OnTakeDamage, 只有"伤害来源武器是本插件标记的 asw_weapon_sniper_rifle"
 *     时才把 damage 乘以倍率 (用 g_bDamageHooked[] 去重防止倍率叠加)。
 *   - 射速: weapon_fire 事件记录每把标记枪的开火时刻, 每帧把 m_flNextPrimaryAttack
 *     钳到 max(当前值, 上次开火 + fire_interval); 只在弹匣非空时干预,
 *     换弹/空弹时保持引擎原节奏。
 *
 *  依赖: SourceMod 1.11+ (只用核心 API + sdktools + sdkhooks)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] AVK-36 神射手步枪"
#define PLUGIN_VERSION "1.0.0"

// 武器实体类名: 游戏里 AVK-36 就是狙击步枪 asw_weapon_sniper_rifle
#define AVK_CLASSNAME "asw_weapon_sniper_rifle"

// 实体数组上限 (引擎最大实体数 2048 + 1)
#define MAX_ENT 2049

// ============================================================================
//  ConVar 句柄
// ============================================================================
ConVar g_cvEnabled;
ConVar g_cvDropPublic;
ConVar g_cvDmgMult;
ConVar g_cvClip;
ConVar g_cvReserve;
ConVar g_cvFireInterval;
ConVar g_cvDebug;

ConVar g_cvGameClip;   // 引擎 ConVar asw_ammo_count_sniper_rifle (弹匣/默认弹药)
ConVar g_cvGameMax;    // 引擎 ConVar sk_max_asw_sniper (ASW_SNIPER 携带上限)

// ============================================================================
//  运行时状态
// ============================================================================
bool  g_bAvk[MAX_ENT];            // 本插件掉落的 AVK-36 标记
bool  g_bDamageHooked[MAX_ENT];   // 伤害钩子去重
int   g_iAppliedOwner[MAX_ENT];   // 已为哪个 marine 补过弹
float g_fLastFire[MAX_ENT];       // 上次开火时刻 (射速钳制用)

float g_fNextEngineSync;

public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "掉落 AVK-36 神射手步枪(狙击步枪)并支持可调伤害/弹匣/备弹/射速",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件启动
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_avk36_enabled", "1",
        "启用/禁用 AVK-36 神射手步枪掉落功能 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDropPublic = CreateConVar(
        "sm_asrd_avk36_drop_public", "1",
        "普通玩家能否用 sm_avk36drop 自己掉一把 AVK-36 在身边 (0=仅管理员 sm_avk36_drop)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDmgMult = CreateConVar(
        "sm_asrd_avk36_dmg_mult", "1.0",
        "AVK-36 伤害倍率 (1.0=游戏原值 65; 仅本插件掉落的枪生效; 对虫族/场景物体/队友均生效; 上限 500)",
        FCVAR_NOTIFY, true, 0.01, true, 500.0
    );
    g_cvClip = CreateConVar(
        "sm_asrd_avk36_clip", "0",
        "AVK-36 弹匣容量 (0=不覆盖, 沿用游戏 12; 设 >12 时会抬高引擎 asw_ammo_count_sniper_rifle —— 该值全局生效, 场上所有狙击步枪弹匣都会变大; 上限 200)",
        FCVAR_NOTIFY, true, 0.0, true, 200.0
    );
    g_cvReserve = CreateConVar(
        "sm_asrd_avk36_reserve", "0",
        "AVK-36 携带备弹 (0=不覆盖, 沿用游戏 60; 拾取时只补到不低于该值, 不清除玩家原有备弹; 超过 60 时会抬高引擎 sk_max_asw_sniper; 上限 2000)",
        FCVAR_NOTIFY, true, 0.0, true, 2000.0
    );
    g_cvFireInterval = CreateConVar(
        "sm_asrd_avk36_fire_interval", "0.0",
        "AVK-36 两次射击的最小间隔秒数 (0=不干预, 保持游戏原节奏 0.72 秒/开镜 ×1.9; 仅在弹匣非空时钳制)",
        FCVAR_NOTIFY, true, 0.0, true, 10.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_avk36_debug", "0",
        "调试输出到服务器控制台 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvGameClip = FindConVar("asw_ammo_count_sniper_rifle");
    g_cvGameMax  = FindConVar("sk_max_asw_sniper");
    if (g_cvGameClip == null)
        PrintToServer("[AVK-36] 警告: 找不到引擎 ConVar asw_ammo_count_sniper_rifle, 弹匣容量设置不会生效");
    if (g_cvGameMax == null)
        PrintToServer("[AVK-36] 警告: 找不到引擎 ConVar sk_max_asw_sniper, 备弹会被游戏原上限(60)截断");

    HookConVarChange(g_cvClip, OnSettingsChanged);
    HookConVarChange(g_cvReserve, OnSettingsChanged);
    ApplyEngineSettings();

    RegAdminCmd("sm_avk36_drop", Command_AvkDrop, ADMFLAG_GENERIC,
        "在自己身边掉一把 AVK-36");
    RegConsoleCmd("sm_avk36drop", Command_AvkDropPublic,
        "在自己身边掉一把 AVK-36 (受 sm_asrd_avk36_drop_public 限制)");
    RegAdminCmd("sm_avk36_status", Command_AvkStatus, ADMFLAG_GENERIC,
        "查看 AVK-36 配置与场上掉落状态");

    HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);

    AutoExecConfig(true, "asrd_avk36");
}

public void OnMapStart()
{
    ApplyEngineSettings();
    g_fNextEngineSync = 0.0;
    // 地图已存在的实体补挂伤害回调 (之后生成的由 OnEntityCreated 挂)
    for (int e = 1; e < MAX_ENT; e++)
        TryHookDamage(e);
}

void OnSettingsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ApplyEngineSettings();
}

// 把"弹匣/备弹"写进引擎 ConVar —— 只抬高, 绝不下调, 免得削减游戏原本的数值
void ApplyEngineSettings()
{
    if (g_cvGameClip != null)
    {
        int iWant = g_cvClip.IntValue;
        if (iWant > 0 && g_cvGameClip.IntValue < iWant)
            g_cvGameClip.IntValue = iWant;
    }
    if (g_cvGameMax != null)
    {
        int iWant = g_cvReserve.IntValue;
        if (iWant > 0 && g_cvGameMax.IntValue < iWant)
            g_cvGameMax.IntValue = iWant;
    }
}

// ============================================================================
//  帧回调: 引擎 ConVar 校验 + 拾取补弹 + 射速钳制
// ============================================================================
public void OnGameFrame()
{
    if (!g_cvEnabled.BoolValue)
        return;

    float fNow = GetGameTime();

    // 引擎 ConVar 每秒校验一次 (难度切换/技能系统可能把它们改回默认值)
    if (fNow >= g_fNextEngineSync)
    {
        g_fNextEngineSync = fNow + 1.0;
        ApplyEngineSettings();
    }

    int iMaxEnt = GetMaxEntities();
    for (int w = MaxClients + 1; w < iMaxEnt; w++)
    {
        if (!g_bAvk[w] || !IsValidEntity(w))
            continue;

        int iMarine = GetWeaponMarine(w);
        if (iMarine <= 0)
            continue;   // 还在地上没人捡

        // 拾取补弹: 持有者变化时写一次
        if (g_iAppliedOwner[w] != iMarine)
        {
            g_iAppliedOwner[w] = iMarine;
            ApplyAvkAmmo(w, iMarine);
            if (g_cvDebug.BoolValue)
                PrintToServer("[AVK-36] 武器 %d 被 marine %d 拾取, 已按配置补弹", w, iMarine);
        }

        // 射速: 弹匣非空时才钳制; 换弹/空弹保持引擎原节奏
        float fInterval = g_cvFireInterval.FloatValue;
        if (fInterval <= 0.0)
            continue;
        if (g_fLastFire[w] <= 0.0)
            continue;

        int iClip = GetWeaponClip1(w);
        if (iClip <= 0)
            continue;

        float fTarget = g_fLastFire[w] + fInterval;
        if (GetWeaponNextAttack(w) < fTarget)
            SetWeaponNextAttack(w, fTarget);
    }
}

// weapon_fire: 记录标记枪的开火时刻
public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client))
        return;

    int iMarine = GetClientMarine(client);
    if (iMarine <= 0)
        return;

    int iWeapon = GetMarineActiveWeapon(iMarine);
    if (iWeapon <= 0 || iWeapon >= MAX_ENT || !g_bAvk[iWeapon])
        return;

    g_fLastFire[iWeapon] = GetGameTime();
}

// ============================================================================
//  伤害倍率: 只放大"本插件掉落的 AVK-36"造成的伤害
//  方案同 asrd_watcher_pulse_rifle.sp: 给所有实体挂 OnTakeDamage,
//  从 weapon / inflictor 参数判断伤害来源武器。
// ============================================================================
void TryHookDamage(int entity)
{
    if (entity <= 0 || entity >= MAX_ENT || !IsValidEntity(entity))
        return;
    char sClass[16];
    if (GetEntityClassname(entity, sClass, sizeof(sClass)) && StrEqual(sClass, "worldspawn"))
        return;
    if (g_bDamageHooked[entity])
        return;
    if (SDKHookEx(entity, SDKHook_OnTakeDamage, OnAvkDamaged))
        g_bDamageHooked[entity] = true;
}

public void OnEntityCreated(int entity, const char[] classname)
{
    TryHookDamage(entity);
}

public Action OnAvkDamaged(int victim, int &attacker, int &inflictor,
    float &damage, int &damagetype, int &weapon,
    float damageForce[3], float damagePosition[3], int damagecustom)
{
    if (damage <= 0.0)
        return Plugin_Continue;

    float mult = g_cvDmgMult.FloatValue;
    if (mult <= 0.0 || mult == 1.0)
        return Plugin_Continue;
    if (attacker == victim)
        return Plugin_Continue;

    // 伤害来源武器: OnTakeDamage 的 weapon 参数, 没有则退回 inflictor
    int iWep = (weapon > 0 && IsValidEntity(weapon)) ? weapon : inflictor;
    if (iWep <= 0 || iWep >= MAX_ENT || !IsValidEntity(iWep))
        return Plugin_Continue;
    if (!g_bAvk[iWep])
        return Plugin_Continue;

    char sClass[32];
    if (!GetEntityClassname(iWep, sClass, sizeof(sClass))
        || !StrEqual(sClass, AVK_CLASSNAME))
        return Plugin_Continue;

    if (g_cvDebug.BoolValue)
        PrintToServer("[AVK-36] 伤害倍率 x%.2f (%.1f -> %.1f) 受害者 %d",
            mult, damage, damage * mult, victim);

    damage *= mult;
    return Plugin_Changed;
}

// 实体销毁: 清标记, 避免索引复用误判
public void OnEntityDestroyed(int entity)
{
    if (entity < 0 || entity >= MAX_ENT)
        return;
    g_bAvk[entity] = false;
    g_bDamageHooked[entity] = false;
    g_fLastFire[entity] = 0.0;
    g_iAppliedOwner[entity] = 0;
}

// ============================================================================
//  掉落: 在玩家（其 marine）身边生成一把 AVK-36 武器实体
// ============================================================================
int SpawnAvkNear(int client)
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

    int iWeapon = CreateEntityByName(AVK_CLASSNAME);
    if (iWeapon == -1)
    {
        PrintToServer("[AVK-36] CreateEntityByName(%s) 失败 (实体未注册?)", AVK_CLASSNAME);
        return -1;
    }

    float fZeroAng[3];
    TeleportEntity(iWeapon, fPos, fZeroAng, NULL_VECTOR);
    DispatchSpawn(iWeapon);
    ActivateEntity(iWeapon);

    // 落地即按配置填弹匣 (0=不覆盖, 保持引擎默认 12)
    int iClip = g_cvClip.IntValue;
    if (iClip > 0)
        SetWeaponClip1(iWeapon, iClip);

    g_bAvk[iWeapon] = true;
    g_fLastFire[iWeapon] = 0.0;
    g_iAppliedOwner[iWeapon] = 0;

    if (g_cvDebug.BoolValue)
        PrintToServer("[AVK-36] 已在玩家 %d 身边生成武器实体 %d", client, iWeapon);
    return iWeapon;
}

// 拾取时写弹匣与 marine 弹药池 (只抬高备弹, 不清除玩家原有弹药)
void ApplyAvkAmmo(int iWeapon, int iMarine)
{
    int iClip = g_cvClip.IntValue;
    if (iClip > 0)
        SetWeaponClip1(iWeapon, iClip);

    int iReserve = g_cvReserve.IntValue;
    if (iReserve <= 0)
        return;   // 不覆盖备弹

    int iAmmoType = GetWeaponAmmoType(iWeapon, "m_iPrimaryAmmoType");
    if (iAmmoType < 0)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[AVK-36] 读不到武器 %d 的 m_iPrimaryAmmoType, 跳过备弹设置", iWeapon);
        return;
    }

    if (GetMarineAmmo(iMarine, iAmmoType) < iReserve)
        SetMarineAmmo(iMarine, iAmmoType, iReserve);
}

// ============================================================================
//  命令
// ============================================================================
public Action Command_AvkDrop(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        ReplyToCommand(client, "此命令只能由玩家执行");
        return Plugin_Handled;
    }
    if (!g_cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[AVK-36]\x01 功能已禁用 (sm_asrd_avk36_enabled 0)");
        return Plugin_Handled;
    }
    int iMarine = GetClientMarine(client);
    if (iMarine <= 0 || !IsMarineAlive(iMarine))
    {
        PrintToChat(client, "\x04[AVK-36]\x01 没找到存活的陆战队员, 无法掉落");
        return Plugin_Handled;
    }
    if (SpawnAvkNear(client) == -1)
    {
        PrintToChat(client, "\x04[AVK-36]\x01 创建 AVK-36 失败 (实体 asw_weapon_sniper_rifle 可能未加载)");
        return Plugin_Handled;
    }
    PrintToChat(client, "\x04[AVK-36]\x01 已在身边掉落一把 AVK-36, 走过去按 \x05E\x01 (使用键) 拾取");
    return Plugin_Handled;
}

// 玩家命令: 积分插件购买转发到这里 (失败提示必须用 PrintToChat, 玩家才看得到)
public Action Command_AvkDropPublic(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        ReplyToCommand(client, "此命令只能由玩家执行");
        return Plugin_Handled;
    }
    if (!g_cvEnabled.BoolValue)
    {
        PrintToChat(client, "\x04[AVK-36]\x01 功能已禁用 (sm_asrd_avk36_enabled 0)");
        return Plugin_Handled;
    }
    if (!g_cvDropPublic.BoolValue)
    {
        PrintToChat(client, "\x04[AVK-36]\x01 掉落功能未对玩家开放 (需 sm_asrd_avk36_drop_public 1)");
        return Plugin_Handled;
    }
    int iMarine = GetClientMarine(client);
    if (iMarine <= 0)
    {
        PrintToChat(client, "\x04[AVK-36]\x01 没找到你控制的陆战队员, 无法掉落 (请先进入游戏)");
        return Plugin_Handled;
    }
    if (!IsMarineAlive(iMarine))
    {
        PrintToChat(client, "\x04[AVK-36]\x01 你的陆战队员已死亡, 无法掉落");
        return Plugin_Handled;
    }
    if (SpawnAvkNear(client) == -1)
    {
        PrintToChat(client, "\x04[AVK-36]\x01 创建 AVK-36 失败 (实体 asw_weapon_sniper_rifle 可能未加载)");
        return Plugin_Handled;
    }
    PrintToChat(client, "\x04[AVK-36]\x01 已在身边掉落一把 AVK-36, 走过去按 \x05E\x01 (使用键) 拾取");
    return Plugin_Handled;
}

public Action Command_AvkStatus(int client, int args)
{
    int iCount = 0;
    int iHeld = 0;
    for (int w = MaxClients + 1; w < MAX_ENT; w++)
    {
        if (!g_bAvk[w] || !IsValidEntity(w))
            continue;
        iCount++;
        if (GetWeaponMarine(w) > 0)
            iHeld++;
    }
    ReplyToCommand(client, "[AVK-36] 总开关=%d 玩家掉落=%d 伤害倍率=%.2f 弹匣=%d(0=原版) 备弹=%d(0=原版) 射击间隔=%.2f(0=原版)",
        g_cvEnabled.IntValue, g_cvDropPublic.IntValue, g_cvDmgMult.FloatValue,
        g_cvClip.IntValue, g_cvReserve.IntValue, g_cvFireInterval.FloatValue);
    ReplyToCommand(client, "[AVK-36] 场上本插件掉落的 AVK-36: %d 把 (其中被拾取 %d 把)", iCount, iHeld);
    return Plugin_Handled;
}

// ============================================================================
//  工具函数
// ============================================================================
bool IsMarine(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;
    char sClass[32];
    if (!GetEntityClassname(entity, sClass, sizeof(sClass)))
        return false;
    return StrEqual(sClass, "asw_marine");
}

bool IsMarineAlive(int iMarine)
{
    if (iMarine <= 0 || !IsValidEntity(iMarine))
        return false;
    if (FindDataMapInfo(iMarine, "m_lifeState") != -1)
        return GetEntProp(iMarine, Prop_Data, "m_lifeState") == 0;
    return true;
}

// 解析 marine 的控制者 client (没有则 -1)
//   注意: AS:RD marine 的控制者属性是 m_Commander (不是 m_hCommander)
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

// 玩家当前操控的 marine (三种办法, 与 asrd_railgun.sp 一致)
int GetClientMarine(int client)
{
    if (client <= 0 || !IsClientInGame(client))
        return 0;

    int iEnt = -1;
    while ((iEnt = FindEntityByClassname(iEnt, "asw_marine")) != -1)
    {
        if (GetMarineCommander(iEnt) == client)
            return iEnt;
    }

    if (GetEntitySendPropOff(client, "m_hInhabiting") != -1)
    {
        int iMarine = GetEntPropEnt(client, Prop_Send, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    if (FindDataMapInfo(client, "m_hInhabiting") != -1)
    {
        int iMarine = GetEntPropEnt(client, Prop_Data, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }
    return 0;
}

// 武器当前被哪个 marine 持有 (没有则 -1)
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

int GetEntitySendPropOff(int entity, const char[] sProp)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return -1;
    char sNetClass[64];
    if (!GetEntityNetClass(entity, sNetClass, sizeof(sNetClass)) || !sNetClass[0])
        return -1;
    return FindSendPropInfo(sNetClass, sProp);
}

// marine 当前手持武器 (m_hActiveWeapon 为 CBaseCombatCharacter 的发送属性)
int GetMarineActiveWeapon(int iMarine)
{
    if (iMarine <= 0 || !IsValidEntity(iMarine))
        return -1;
    if (GetEntitySendPropOff(iMarine, "m_hActiveWeapon") != -1)
    {
        int w = GetEntPropEnt(iMarine, Prop_Send, "m_hActiveWeapon");
        if (w > 0 && IsValidEntity(w))
            return w;
    }
    int dm = FindDataMapInfo(iMarine, "m_hActiveWeapon");
    if (dm != -1)
    {
        int w = GetEntPropEnt(iMarine, Prop_Data, "m_hActiveWeapon");
        if (w > 0 && IsValidEntity(w))
            return w;
    }
    return -1;
}

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

// m_iAmmo 是 DT_ASW_Marine 的 SendPropArray3 (sendprop 数组, 不在 datamap)
int GetMarineAmmoOffset(int iMarine)
{
    if (iMarine <= 0 || !IsValidEntity(iMarine))
        return -1;
    return GetEntitySendPropOff(iMarine, "m_iAmmo");
}

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

void SetMarineAmmo(int iMarine, int iAmmoType, int iCount)
{
    if (iAmmoType < 0 || iCount < 0)
        return;

    int off = GetMarineAmmoOffset(iMarine);
    if (off == -1)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[AVK-36] 设置弹药失败: marine(%d) 没有 m_iAmmo 发送属性 (弹药类型=%d)",
                iMarine, iAmmoType);
        return;
    }

    SetEntProp(iMarine, Prop_Send, "m_iAmmo", iCount, iAmmoType);
    if (GetEntProp(iMarine, Prop_Send, "m_iAmmo", iAmmoType) == iCount)
        return;

    // 读回不一致时按绝对偏移直写 (元素步长 4 字节)
    SetEntData(iMarine, off + iAmmoType * 4, iCount, 4, true);
    if (g_cvDebug.BoolValue && GetEntProp(iMarine, Prop_Send, "m_iAmmo", iAmmoType) != iCount)
        PrintToServer("[AVK-36] 警告: marine %d m_iAmmo[%d] 写入读回不一致 (期望 %d)",
            iMarine, iAmmoType, iCount);
}
