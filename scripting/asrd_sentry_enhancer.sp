/**
 * ============================================================================
 *  Plugin: [AS:RD] Sentry Enhancer + Sentry Hat
 *
 *  描述: 增强 AS:RD 机枪塔属性 + 把机枪塔放角色头顶
 *  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  支持4种机枪塔:
 *    哨戒枪 (asw_sentry_top_machinegun)  — m_nGunType=0
 *    哨戒炮 (asw_sentry_top_cannon)      — m_nGunType=1
 *    喷火型哨戒枪 (asw_sentry_top_flamer) — m_nGunType=2
 *    冷冻型哨戒枪 (asw_sentry_top_freeze) — m_nGunType=3
 *
 *  功能:
 *    - 增加机枪塔生命值
 *    - 增加机枪塔弹药 + 手动装填命令
 *    - 增加机枪塔射程
 *    - 提高机枪塔射速
 *    - 增加机枪塔伤害（DHooks）
 *    - 机枪塔无敌（不消失）
 *    - 机枪塔放头顶
 *
 *  依赖:
 *    SourceMod 1.11+, DHooks (SourceMod 内置)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

// DHooks 可选依赖 — 如果编译环境不支持，伤害倍率功能自动禁用
#tryinclude <dhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Sentry Enhancer + Hat"
#define PLUGIN_VERSION "5.0.0"

#define MAX_ENTITIES  2048
#define SENTRY_BASE_FIRE_RATE 0.1

// ─── CVar 句柄 ──────────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvHealthMult;
ConVar g_cvDamageMult;
ConVar g_cvFireRateMult;
ConVar g_cvRangeMult;
ConVar g_cvAmmoMult;
ConVar g_cvInvulnerable;
ConVar g_cvDebug;

// ─── 增强追踪 ───────────────────────────────────────────
bool  g_bEnhanced[MAX_ENTITIES];
int   g_iOrigMaxHealth[MAX_ENTITIES];
int   g_iOrigAmmo[MAX_ENTITIES];
float g_fOrigShootRange[MAX_ENTITIES];
int   g_iCachedTop[MAX_ENTITIES];

// ─── DHooks ─────────────────────────────────────────────
#if defined _dhooks_included
Handle g_hGetSentryDamage;
bool   g_bDHooksAvailable;
#else
bool   g_bDHooksAvailable = false;
#endif

// ─── 头顶机枪塔追踪 ─────────────────────────────────────
// base ref → marine userid
int   g_iHatMarine[MAX_ENTITIES];
// 是否使用父子绑定模式（AS:RD 中玩家不支持 SetParent，改用 OnGameFrame 追踪）
bool  g_bHatParented[MAX_ENTITIES];

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "AS:RD 机枪塔增强 + 头顶机枪塔",
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
        "启用/禁用机枪塔增强",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvHealthMult = CreateConVar(
        "sm_asrd_sentry_health_mult", "2.0",
        "机枪塔生命值倍率 (1.0=默认, 2.0=双倍)",
        FCVAR_NOTIFY, true, 1.0
    );

    g_cvDamageMult = CreateConVar(
        "sm_asrd_sentry_damage_mult", "2.0",
        "机枪塔伤害倍率 (1.0=默认, 2.0=双倍伤害). 需要 DHooks gamedata",
        FCVAR_NOTIFY, true, 1.0
    );

    g_cvFireRateMult = CreateConVar(
        "sm_asrd_sentry_firerate_mult", "2.0",
        "机枪塔射速倍率 (1.0=默认, 2.0=两倍射速)",
        FCVAR_NOTIFY, true, 1.0
    );

    g_cvRangeMult = CreateConVar(
        "sm_asrd_sentry_range_mult", "1.5",
        "机枪塔射程倍率 (1.0=默认, 1.5=1.5倍射程)",
        FCVAR_NOTIFY, true, 1.0
    );

    g_cvAmmoMult = CreateConVar(
        "sm_asrd_sentry_ammo_mult", "2.0",
        "机枪塔弹药倍率 (1.0=默认, 2.0=双倍弹药)",
        FCVAR_NOTIFY, true, 1.0
    );

    g_cvInvulnerable = CreateConVar(
        "sm_asrd_sentry_invulnerable", "0",
        "机枪塔无敌 (0=正常可被摧毁, 1=不会死亡不会消失)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvDebug = CreateConVar(
        "sm_asrd_sentry_debug", "0",
        "调试模式",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    AutoExecConfig(true, "asrd_sentry_enhancer");

    RegAdminCmd("sm_sentry_refresh", Command_RefreshSentries, ADMFLAG_GENERIC, "重新增强所有机枪塔并补满弹药");
    RegAdminCmd("sm_sentry_status", Command_SentryStatus, ADMFLAG_GENERIC, "查看所有机枪塔状态");
    RegAdminCmd("sm_sentry_dump", Command_SentryDump, ADMFLAG_GENERIC, "转储机枪塔属性（调试）");
    RegAdminCmd("sm_sentryhat", Command_SentryHat, ADMFLAG_GENERIC, "把最近的机枪塔放到自己头顶");
    RegAdminCmd("sm_sentryhat_off", Command_SentryHatOff, ADMFLAG_GENERIC, "取消所有头顶机枪塔");

    SetupDHooks();
    ResetAllTracking();
}

// ============================================================================
//  DHooks 初始化
// ============================================================================
void SetupDHooks()
{
#if defined _dhooks_included
    g_bDHooksAvailable = false;

    // 先检查 gamedata 文件是否存在，避免 LoadGameConfigFile 抛出致命错误
    char sPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sPath, sizeof(sPath), "gamedata/asrd_sentry_enhancer.txt");
    if (!FileExists(sPath))
    {
        PrintToServer("[机枪塔增强] 未找到 gamedata/asrd_sentry_enhancer.txt，伤害倍率不可用");
        PrintToServer("[机枪塔增强] 其他功能（生命/弹药/射程/射速/无敌）正常工作");
        return;
    }

    Handle hGameData = LoadGameConfigFile("asrd_sentry_enhancer");
    if (hGameData == null)
    {
        PrintToServer("[机枪塔增强] 警告: gamedata 加载失败，伤害倍率不可用");
        return;
    }

    int iOffset = GameConfGetOffset(hGameData, "GetSentryDamage");
    if (iOffset == -1)
    {
        PrintToServer("[机枪塔增强] 警告: gamedata 中未找到 GetSentryDamage 偏移");
        delete hGameData;
        return;
    }

    g_hGetSentryDamage = DHookCreate(iOffset, HookType_Entity, ReturnType_Int, ThisPointer_CBaseEntity, OnGetSentryDamage);
    if (g_hGetSentryDamage == null)
    {
        PrintToServer("[机枪塔增强] 警告: DHooks 创建失败");
        delete hGameData;
        return;
    }

    g_bDHooksAvailable = true;
    PrintToServer("[机枪塔增强] DHooks 初始化成功，GetSentryDamage 偏移: %d", iOffset);

    delete hGameData;
#else
    g_bDHooksAvailable = false;
    PrintToServer("[机枪塔增强] DHooks 不可用（编译时未包含），伤害倍率功能禁用");
    PrintToServer("[机枪塔增强] 其他功能（生命/弹药/射程/射速/无敌）正常工作");
#endif
}

// ============================================================================
//  DHooks 回调：修改伤害
// ============================================================================
#if defined _dhooks_included
public MRESReturn OnGetSentryDamage(int pThis, Handle hReturn)
{
    if (!g_cvEnabled.BoolValue)
        return MRES_Ignored;

    float fMult = g_cvDamageMult.FloatValue;
    if (fMult <= 1.0)
        return MRES_Ignored;

    int iOrigDamage = DHookGetReturn(hReturn);
    int iNewDamage = RoundToFloor(float(iOrigDamage) * fMult);
    DHookSetReturn(hReturn, iNewDamage);

    if (g_cvDebug.BoolValue)
    {
        char sClass[64];
        GetEntityClassname(pThis, sClass, sizeof(sClass));
        PrintToServer("[机枪塔] %s GetSentryDamage: %d → %d (x%.1f)", sClass, iOrigDamage, iNewDamage, fMult);
    }

    return MRES_Override;
}
#endif

// ============================================================================
//  实体创建
// ============================================================================
public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnabled.BoolValue)
        return;

    if (entity < 0 || entity >= MAX_ENTITIES)
        return;

    // 钩住所有 top 实体的 GetSentryDamage（4种塔都会被钩住）
    #if defined _dhooks_included
    if (g_bDHooksAvailable && StrContains(classname, "asw_sentry_top") == 0)
    {
        DHookEntity(g_hGetSentryDamage, false, entity);
    }
    #endif

    // 延迟增强 base 实体
    if (StrEqual(classname, "asw_sentry_base"))
    {
        CreateTimer(0.3, Timer_EnhanceSentry, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
    }
}

void ResetAllTracking()
{
    for (int i = 0; i < MAX_ENTITIES; i++)
    {
        g_bEnhanced[i]       = false;
        g_iOrigMaxHealth[i]  = 0;
        g_iOrigAmmo[i]       = 0;
        g_fOrigShootRange[i] = 0.0;
        g_iCachedTop[i]      = -1;
        g_iHatMarine[i]      = 0;
    }
}

public void OnMapStart()
{
    ResetAllTracking();
}

public void OnEntityDestroyed(int entity)
{
    if (entity < 0 || entity >= MAX_ENTITIES)
        return;

    g_bEnhanced[entity]       = false;
    g_iOrigMaxHealth[entity]  = 0;
    g_iOrigAmmo[entity]       = 0;
    g_fOrigShootRange[entity] = 0.0;
    g_iCachedTop[entity]      = -1;
    g_iHatMarine[entity]      = 0;
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
void EnhanceSentry(int iBase, bool bForce)
{
    if (!bForce && g_bEnhanced[iBase])
        return;

    float fHealthMult = g_cvHealthMult.FloatValue;
    float fAmmoMult   = g_cvAmmoMult.FloatValue;
    float fRangeMult  = g_cvRangeMult.FloatValue;

    // ─── 增强生命值 ───
    if (FindDataMapInfo(iBase, "m_iMaxHealth") != -1)
    {
        if (!g_bEnhanced[iBase])
            g_iOrigMaxHealth[iBase] = GetEntProp(iBase, Prop_Data, "m_iMaxHealth");

        int iOrigHealth = g_iOrigMaxHealth[iBase];
        if (iOrigHealth > 0 && fHealthMult != 1.0)
        {
            int iNewHealth = RoundToFloor(float(iOrigHealth) * fHealthMult);
            SetEntProp(iBase, Prop_Data, "m_iMaxHealth", iNewHealth);
            SetEntProp(iBase, Prop_Data, "m_iHealth", iNewHealth);

            if (g_cvDebug.BoolValue)
                PrintToServer("[机枪塔] 生命: %d → %d (x%.1f)", iOrigHealth, iNewHealth, fHealthMult);
        }
    }

    // ─── 增强弹药 ───
    if (FindDataMapInfo(iBase, "m_iAmmo") != -1)
    {
        if (!g_bEnhanced[iBase])
            g_iOrigAmmo[iBase] = GetEntProp(iBase, Prop_Data, "m_iAmmo");

        int iOrigAmmo = g_iOrigAmmo[iBase];
        if (iOrigAmmo > 0 && fAmmoMult != 1.0)
        {
            int iNewAmmo = RoundToFloor(float(iOrigAmmo) * fAmmoMult);
            // 强制刷新时也补满弹药
            SetEntProp(iBase, Prop_Data, "m_iAmmo", iNewAmmo);

            if (g_cvDebug.BoolValue)
                PrintToServer("[机枪塔] 弹药: %d → %d (x%.1f)", iOrigAmmo, iNewAmmo, fAmmoMult);
        }
        else if (bForce && iOrigAmmo > 0)
        {
            // 倍率为1时也补满到原始值 × 倍率
            int iFullAmmo = RoundToFloor(float(iOrigAmmo) * fAmmoMult);
            SetEntProp(iBase, Prop_Data, "m_iAmmo", iFullAmmo);
        }
    }

    // ─── 查找 top 实体并缓存 ───
    int iTop = FindSentryTop(iBase);
    g_iCachedTop[iBase] = iTop;

    // ─── 增强射程 ───
    if (iTop > 0 && FindDataMapInfo(iTop, "m_flShootRange") != -1)
    {
        if (!g_bEnhanced[iBase])
            g_fOrigShootRange[iBase] = GetEntPropFloat(iTop, Prop_Data, "m_flShootRange");

        float fOrigRange = g_fOrigShootRange[iBase];
        if (fOrigRange > 0.0 && fRangeMult != 1.0)
        {
            float fNewRange = fOrigRange * fRangeMult;
            SetEntPropFloat(iTop, Prop_Data, "m_flShootRange", fNewRange);

            if (g_cvDebug.BoolValue)
                PrintToServer("[机枪塔] 射程: %.0f → %.0f (x%.1f)", fOrigRange, fNewRange, fRangeMult);
        }
    }

    g_bEnhanced[iBase] = true;

    // 获取塔类型名称
    char sTypeName[32];
    GetSentryTypeName(iBase, sTypeName, sizeof(sTypeName));

    PrintToServer("[机枪塔增强] #%d [%s] (生命x%.1f 伤害x%.1f%s 射速x%.1f 射程x%.1f 弹药x%.1f 无敌%s)",
        iBase, sTypeName, fHealthMult, g_cvDamageMult.FloatValue,
        g_bDHooksAvailable ? "" : "[不可用]",
        g_cvFireRateMult.FloatValue, fRangeMult, fAmmoMult,
        g_cvInvulnerable.BoolValue ? "开" : "关");
}

// ============================================================================
//  OnGameFrame：射速 + 无敌
// ============================================================================
public void OnGameFrame()
{
    if (!g_cvEnabled.BoolValue)
        return;

    float fFireRateMult = g_cvFireRateMult.FloatValue;
    bool bInvuln = g_cvInvulnerable.BoolValue;
    float fGameTime = GetGameTime();

    for (int i = MaxClients + 1; i < MAX_ENTITIES; i++)
    {
        if (!g_bEnhanced[i])
            continue;

        // ─── 射速操控 ───
        if (fFireRateMult > 1.0)
        {
            int iTop = g_iCachedTop[i];
            if (iTop <= 0 || !IsValidEntity(iTop))
            {
                iTop = FindSentryTop(i);
                g_iCachedTop[i] = iTop;
            }

            if (iTop > 0 && FindDataMapInfo(iTop, "m_fNextFireTime") != -1)
            {
                float fNextFire = GetEntPropFloat(iTop, Prop_Data, "m_fNextFireTime");
                if (fNextFire > fGameTime)
                {
                    float fDesiredInterval = SENTRY_BASE_FIRE_RATE / fFireRateMult;
                    float fCurrentInterval = fNextFire - fGameTime;
                    if (fCurrentInterval > fDesiredInterval)
                    {
                        SetEntPropFloat(iTop, Prop_Data, "m_fNextFireTime", fGameTime + fDesiredInterval);
                    }
                }
            }
        }

        // ─── 无敌：保持生命值不低于1 ───
        if (bInvuln && FindDataMapInfo(i, "m_iHealth") != -1)
        {
            int iHealth = GetEntProp(i, Prop_Data, "m_iHealth");
            if (iHealth <= 0)
            {
                int iMaxHealth = GetEntProp(i, Prop_Data, "m_iMaxHealth");
                if (iMaxHealth > 0)
                {
                    SetEntProp(i, Prop_Data, "m_iHealth", iMaxHealth);

                    if (g_cvDebug.BoolValue)
                        PrintToServer("[机枪塔] #%d 无敌保护：生命恢复 %d/%d", i, iMaxHealth, iMaxHealth);
                }
            }
        }
    }

    // ─── 头顶机枪塔追踪 ───
    for (int i = 0; i < MAX_ENTITIES; i++)
    {
        if (g_iHatMarine[i] == 0)
            continue;

        if (g_bHatParented[i])
            continue;  // SetParent 模式不需要手动追踪

        int iBase = EntRefToEntIndex(i);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
        {
            g_iHatMarine[i] = 0;
            continue;
        }

        int iMarine = GetClientOfUserId(g_iHatMarine[i]);
        if (iMarine <= 0 || !IsClientInGame(iMarine) || !IsPlayerAlive(iMarine))
        {
            // 玩家不在了，取消追踪
            g_iHatMarine[i] = 0;
            SetEntProp(iBase, Prop_Send, "m_CollisionGroup", 0);
            continue;
        }

        // 获取玩家头部位置
        float fEyePos[3];
        GetClientEyePosition(iMarine, fEyePos);
        fEyePos[2] += 15.0;

        float fEyeAngles[3];
        GetClientEyeAngles(iMarine, fEyeAngles);
        fEyeAngles[0] = 0.0;

        // 传送机枪塔到头顶
        TeleportEntity(iBase, fEyePos, fEyeAngles, NULL_VECTOR);
    }
}

// ============================================================================
//  辅助：获取机枪塔类型名称
// ============================================================================
void GetSentryTypeName(int iBase, char[] sName, int iLen)
{
    if (FindDataMapInfo(iBase, "m_nGunType") == -1)
    {
        strcopy(sName, iLen, "未知");
        return;
    }

    int iGunType = GetEntProp(iBase, Prop_Data, "m_nGunType");
    switch (iGunType)
    {
        case 0: strcopy(sName, iLen, "哨戒枪");
        case 1: strcopy(sName, iLen, "哨戒炮");
        case 2: strcopy(sName, iLen, "喷火型");
        case 3: strcopy(sName, iLen, "冷冻型");
        default:
        {
            Format(sName, iLen, "未知(%d)", iGunType);
        }
    }
}

// ============================================================================
//  辅助：通过 base 找 top（支持4种塔）
// ============================================================================
int FindSentryTop(int iBase)
{
    if (!IsValidEntity(iBase))
        return -1;

    // 方法1：通过 m_hSentryTop 句柄
    if (FindDataMapInfo(iBase, "m_hSentryTop") != -1)
    {
        int iTop = GetEntPropEnt(iBase, Prop_Data, "m_hSentryTop");
        if (iTop > 0 && IsValidEntity(iTop))
            return iTop;
    }

    // 方法2：遍历所有 top 实体类名
    // 4种塔的 top 实体类名
    char sTopClasses[][] = {
        "asw_sentry_top",              // 基类
        "asw_sentry_top_machinegun",   // 哨戒枪
        "asw_sentry_top_cannon",       // 哨戒炮
        "asw_sentry_top_flamer",       // 喷火型哨戒枪
        "asw_sentry_top_freeze"        // 冷冻型哨戒枪
    };

    for (int t = 0; t < sizeof(sTopClasses); t++)
    {
        int entity = -1;
        while ((entity = FindEntityByClassname(entity, sTopClasses[t])) != -1)
        {
            if (FindDataMapInfo(entity, "m_hSentryBase") != -1)
            {
                int iMyBase = GetEntPropEnt(entity, Prop_Data, "m_hSentryBase");
                if (iMyBase == iBase)
                    return entity;
            }
        }
    }

    return -1;
}

// ============================================================================
//  命令：把最近的机枪塔放到自己头顶
//  AS:RD 中玩家实体不支持 SetParent，改用 OnGameFrame 每帧追踪位置
// ============================================================================
public Action Command_SentryHat(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "你必须存活才能使用此命令");
        return Plugin_Handled;
    }

    int iBase = FindNearestSentryBase(client);
    if (iBase == -1)
    {
        ReplyToCommand(client, "附近没有找到机枪塔");
        return Plugin_Handled;
    }

    // 关闭碰撞，防止卡住玩家
    SetEntProp(iBase, Prop_Send, "m_CollisionGroup", 2);

    // 记录追踪信息，OnGameFrame 中会每帧更新位置
    int ref = EntIndexToEntRef(iBase);
    if (ref >= 0 && ref < MAX_ENTITIES)
    {
        g_iHatMarine[ref] = GetClientUserId(client);
        g_bHatParented[ref] = false;  // 不用 SetParent，用 OnGameFrame 追踪
    }

    // 立即传送到头顶
    float fEyePos[3];
    GetClientEyePosition(client, fEyePos);
    fEyePos[2] += 15.0;

    float fEyeAngles[3];
    GetClientEyeAngles(client, fEyeAngles);
    fEyeAngles[0] = 0.0;

    TeleportEntity(iBase, fEyePos, fEyeAngles, NULL_VECTOR);

    char sTypeName[32];
    GetSentryTypeName(iBase, sTypeName, sizeof(sTypeName));
    ReplyToCommand(client, "已把[%s]放到你头顶", sTypeName);
    return Plugin_Handled;
}

// ============================================================================
//  命令：取消头顶机枪塔
// ============================================================================
public Action Command_SentryHatOff(int client, int args)
{
    int iCount = 0;

    for (int i = 0; i < MAX_ENTITIES; i++)
    {
        if (g_iHatMarine[i] == 0)
            continue;

        int iBase = EntRefToEntIndex(i);
        if (iBase != INVALID_ENT_REFERENCE && IsValidEntity(iBase))
        {
            SetEntProp(iBase, Prop_Send, "m_CollisionGroup", 0);
        }

        g_iHatMarine[i] = 0;
        g_bHatParented[i] = false;
        iCount++;
    }

    ReplyToCommand(client, "已取消 %d 个头顶机枪塔", iCount);
    return Plugin_Handled;
}

// ============================================================================
//  命令：重新增强所有机枪塔
// ============================================================================
public Action Command_RefreshSentries(int client, int args)
{
    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "机枪塔增强功能已禁用");
        return Plugin_Handled;
    }

    int count = 0;
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_sentry_base")) != -1)
    {
        EnhanceSentry(entity, true);
        count++;
    }

    ReplyToCommand(client, "已重新增强 %d 个机枪塔", count);
    return Plugin_Handled;
}

// ============================================================================
//  命令：查看所有机枪塔状态
// ============================================================================
public Action Command_SentryStatus(int client, int args)
{
    PrintToConsole(client, "========== 机枪塔状态 (v%s) ==========", PLUGIN_VERSION);
    PrintToConsole(client, "倍率: 生命x%.1f | 伤害x%.1f%s | 射速x%.1f | 射程x%.1f | 弹药x%.1f | 无敌%s",
        g_cvHealthMult.FloatValue, g_cvDamageMult.FloatValue,
        g_bDHooksAvailable ? "" : "[不可用]",
        g_cvFireRateMult.FloatValue, g_cvRangeMult.FloatValue, g_cvAmmoMult.FloatValue,
        g_cvInvulnerable.BoolValue ? "开" : "关");
    PrintToConsole(client, "------------------------------");

    int count = 0;
    int entity = -1;

    while ((entity = FindEntityByClassname(entity, "asw_sentry_base")) != -1)
    {
        count++;

        int iHealth = GetEntProp(entity, Prop_Data, "m_iHealth");
        int iMaxHealth = GetEntProp(entity, Prop_Data, "m_iMaxHealth");
        int iAmmo = GetEntProp(entity, Prop_Data, "m_iAmmo");

        char sTypeName[32];
        GetSentryTypeName(entity, sTypeName, sizeof(sTypeName));

        PrintToConsole(client, "[base #%d] [%s] 生命: %d/%d | 弹药: %d | 已增强: %s | 头顶: %s",
            entity, sTypeName, iHealth, iMaxHealth, iAmmo,
            g_bEnhanced[entity] ? "是" : "否",
            (entity < MAX_ENTITIES && g_iHatMarine[EntIndexToEntRef(entity)] != 0) ? "是" : "否");

        int iTop = FindSentryTop(entity);
        if (iTop > 0)
        {
            char sTopClass[64];
            GetEntityClassname(iTop, sTopClass, sizeof(sTopClass));
            float fShootRange = GetEntPropFloat(iTop, Prop_Data, "m_flShootRange");
            PrintToConsole(client, "  [top #%d %s] 射程: %.0f",
                iTop, sTopClass, fShootRange);
        }
        else
        {
            PrintToConsole(client, "  [top] 未找到!");
        }
    }

    if (count == 0)
        PrintToConsole(client, "当前没有机枪塔");

    PrintToConsole(client, "==============================");
    return Plugin_Handled;
}

// ============================================================================
//  命令：转储属性（调试）
// ============================================================================
public Action Command_SentryDump(int client, int args)
{
    int entity = -1;
    int count = 0;

    while ((entity = FindEntityByClassname(entity, "asw_sentry_base")) != -1)
    {
        count++;

        char sTypeName[32];
        GetSentryTypeName(entity, sTypeName, sizeof(sTypeName));

        PrintToConsole(client, "====== base #%d [%s] ======", entity, sTypeName);
        PrintToConsole(client, "  m_iMaxHealth: %d (值:%d)", FindDataMapInfo(entity, "m_iMaxHealth"), GetEntProp(entity, Prop_Data, "m_iMaxHealth"));
        PrintToConsole(client, "  m_iHealth: %d (值:%d)", FindDataMapInfo(entity, "m_iHealth"), GetEntProp(entity, Prop_Data, "m_iHealth"));
        PrintToConsole(client, "  m_iAmmo: %d (值:%d)", FindDataMapInfo(entity, "m_iAmmo"), GetEntProp(entity, Prop_Data, "m_iAmmo"));
        PrintToConsole(client, "  m_nGunType: %d (值:%d)", FindDataMapInfo(entity, "m_nGunType"), GetEntProp(entity, Prop_Data, "m_nGunType"));
        PrintToConsole(client, "  m_hSentryTop: %d", FindDataMapInfo(entity, "m_hSentryTop"));

        int iTop = FindSentryTop(entity);
        if (iTop > 0)
        {
            char sTopClass[64];
            GetEntityClassname(iTop, sTopClass, sizeof(sTopClass));
            PrintToConsole(client, "====== top #%d (%s) ======", iTop, sTopClass);
            PrintToConsole(client, "  m_flShootRange: %d (值:%.0f)", FindDataMapInfo(iTop, "m_flShootRange"), GetEntPropFloat(iTop, Prop_Data, "m_flShootRange"));
            PrintToConsole(client, "  m_fNextFireTime: %d (值:%.2f)", FindDataMapInfo(iTop, "m_fNextFireTime"), GetEntPropFloat(iTop, Prop_Data, "m_fNextFireTime"));
        }
    }

    if (count == 0)
        PrintToConsole(client, "当前没有机枪塔");

    ReplyToCommand(client, "已转储 %d 个机枪塔属性到控制台", count);
    return Plugin_Handled;
}

// ============================================================================
//  辅助：找最近的 base 实体
// ============================================================================
int FindNearestSentryBase(int iClient)
{
    float fClientPos[3];
    GetClientAbsOrigin(iClient, fClientPos);

    int iBest = -1;
    float fBestDist = 999999.0;

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_sentry_base")) != -1)
    {
        float fSentryPos[3];
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", fSentryPos);

        float fDist = GetVectorDistance(fClientPos, fSentryPos);
        if (fDist < fBestDist)
        {
            fBestDist = fDist;
            iBest = entity;
        }
    }

    return iBest;
}
