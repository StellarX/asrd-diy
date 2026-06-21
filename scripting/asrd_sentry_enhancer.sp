/**
 * ============================================================================
 *  Plugin: [AS:RD] Sentry Enhancer
 *
 *  描述: 增强 Alien Swarm: Reactive Drop 中机枪塔的威力
 *  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  功能:
 *    - 增加机枪塔生命值
 *    - 增加机枪塔伤害
 *    - 提高机枪塔射速
 *    - 增加机枪塔射程
 *    - 所有参数可通过 CVar 实时调整
 *    - 支持所有机枪塔类型（机枪/火焰/冰冻/炮台）
 *    - 修改 CVar 后可用 sm_sentry_refresh 刷新已放置的塔
 *
 *  安装:
 *    将编译后的 .smx 放入 addons/sourcemod/plugins/
 *
 *  依赖:
 *    SourceMod 1.11+ (无需 SDKHooks)
 * ============================================================================
 */

#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Sentry Enhancer"
#define PLUGIN_VERSION "1.0.0"

#define MIN_FIRE_RATE 0.05  // 最低射速间隔（秒），防止过快导致异常
#define MAX_ENTITIES  2048

// ─── CVar 句柄 ──────────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvHealthMult;
ConVar g_cvDamageMult;
ConVar g_cvFireRateMult;
ConVar g_cvRangeMult;
ConVar g_cvDebug;

// ─── 追踪已增强的机枪塔 ─────────────────────────────────
bool  g_bEnhanced[MAX_ENTITIES];

// ─── 存储原始属性值（用于刷新时正确计算） ───────────────
int   g_iOrigMaxHealth[MAX_ENTITIES];
int   g_iOrigDamage[MAX_ENTITIES];
float g_fOrigFireRate[MAX_ENTITIES];
float g_fOrigRange[MAX_ENTITIES];

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "增强 AS:RD 机枪塔威力（生命/伤害/射速/射程）",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件加载
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_sentry_enabled", "1",
        "启用/禁用机枪塔增强 (0=禁用, 1=启用)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvHealthMult = CreateConVar(
        "sm_asrd_sentry_health_mult", "2.0",
        "机枪塔生命值倍率 (1.0=默认, 2.0=双倍生命)",
        FCVAR_NOTIFY, true, 1.0
    );

    g_cvDamageMult = CreateConVar(
        "sm_asrd_sentry_damage_mult", "2.0",
        "机枪塔伤害倍率 (1.0=默认, 2.0=双倍伤害)",
        FCVAR_NOTIFY, true, 1.0
    );

    g_cvFireRateMult = CreateConVar(
        "sm_asrd_sentry_firerate_mult", "1.5",
        "机枪塔射速倍率 (1.0=默认, 2.0=两倍射速, 数值越高射速越快)",
        FCVAR_NOTIFY, true, 1.0
    );

    g_cvRangeMult = CreateConVar(
        "sm_asrd_sentry_range_mult", "1.5",
        "机枪塔射程倍率 (1.0=默认, 1.5=1.5倍射程)",
        FCVAR_NOTIFY, true, 1.0
    );

    g_cvDebug = CreateConVar(
        "sm_asrd_sentry_debug", "0",
        "调试模式，输出详细增强信息",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    AutoExecConfig(true, "asrd_sentry_enhancer");

    RegAdminCmd("sm_sentry_refresh", Command_RefreshSentries, ADMFLAG_GENERIC, "重新增强所有已放置的机枪塔");
    RegAdminCmd("sm_sentry_status", Command_SentryStatus, ADMFLAG_GENERIC, "查看所有机枪塔状态");

    ResetAllTracking();
}

// ============================================================================
//  重置追踪数据
// ============================================================================
void ResetAllTracking()
{
    for (int i = 0; i < MAX_ENTITIES; i++)
    {
        g_bEnhanced[i]      = false;
        g_iOrigMaxHealth[i] = 0;
        g_iOrigDamage[i]    = 0;
        g_fOrigFireRate[i]  = 0.0;
        g_fOrigRange[i]     = 0.0;
    }
}

public void OnMapStart()
{
    ResetAllTracking();
}

