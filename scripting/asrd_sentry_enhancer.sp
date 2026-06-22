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
 *    - 机枪塔无敌（不消失）
 *    - 机枪塔放头顶
 *
 *  依赖:
 *    SourceMod 1.11+
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Sentry Enhancer + Hat"
#define PLUGIN_VERSION "5.0.0"

#define MAX_ENTITIES  2048
#define SENTRY_BASE_FIRE_RATE 0.1

// ─── CVar 句柄 ──────────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvHealthMult;
ConVar g_cvFireRateMult;
ConVar g_cvRangeMult;
ConVar g_cvAmmoMult;
ConVar g_cvInvulnerable;
ConVar g_cvHatTurnSpeed;
ConVar g_cvHatPublic;
ConVar g_cvDebug;

// ─── 增强追踪 ───────────────────────────────────────────
bool  g_bEnhanced[MAX_ENTITIES];
int   g_iOrigMaxHealth[MAX_ENTITIES];
int   g_iOrigAmmo[MAX_ENTITIES];
float g_fOrigShootRange[MAX_ENTITIES];
int   g_iCachedTop[MAX_ENTITIES];

// ─── 头顶机枪塔追踪 ─────────────────────────────────────
// base ref → marine userid
int   g_iHatMarine[MAX_ENTITIES];
// 是否使用父子绑定模式（AS:RD 中玩家不支持 SetParent，改用 OnGameFrame 追踪）
bool  g_bHatParented[MAX_ENTITIES];
// 缓存 marine 实体索引（避免每帧遍历）
int   g_iHatMarineEnt[MAX_ENTITIES];
// 每个塔的额外 Yaw 偏移（度）
float g_fHatYawOffset[MAX_ENTITIES];

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

    g_cvHatTurnSpeed = CreateConVar(
        "sm_asrd_sentry_hat_turnspeed", "360.0",
        "头顶机枪塔转向速度 (度/秒, 0=瞬间转向, 360=1秒转1圈)",
        FCVAR_NOTIFY, true, 0.0
    );

    g_cvHatPublic = CreateConVar(
        "sm_asrd_sentry_hat_public", "0",
        "允许所有玩家使用头顶机枪塔命令 (0=仅管理员, 1=所有玩家)",
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
    RegAdminCmd("sm_sentry_dump_player", Command_DumpPlayer, ADMFLAG_GENERIC, "转储玩家实体属性（调试）");
    RegAdminCmd("sm_sentryhat", Command_SentryHat, ADMFLAG_GENERIC, "把最近的机枪塔放到自己头顶");
    RegAdminCmd("sm_sentryhat_off", Command_SentryHatOff, ADMFLAG_GENERIC, "取消所有头顶机枪塔");
    RegConsoleCmd("sm_hat", Command_HatPublic, "把最近的机枪塔放到自己头顶 (需管理员开启)");
    RegConsoleCmd("sm_hat_off", Command_HatOffPublic, "取消自己的头顶机枪塔 (需管理员开启)");

    ResetAllTracking();
}

// ============================================================================
//  实体创建
// ============================================================================
public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnabled.BoolValue)
        return;

    if (entity < 0 || entity >= MAX_ENTITIES)
        return;

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
        g_iHatMarineEnt[i]   = -1;
        g_fHatYawOffset[i]   = 0.0;
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
    g_iHatMarineEnt[entity]   = -1;
    g_fHatYawOffset[entity]   = 0.0;
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

    PrintToServer("[机枪塔增强] #%d [%s] (生命x%.1f 射速x%.1f 射程x%.1f 弹药x%.1f 无敌%s)",
        iBase, sTypeName, fHealthMult,
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
    for (int i = MaxClients + 1; i < MAX_ENTITIES; i++)
    {
        if (g_iHatMarine[i] == 0)
            continue;

        if (g_bHatParented[i])
            continue;

        int iBase = i;
        if (!IsValidEntity(iBase))
        {
            g_iHatMarine[i] = 0;
            g_iHatMarineEnt[i] = -1;
            g_fHatYawOffset[i] = 0.0;
            continue;
        }

        int iClient = GetClientOfUserId(g_iHatMarine[i]);
        if (iClient <= 0 || !IsClientInGame(iClient))
        {
            g_iHatMarine[i] = 0;
            g_iHatMarineEnt[i] = -1;
            g_fHatYawOffset[i] = 0.0;
            SetEntProp(iBase, Prop_Send, "m_CollisionGroup", 0);
            continue;
        }

        // 使用缓存的 marine 实体，如果无效则重新查找
        int iMarine = g_iHatMarineEnt[i];
        if (iMarine <= 0 || !IsValidEntity(iMarine))
        {
            iMarine = GetPlayerMarine(iClient);
            g_iHatMarineEnt[i] = iMarine;
        }

        if (iMarine <= 0 || !IsValidEntity(iMarine))
        {
            // marine 不存在（可能还没部署），跳过本帧
            continue;
        }

        // 检查 marine 是否存活
        if (FindDataMapInfo(iMarine, "m_iHealth") != -1 && GetEntProp(iMarine, Prop_Data, "m_iHealth") <= 0)
        {
            // marine 死亡，取消追踪
            g_iHatMarine[i] = 0;
            g_iHatMarineEnt[i] = -1;
            g_fHatYawOffset[i] = 0.0;
            SetEntProp(iBase, Prop_Send, "m_CollisionGroup", 0);
            continue;
        }

        // 获取 marine 头部位置和朝向
        float fOrigin[3], fAngles[3];
        GetEntPropVector(iMarine, Prop_Data, "m_vecOrigin", fOrigin);
        fOrigin[2] += 80.0;  // 基础高度80

        // 有角度偏移的塔放更高，避免重叠（塔整体约60-70单位高）
        if (g_fHatYawOffset[i] != 0.0)
            fOrigin[2] += 70.0;

        // 获取玩家视角（用于计算朝向）
        float fEyeAngles[3];
        GetClientEyeAngles(iClient, fEyeAngles);

        // 获取 marine 朝向
        GetEntPropVector(iMarine, Prop_Data, "m_angRotation", fAngles);

        // 计算目标朝向：玩家视角 + 180度
        float fTargetYaw = fEyeAngles[1] + 180.0 + g_fHatYawOffset[i];

        // 转向速度控制
        float fTurnSpeed = g_cvHatTurnSpeed.FloatValue;
        if (fTurnSpeed <= 0.0)
        {
            // 瞬间转向
            fAngles[1] = fTargetYaw;
        }
        else
        {
            // 平滑转向：计算角度差，限制每帧最大转角
            float fDelta = fTargetYaw - fAngles[1];
            // 归一化到 -180 ~ 180
            while (fDelta > 180.0) fDelta -= 360.0;
            while (fDelta < -180.0) fDelta += 360.0;

            float fMaxTurn = fTurnSpeed * GetTickInterval();
            if (fDelta > fMaxTurn)
                fDelta = fMaxTurn;
            else if (fDelta < -fMaxTurn)
                fDelta = -fMaxTurn;

            fAngles[1] += fDelta;
        }

        fAngles[0] = 0.0;  // 不俯仰

        // 传送机枪塔到头顶并跟随朝向
        TeleportEntity(iBase, fOrigin, fAngles, NULL_VECTOR);
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

    // 可选参数：额外 Yaw 偏移角度（如 180 = 反向）
    float fYawOffset = 0.0;
    if (args >= 1)
    {
        char sArg[16];
        GetCmdArg(1, sArg, sizeof(sArg));
        fYawOffset = StringToFloat(sArg);
    }

    int iBase = FindNearestSentryBase(client);
    if (iBase == -1)
    {
        ReplyToCommand(client, "附近没有找到机枪塔");
        return Plugin_Handled;
    }

    // 关闭碰撞，防止卡住玩家和塔之间互相阻挡
    // 碰撞组 1 = debris (不与玩家/塔碰撞)
    SetEntProp(iBase, Prop_Send, "m_CollisionGroup", 1);
    // 同时关闭 top 实体的碰撞
    int iTop = FindSentryTop(iBase);
    if (iTop > 0)
        SetEntProp(iTop, Prop_Send, "m_CollisionGroup", 1);

    // 尝试 SetParent 绑定到 marine 实体
    int iMarine = GetPlayerMarine(client);
    bool bParented = false;

    if (iMarine > 0 && IsValidEntity(iMarine))
    {
        // 给 marine 设目标名
        char sParentName[64];
        Format(sParentName, sizeof(sParentName), "marine_ent_%d", iMarine);
        DispatchKeyValue(iMarine, "targetname", sParentName);

        // 尝试绑定
        SetVariantString(sParentName);
        bParented = AcceptEntityInput(iBase, "SetParent");
    }

    // 记录追踪信息（用实体索引做数组下标）
    if (iBase >= 0 && iBase < MAX_ENTITIES)
    {
        g_iHatMarine[iBase] = GetClientUserId(client);
        g_bHatParented[iBase] = bParented;
        g_iHatMarineEnt[iBase] = iMarine;
        g_fHatYawOffset[iBase] = fYawOffset;
    }

    // 初始传送到目标位置
    if (iMarine > 0 && IsValidEntity(iMarine))
    {
        float fOrigin[3], fAngles[3];
        GetEntPropVector(iMarine, Prop_Data, "m_vecOrigin", fOrigin);
        fOrigin[2] += 80.0;
        GetEntPropVector(iMarine, Prop_Data, "m_angRotation", fAngles);
        fAngles[0] = 0.0;
        TeleportEntity(iBase, fOrigin, fAngles, NULL_VECTOR);
    }
    else
    {
        // marine 找不到，回退到玩家眼睛位置
        float fEyePos[3], fEyeAngles[3];
        GetClientEyePosition(client, fEyePos);
        fEyePos[2] += 15.0;
        GetClientEyeAngles(client, fEyeAngles);
        fEyeAngles[0] = 0.0;
        TeleportEntity(iBase, fEyePos, fEyeAngles, NULL_VECTOR);
    }

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

    for (int i = MaxClients + 1; i < MAX_ENTITIES; i++)
    {
        if (g_iHatMarine[i] == 0)
            continue;

        if (IsValidEntity(i))
        {
            if (g_bHatParented[i])
                AcceptEntityInput(i, "ClearParent");
            SetEntProp(i, Prop_Send, "m_CollisionGroup", 0);
        }

        g_iHatMarine[i] = 0;
        g_bHatParented[i] = false;
        g_iHatMarineEnt[i] = -1;
        g_fHatYawOffset[i] = 0.0;
        iCount++;
    }

    ReplyToCommand(client, "已取消 %d 个头顶机枪塔", iCount);
    return Plugin_Handled;
}

// ============================================================================
//  公共命令：玩家头顶机枪塔（需管理员开启 sm_asrd_sentry_hat_public）
// ============================================================================
public Action Command_HatPublic(int client, int args)
{
    if (!g_cvHatPublic.BoolValue)
    {
        ReplyToCommand(client, "头顶机枪塔功能未对玩家开放");
        return Plugin_Handled;
    }
    return Command_SentryHat(client, args);
}

public Action Command_HatOffPublic(int client, int args)
{
    if (!g_cvHatPublic.BoolValue)
    {
        ReplyToCommand(client, "头顶机枪塔功能未对玩家开放");
        return Plugin_Handled;
    }

    // 普通玩家只能取消自己的头顶机枪塔
    int iCount = 0;
    int iUserID = GetClientUserId(client);

    for (int i = MaxClients + 1; i < MAX_ENTITIES; i++)
    {
        if (g_iHatMarine[i] != iUserID)
            continue;

        if (IsValidEntity(i))
        {
            if (g_bHatParented[i])
                AcceptEntityInput(i, "ClearParent");
            SetEntProp(i, Prop_Send, "m_CollisionGroup", 0);
        }

        g_iHatMarine[i] = 0;
        g_bHatParented[i] = false;
        g_iHatMarineEnt[i] = -1;
        g_fHatYawOffset[i] = 0.0;
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
    PrintToConsole(client, "倍率: 生命x%.1f | 射速x%.1f | 射程x%.1f | 弹药x%.1f | 无敌%s",
        g_cvHealthMult.FloatValue,
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
            (entity < MAX_ENTITIES && g_iHatMarine[entity] != 0) ? "是" : "否");

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
        // 跳过已经在头顶的塔
        if (entity >= 0 && entity < MAX_ENTITIES && g_iHatMarine[entity] != 0)
            continue;

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

// ============================================================================
//  辅助：获取玩家控制的 marine 实体
//  AS:RD 中有多种方式获取玩家控制的 marine NPC：
//    1. 玩家实体的 m_hInhabiting 属性 (asw_player.h)
//    2. asw_game_resource 实体的 m_hMarine0~7 数组
//    3. 遍历 asw_marine 实体匹配 m_hCommander
// ============================================================================
int GetPlayerMarine(int iClient)
{
    int iMarine = -1;

    // ─── 方法1: 玩家实体的 m_hInhabiting ───
    // 来源: asw_player.h → CNetworkHandle( CASW_Inhabitable_NPC, m_hInhabiting )
    if (FindDataMapInfo(iClient, "m_hInhabiting") != -1)
    {
        iMarine = GetEntPropEnt(iClient, Prop_Data, "m_hInhabiting");
        if (g_cvDebug.BoolValue)
            PrintToServer("[机枪塔] m_hInhabiting (Prop_Data): %d", iMarine);
    }

    if (iMarine <= 0 || !IsValidEntity(iMarine))
    {
        char sNetClass[64];
        if (GetEntityNetClass(iClient, sNetClass, sizeof(sNetClass)))
        {
            if (FindSendPropInfo(sNetClass, "m_hInhabiting") != -1)
            {
                iMarine = GetEntPropEnt(iClient, Prop_Send, "m_hInhabiting");
                if (g_cvDebug.BoolValue)
                    PrintToServer("[机枪塔] m_hInhabiting (Prop_Send, netclass=%s): %d", sNetClass, iMarine);
            }
        }
    }

    if (iMarine > 0 && IsValidEntity(iMarine))
    {
        if (g_cvDebug.BoolValue)
        {
            char sMarineClass[64];
            GetEntityClassname(iMarine, sMarineClass, sizeof(sMarineClass));
            PrintToServer("[机枪塔] 方法1成功: 找到 inhabiting NPC #%d (%s)", iMarine, sMarineClass);
        }
        return iMarine;
    }

    // ─── 方法2: 通过 asw_game_resource 获取 ───
    // asw_game_resource 有 m_hMarine0~7 属性，按玩家索引存储 marine 句柄
    int iGR = FindEntityByClassname(-1, "asw_game_resource");
    if (iGR > 0 && IsValidEntity(iGR))
    {
        // 玩家索引从1开始，但数组从0开始
        char sPropName[32];
        for (int i = 0; i < 8; i++)
        {
            Format(sPropName, sizeof(sPropName), "m_hMarine%d", i);

            int iDataOff = FindDataMapInfo(iGR, sPropName);
            int iSendOff = -1;
            char sGRNetClass[64];
            GetEntityNetClass(iGR, sGRNetClass, sizeof(sGRNetClass));
            if (sGRNetClass[0] != '\0')
                iSendOff = FindSendPropInfo(sGRNetClass, sPropName);

            if (iDataOff != -1 || iSendOff != -1)
            {
                int iMarineEnt = -1;
                if (iSendOff != -1)
                    iMarineEnt = GetEntPropEnt(iGR, Prop_Send, sPropName);
                else
                    iMarineEnt = GetEntPropEnt(iGR, Prop_Data, sPropName);

                if (iMarineEnt > 0 && IsValidEntity(iMarineEnt))
                {
                    // 检查这个 marine 的 commander 是否是当前玩家
                    int iCommander = -1;
                    if (FindDataMapInfo(iMarineEnt, "m_hCommander") != -1)
                        iCommander = GetEntPropEnt(iMarineEnt, Prop_Data, "m_hCommander");

                    char sMarineNetClass[64];
                    GetEntityNetClass(iMarineEnt, sMarineNetClass, sizeof(sMarineNetClass));
                    if (sMarineNetClass[0] != '\0' && FindSendPropInfo(sMarineNetClass, "m_hCommander") != -1)
                        iCommander = GetEntPropEnt(iMarineEnt, Prop_Send, "m_hCommander");

                    if (iCommander == iClient)
                    {
                        if (g_cvDebug.BoolValue)
                        {
                            char sMarineClass[64];
                            GetEntityClassname(iMarineEnt, sMarineClass, sizeof(sMarineClass));
                            PrintToServer("[机枪塔] 方法2成功: 通过 asw_game_resource[%d] 找到 marine #%d (%s)", i, iMarineEnt, sMarineClass);
                        }
                        return iMarineEnt;
                    }
                }
            }
        }
    }

    // ─── 方法3: 遍历 asw_marine 实体匹配 m_hCommander ───
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_marine")) != -1)
    {
        int iCommander = -1;

        if (FindDataMapInfo(entity, "m_hCommander") != -1)
            iCommander = GetEntPropEnt(entity, Prop_Data, "m_hCommander");

        if (iCommander <= 0)
        {
            char sNetClass[64];
            if (GetEntityNetClass(entity, sNetClass, sizeof(sNetClass)))
            {
                if (FindSendPropInfo(sNetClass, "m_hCommander") != -1)
                    iCommander = GetEntPropEnt(entity, Prop_Send, "m_hCommander");
            }
        }

        if (iCommander == iClient)
        {
            if (g_cvDebug.BoolValue)
            {
                char sMarineClass[64];
                GetEntityClassname(entity, sMarineClass, sizeof(sMarineClass));
                PrintToServer("[机枪塔] 方法3成功: 遍历找到 marine #%d (%s), commander=%d", entity, sMarineClass, iCommander);
            }
            return entity;
        }
    }

    // ─── 方法4: 遍历 asw_marine_resource 匹配 m_hCommander ───
    // asw_marine_resource 是 marine 的资源实体，也有 m_hCommander
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_marine_resource")) != -1)
    {
        int iCommander = -1;

        if (FindDataMapInfo(entity, "m_hCommander") != -1)
            iCommander = GetEntPropEnt(entity, Prop_Data, "m_hCommander");

        if (iCommander <= 0)
        {
            char sNetClass[64];
            if (GetEntityNetClass(entity, sNetClass, sizeof(sNetClass)))
            {
                if (FindSendPropInfo(sNetClass, "m_hCommander") != -1)
                    iCommander = GetEntPropEnt(entity, Prop_Send, "m_hCommander");
            }
        }

        if (iCommander == iClient)
        {
            // 找到对应的 marine_resource，尝试获取 marine 实体
            int iMarineEnt = -1;
            if (FindDataMapInfo(entity, "m_hMarineEntity") != -1)
                iMarineEnt = GetEntPropEnt(entity, Prop_Data, "m_hMarineEntity");

            if (iMarineEnt <= 0)
            {
                char sNetClass[64];
                if (GetEntityNetClass(entity, sNetClass, sizeof(sNetClass)))
                {
                    if (FindSendPropInfo(sNetClass, "m_hMarineEntity") != -1)
                        iMarineEnt = GetEntPropEnt(entity, Prop_Send, "m_hMarineEntity");
                }
            }

            if (iMarineEnt > 0 && IsValidEntity(iMarineEnt))
            {
                if (g_cvDebug.BoolValue)
                {
                    char sMarineClass[64];
                    GetEntityClassname(iMarineEnt, sMarineClass, sizeof(sMarineClass));
                    PrintToServer("[机枪塔] 方法4成功: 通过 marine_resource 找到 marine #%d (%s)", iMarineEnt, sMarineClass);
                }
                return iMarineEnt;
            }
        }
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[机枪塔] 警告: 所有方法均未找到 client %d 的 marine", iClient);

    return -1;
}

// ============================================================================
//  命令：转储玩家实体属性（调试用，找 marine 属性名）
// ============================================================================
public Action Command_DumpPlayer(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "只能在游戏内使用");
        return Plugin_Handled;
    }

    PrintToConsole(client, "====== 玩家实体 #%d 属性转储 ======", client);

    // ─── 检查玩家自身的属性 ───
    PrintToConsole(client, "--- 玩家 SendProp 中包含 marine/handle 的属性 ---");
    char sPlayerNetClass[64];
    if (GetEntityNetClass(client, sPlayerNetClass, sizeof(sPlayerNetClass)))
    {
        PrintToConsole(client, "  玩家网络类: %s", sPlayerNetClass);

        char sPlayerProps[][] = {
            "m_hInhabiting", "m_hMarine", "m_hMarineResource",
            "m_hActiveWeapon", "m_hLastWeapon", "m_hOwnerEntity",
            "m_iUserID", "m_nPlayerIndex", "m_iTeamNum"
        };

        for (int i = 0; i < sizeof(sPlayerProps); i++)
        {
            int iDataOff = FindDataMapInfo(client, sPlayerProps[i]);
            int iSendOff = FindSendPropInfo(sPlayerNetClass, sPlayerProps[i]);

            if (iDataOff != -1 || iSendOff != -1)
            {
                int iValue = -1;
                if (iSendOff != -1)
                    iValue = GetEntPropEnt(client, Prop_Send, sPlayerProps[i]);
                else if (iDataOff != -1)
                {
                    iValue = GetEntPropEnt(client, Prop_Data, sPlayerProps[i]);
                    if (iValue <= 0)
                        iValue = GetEntProp(client, Prop_Data, sPlayerProps[i]);
                }

                PrintToConsole(client, "  %s: DataMap=%d Send=%d 值=%d", sPlayerProps[i], iDataOff, iSendOff, iValue);
            }
        }
    }

    // ─── 详细检查 asw_marine_resource ───
    PrintToConsole(client, "--- 详细检查 asw_marine_resource ---");
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_marine_resource")) != -1)
    {
        char sNetClass[64];
        GetEntityNetClass(entity, sNetClass, sizeof(sNetClass));
        PrintToConsole(client, "  #%d 网络类: %s", entity, sNetClass);

        char sProps[][] = {
            "m_hCommander", "m_iCommander", "m_hPlayer", "m_iPlayerIndex",
            "m_hMarineEntity", "m_hMarine", "m_hInhabitableNPC",
            "m_nMarineIndex", "m_iMarineIndex",
            "m_iUserID", "m_nPlayerIndex",
            "m_hLeader", "m_hSquadLeader",
            "m_bInhabited", "m_bAlive"
        };

        for (int i = 0; i < sizeof(sProps); i++)
        {
            int iDataOff = FindDataMapInfo(entity, sProps[i]);
            int iSendOff = FindSendPropInfo(sNetClass, sProps[i]);

            if (iDataOff != -1 || iSendOff != -1)
            {
                int iValue = -1;
                if (iSendOff != -1)
                    iValue = GetEntPropEnt(entity, Prop_Send, sProps[i]);
                else if (iDataOff != -1)
                {
                    iValue = GetEntPropEnt(entity, Prop_Data, sProps[i]);
                    if (iValue <= 0)
                        iValue = GetEntProp(entity, Prop_Data, sProps[i]);
                }

                PrintToConsole(client, "  %s: DataMap=%d Send=%d 值=%d", sProps[i], iDataOff, iSendOff, iValue);
            }
        }
    }

    // ─── 详细检查 asw_marine ───
    PrintToConsole(client, "--- 详细检查 asw_marine ---");
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_marine")) != -1)
    {
        char sNetClass[64];
        GetEntityNetClass(entity, sNetClass, sizeof(sNetClass));
        PrintToConsole(client, "  #%d 网络类: %s", entity, sNetClass);

        char sProps[][] = {
            "m_hCommander", "m_iCommander", "m_hPlayer", "m_hMarineResource",
            "m_hLeader", "m_hOwnerEntity", "m_hOwner",
            "m_iHealth", "m_iMaxHealth",
            "m_hWeapon", "m_hActiveWeapon",
            "m_hInhabiting", "m_hInhabitableNPC",
            "m_bInhabited", "m_bAlive"
        };

        for (int i = 0; i < sizeof(sProps); i++)
        {
            int iDataOff = FindDataMapInfo(entity, sProps[i]);
            int iSendOff = FindSendPropInfo(sNetClass, sProps[i]);

            if (iDataOff != -1 || iSendOff != -1)
            {
                int iValue = -1;
                if (iSendOff != -1)
                    iValue = GetEntPropEnt(entity, Prop_Send, sProps[i]);
                else if (iDataOff != -1)
                {
                    iValue = GetEntPropEnt(entity, Prop_Data, sProps[i]);
                    if (iValue <= 0)
                        iValue = GetEntProp(entity, Prop_Data, sProps[i]);
                }

                PrintToConsole(client, "  %s: DataMap=%d Send=%d 值=%d", sProps[i], iDataOff, iSendOff, iValue);
            }
        }

        // 获取位置确认 marine 在地图上
        float fOrigin[3];
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", fOrigin);
        PrintToConsole(client, "  位置: %.1f %.1f %.1f", fOrigin[0], fOrigin[1], fOrigin[2]);
    }

    // ─── 检查 asw_game_resource ───
    PrintToConsole(client, "--- 详细检查 asw_game_resource ---");
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_game_resource")) != -1)
    {
        char sNetClass[64];
        GetEntityNetClass(entity, sNetClass, sizeof(sNetClass));
        PrintToConsole(client, "  #%d 网络类: %s", entity, sNetClass);

        char sProps[][] = {
            "m_hCommander", "m_iNumMarines", "m_iNumPlayers",
            "m_hMarine0", "m_hMarine1", "m_hMarine2", "m_hMarine3",
            "m_hMarine4", "m_hMarine5", "m_hMarine6", "m_hMarine7",
            "m_hMarineResource0", "m_hMarineResource1", "m_hMarineResource2", "m_hMarineResource3",
            "m_hMarineResource4", "m_hMarineResource5", "m_hMarineResource6", "m_hMarineResource7",
            "m_iNumMarinesSelected",
            "m_hLeader0", "m_hLeader1", "m_hLeader2", "m_hLeader3",
            "m_hLeader4", "m_hLeader5", "m_hLeader6", "m_hLeader7"
        };

        for (int i = 0; i < sizeof(sProps); i++)
        {
            int iDataOff = FindDataMapInfo(entity, sProps[i]);
            int iSendOff = FindSendPropInfo(sNetClass, sProps[i]);

            if (iDataOff != -1 || iSendOff != -1)
            {
                int iValue = -1;
                if (iSendOff != -1)
                    iValue = GetEntPropEnt(entity, Prop_Send, sProps[i]);
                else if (iDataOff != -1)
                {
                    iValue = GetEntPropEnt(entity, Prop_Data, sProps[i]);
                    if (iValue <= 0)
                        iValue = GetEntProp(entity, Prop_Data, sProps[i]);
                }

                PrintToConsole(client, "  %s: DataMap=%d Send=%d 值=%d", sProps[i], iDataOff, iSendOff, iValue);
            }
        }
    }

    // ─── 测试 GetPlayerMarine 函数 ───
    PrintToConsole(client, "--- 测试 GetPlayerMarine ---");
    bool bOldDebug = g_cvDebug.BoolValue;
    g_cvDebug.SetBool(true);
    int iMarine = GetPlayerMarine(client);
    g_cvDebug.SetBool(bOldDebug);
    PrintToConsole(client, "  GetPlayerMarine(%d) = %d", client, iMarine);

    ReplyToCommand(client, "属性已转储到控制台");
    return Plugin_Handled;
}