// ============================================================================
//  实体创建/销毁
// ============================================================================
public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnabled.BoolValue)
        return;

    if (entity < 0 || entity >= MAX_ENTITIES)
        return;

    if (StrContains(classname, "asw_sentry") == -1)
        return;

    // 延迟修改，等待实体完全初始化
    CreateTimer(0.1, Timer_EnhanceSentry, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
}

public void OnEntityDestroyed(int entity)
{
    if (entity < 0 || entity >= MAX_ENTITIES)
        return;

    g_bEnhanced[entity]      = false;
    g_iOrigMaxHealth[entity] = 0;
    g_iOrigDamage[entity]    = 0;
    g_fOrigFireRate[entity]  = 0.0;
    g_fOrigRange[entity]     = 0.0;
}

// ============================================================================
//  延迟增强定时器
// ============================================================================
public Action Timer_EnhanceSentry(Handle timer, int ref)
{
    int entity = EntRefToEntIndex(ref);

    if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity))
        return Plugin_Stop;

    EnhanceSentry(entity, false);

    return Plugin_Stop;
}

// ============================================================================
//  核心：增强机枪塔
// ============================================================================
void EnhanceSentry(int entity, bool bForce)
{
    // 非强制模式下，已增强的跳过
    if (!bForce && g_bEnhanced[entity])
        return;

    float fHealthMult   = g_cvHealthMult.FloatValue;
    float fDamageMult   = g_cvDamageMult.FloatValue;
    float fFireRateMult = g_cvFireRateMult.FloatValue;
    float fRangeMult    = g_cvRangeMult.FloatValue;

    char sClassname[64];
    GetEntityClassname(entity, sClassname, sizeof(sClassname));

    // ─── 增强生命值 ───
    if (FindDataMapInfo(entity, "m_iMaxHealth") != -1)
    {
        if (!g_bEnhanced[entity])
        {
            // 首次增强：读取并存储原始值
            g_iOrigMaxHealth[entity] = GetEntProp(entity, Prop_Data, "m_iMaxHealth");
        }

        int iOrigHealth = g_iOrigMaxHealth[entity];
        if (iOrigHealth > 0 && fHealthMult != 1.0)
        {
            int iNewHealth = RoundToFloor(float(iOrigHealth) * fHealthMult);
            SetEntProp(entity, Prop_Data, "m_iMaxHealth", iNewHealth);
            SetEntProp(entity, Prop_Data, "m_iHealth", iNewHealth);

            if (g_cvDebug.BoolValue)
                PrintToServer("[机枪塔增强] %s 生命: %d → %d (x%.1f)", sClassname, iOrigHealth, iNewHealth, fHealthMult);
        }
    }

    // ─── 增强伤害 ───
    if (FindDataMapInfo(entity, "m_iDamage") != -1)
    {
        if (!g_bEnhanced[entity])
        {
            g_iOrigDamage[entity] = GetEntProp(entity, Prop_Data, "m_iDamage");
        }

        int iOrigDamage = g_iOrigDamage[entity];
        if (iOrigDamage > 0 && fDamageMult != 1.0)
        {
            int iNewDamage = RoundToFloor(float(iOrigDamage) * fDamageMult);
            SetEntProp(entity, Prop_Data, "m_iDamage", iNewDamage);

            if (g_cvDebug.BoolValue)
                PrintToServer("[机枪塔增强] %s 伤害: %d → %d (x%.1f)", sClassname, iOrigDamage, iNewDamage, fDamageMult);
        }
    }

    // ─── 增强射速 ───
    if (FindDataMapInfo(entity, "m_fFireRate") != -1)
    {
        if (!g_bEnhanced[entity])
        {
            g_fOrigFireRate[entity] = GetEntPropFloat(entity, Prop_Data, "m_fFireRate");
        }

        float fOrigFireRate = g_fOrigFireRate[entity];
        if (fOrigFireRate > 0.0 && fFireRateMult != 1.0)
        {
            // 射速倍率：数值越大射击越快，因此用原始值除以倍率
            float fNewFireRate = fOrigFireRate / fFireRateMult;
            if (fNewFireRate < MIN_FIRE_RATE)
                fNewFireRate = MIN_FIRE_RATE;

            SetEntPropFloat(entity, Prop_Data, "m_fFireRate", fNewFireRate);

            if (g_cvDebug.BoolValue)
                PrintToServer("[机枪塔增强] %s 射速间隔: %.3f → %.3f (x%.1f)", sClassname, fOrigFireRate, fNewFireRate, fFireRateMult);
        }
    }

    // ─── 增强射程 ───
    if (FindDataMapInfo(entity, "m_fRange") != -1)
    {
        if (!g_bEnhanced[entity])
        {
            g_fOrigRange[entity] = GetEntPropFloat(entity, Prop_Data, "m_fRange");
        }

        float fOrigRange = g_fOrigRange[entity];
        if (fOrigRange > 0.0 && fRangeMult != 1.0)
        {
            float fNewRange = fOrigRange * fRangeMult;
            SetEntPropFloat(entity, Prop_Data, "m_fRange", fNewRange);

            if (g_cvDebug.BoolValue)
                PrintToServer("[机枪塔增强] %s 射程: %.1f → %.1f (x%.1f)", sClassname, fOrigRange, fNewRange, fRangeMult);
        }
    }

    g_bEnhanced[entity] = true;

    PrintToServer("[机枪塔增强] 已增强 %s (生命x%.1f 伤害x%.1f 射速x%.1f 射程x%.1f)",
        sClassname, fHealthMult, fDamageMult, fFireRateMult, fRangeMult);
}

// ============================================================================
//  管理命令：重新增强所有机枪塔
// ============================================================================
public Action Command_RefreshSentries(int client, int args)
{
    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "机枪塔增强功能已禁用");
        return Plugin_Handled;
    }

    int count = 0;
    char sClassname[64];

    for (int i = MaxClients + 1; i < MAX_ENTITIES; i++)
    {
        if (!IsValidEntity(i))
            continue;

        GetEntityClassname(i, sClassname, sizeof(sClassname));

        if (StrContains(sClassname, "asw_sentry") == -1)
            continue;

        // 强制刷新：使用存储的原始值 + 当前 CVar 重新计算
        EnhanceSentry(i, true);
        count++;
    }

    ReplyToCommand(client, "已重新增强 %d 个机枪塔", count);
    return Plugin_Handled;
}

// ============================================================================
//  管理命令：查看机枪塔状态
// ============================================================================
public Action Command_SentryStatus(int client, int args)
{
    char sClassname[64];
    int count = 0;

    PrintToConsole(client, "========== 机枪塔状态 (v%s) ==========", PLUGIN_VERSION);
    PrintToConsole(client, "增强倍率: 生命x%.1f 伤害x%.1f 射速x%.1f 射程x%.1f",
        g_cvHealthMult.FloatValue, g_cvDamageMult.FloatValue,
        g_cvFireRateMult.FloatValue, g_cvRangeMult.FloatValue);
    PrintToConsole(client, "------------------------------");

    for (int i = MaxClients + 1; i < MAX_ENTITIES; i++)
    {
        if (!IsValidEntity(i))
            continue;

        GetEntityClassname(i, sClassname, sizeof(sClassname));

        if (StrContains(sClassname, "asw_sentry") == -1)
            continue;

        count++;

        int iHealth = -1, iMaxHealth = -1, iDamage = -1;
        float fFireRate = -1.0, fRange = -1.0;

        if (FindDataMapInfo(i, "m_iHealth") != -1)
            iHealth = GetEntProp(i, Prop_Data, "m_iHealth");
        if (FindDataMapInfo(i, "m_iMaxHealth") != -1)
            iMaxHealth = GetEntProp(i, Prop_Data, "m_iMaxHealth");
        if (FindDataMapInfo(i, "m_iDamage") != -1)
            iDamage = GetEntProp(i, Prop_Data, "m_iDamage");
        if (FindDataMapInfo(i, "m_fFireRate") != -1)
            fFireRate = GetEntPropFloat(i, Prop_Data, "m_fFireRate");
        if (FindDataMapInfo(i, "m_fRange") != -1)
            fRange = GetEntPropFloat(i, Prop_Data, "m_fRange");

        PrintToConsole(client, "[%s] #%d | 生命: %d/%d | 伤害: %d | 射速: %.3f | 射程: %.1f | 已增强: %s",
            sClassname, i, iHealth, iMaxHealth, iDamage, fFireRate, fRange,
            g_bEnhanced[i] ? "是" : "否");
    }

    if (count == 0)
        PrintToConsole(client, "当前没有机枪塔");

    PrintToConsole(client, "==============================");

    return Plugin_Handled;
}
