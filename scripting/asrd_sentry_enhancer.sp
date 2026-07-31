/**
 * ============================================================================
 *  Plugin: [AS:RD] Sentry Enhancer + Sentry Hat
 *  Version: 6.0.0
 *
 *  描述: 增强 AS:RD 机枪塔属性 + 把机枪塔放角色头顶
 *  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  v6.0.0 重写要点:
 *    - 性能: ArrayList 替代固定数组遍历，属性偏移缓存，避免循环内 IO
 *    - 兼容: MAX_ENTITIES 动态获取，支持 4096+ 实体
 *    - 多玩家: 每个玩家独立管理头顶塔，按 userid 隔离，无 targetname 冲突
 *    - 无敌: m_takedamage = 0 (无需 SDKHooks)
 *    - 头顶: 删除 SetParent，统一 OnGameFrame 追踪，行为可预测
 *    - 新增: 禁用塔对玩家伤害 (检查 m_hEnemy + 队伍过滤)
 *    - 新增: ConVar 修改自动刷新
 *    - 新增: 保存/恢复原始碰撞组
 *    - 新增: 按塔类型获取真实基础射速 + 动态射速加速
 *
 *  依赖:
 *    SourceMod 1.11+
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Sentry Enhancer + Sentry Hat"
#define PLUGIN_VERSION "6.0.0"

// 玩家队伍 (AS:RD 中 marine 队伍号)
#define ASRD_TEAM_PLAYERS 2

// ============================================================================
//  ConVar 句柄
// ============================================================================
ConVar g_cvEnabled;
ConVar g_cvHealthMult;
ConVar g_cvFireRateMult;
ConVar g_cvRangeMult;
ConVar g_cvAmmoMult;
ConVar g_cvInvulnerable;
ConVar g_cvNoPlayerDamage;
ConVar g_cvHatTurnSpeed;
ConVar g_cvHatPublic;
ConVar g_cvDebug;

// ============================================================================
//  属性偏移缓存（避免循环内 FindDataMapInfo 字符串 IO）
//  同类实体偏移相同，首次访问时初始化即可
// ============================================================================
// base 实体偏移
int g_offBaseMaxHealth    = -1;
int g_offBaseHealth       = -1;
int g_offBaseAmmo         = -1;
int g_offBaseGunType      = -1;
int g_offBaseSentryTop    = -1;
int g_offBaseTakedamage   = -1;
int g_offBaseCollisionGrp = -1;  // Prop_Send
int g_offBaseTeamNum      = -1;  // Prop_Send
// top 实体偏移
int g_offTopShootRange    = -1;
int g_offTopNextFireTime  = -1;
int g_offTopEnemy         = -1;
int g_offTopSentryBase    = -1;

bool g_bPropsCached = false;

// ============================================================================
//  数据结构：用 ArrayList 存储增强记录，避免遍历 MAX_ENTITIES
// ============================================================================
enum struct SentryData {
    int   baseRef;           // base 实体引用（唯一标识，防实体复用）
    int   topRef;            // top  实体引用
    int   origMaxHealth;     // 原始最大生命值
    int   origAmmo;          // 原始弹药
    float origShootRange;    // 原始射程
    int   origCollision;     // 原始碰撞组（头顶塔关闭时恢复）
    int   origTakedamage;    // 原始 m_takedamage
    int   origTeamNum;       // 原始队伍
    int   gunType;           // 塔类型 0-3
    float lastNextFireTime;  // 上一帧的 m_fNextFireTime（用于检测开火瞬间）
    // 头顶塔相关 (hatUserId == 0 表示非头顶塔)
    int   hatUserId;         // 所属玩家 userid
    int   hatMarineRef;      // marine 实体引用
    float hatYawOffset;      // Yaw 偏移
}

ArrayList g_hSentries;  // 增强记录列表（SentryData）

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "AS:RD 机枪塔增强 + 头顶机枪塔 (v6 重写)",
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
    g_cvNoPlayerDamage = CreateConVar(
        "sm_asrd_sentry_no_player_damage", "1",
        "禁用塔对玩家的伤害 (0=可伤害, 1=不伤害玩家/marine)",
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

    // 命令
    RegAdminCmd("sm_sentry_refresh",   Command_RefreshSentries, ADMFLAG_GENERIC, "重新增强所有机枪塔并补满弹药");
    RegAdminCmd("sm_sentry_status",    Command_SentryStatus,    ADMFLAG_GENERIC, "查看所有机枪塔状态");
    RegAdminCmd("sm_sentry_dump",      Command_SentryDump,      ADMFLAG_GENERIC, "转储机枪塔属性（调试）");
    RegAdminCmd("sm_sentry_dump_player", Command_DumpPlayer,    ADMFLAG_GENERIC, "转储玩家实体属性（调试）");
    RegAdminCmd("sm_sentryhat",        Command_SentryHat,       ADMFLAG_GENERIC, "把最近的机枪塔放到自己头顶");
    RegAdminCmd("sm_sentryhat_off",    Command_SentryHatOff,    ADMFLAG_GENERIC, "取消所有玩家的头顶机枪塔");
    RegConsoleCmd("sm_hat",            Command_HatPublic,       "把最近的机枪塔放到自己头顶 (需管理员开启)");
    RegConsoleCmd("sm_hat_off",        Command_HatOffPublic,    "取消自己的头顶机枪塔 (需管理员开启)");

    // ConVar 变更自动刷新
    g_cvHealthMult.AddChangeHook(OnMultCvarChanged);
    g_cvFireRateMult.AddChangeHook(OnMultCvarChanged);
    g_cvRangeMult.AddChangeHook(OnMultCvarChanged);
    g_cvAmmoMult.AddChangeHook(OnMultCvarChanged);
    g_cvInvulnerable.AddChangeHook(OnInvulnCvarChanged);
    g_cvNoPlayerDamage.AddChangeHook(OnNoDamageCvarChanged);

    g_hSentries = new ArrayList(sizeof(SentryData));
}

// ============================================================================
//  地图加载：清空状态
// ============================================================================
public void OnMapStart()
{
    g_hSentries.Clear();
    g_bPropsCached = false;  // 新地图可能实体类重新注册，重新缓存
}

// ============================================================================
//  实体创建：延迟增强 base
// ============================================================================
public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnabled.BoolValue)
        return;
    if (entity <= 0)
        return;

    if (StrEqual(classname, "asw_sentry_base"))
    {
        // 延迟 0.3s 等 top 实体 spawn 完毕
        CreateTimer(0.3, Timer_EnhanceSentry, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void OnEntityDestroyed(int entity)
{
    if (entity <= 0)
        return;

    // 从列表中移除被销毁的 base
    int idx = FindSentryByEntIndex(entity);
    if (idx >= 0)
        g_hSentries.Erase(idx);
}

// ============================================================================
//  属性偏移缓存（首次访问时初始化）
// ============================================================================
void CachePropOffsets(int iBase, int iTop)
{
    if (g_bPropsCached)
        return;

    // base 偏移
    g_offBaseMaxHealth    = FindDataMapInfo(iBase, "m_iMaxHealth");
    g_offBaseHealth       = FindDataMapInfo(iBase, "m_iHealth");
    g_offBaseAmmo         = FindDataMapInfo(iBase, "m_iAmmo");
    g_offBaseGunType      = FindDataMapInfo(iBase, "m_nGunType");
    g_offBaseSentryTop    = FindDataMapInfo(iBase, "m_hSentryTop");
    g_offBaseTakedamage   = FindDataMapInfo(iBase, "m_takedamage");
    g_offBaseCollisionGrp = FindSendPropInfo("asw_sentry_base", "m_CollisionGroup");
    g_offBaseTeamNum      = FindSendPropInfo("asw_sentry_base", "m_iTeamNum");

    // top 偏移
    if (iTop > 0)
    {
        g_offTopShootRange   = FindDataMapInfo(iTop, "m_flShootRange");
        g_offTopNextFireTime = FindDataMapInfo(iTop, "m_fNextFireTime");
        g_offTopEnemy        = FindDataMapInfo(iTop, "m_hEnemy");
        g_offTopSentryBase   = FindDataMapInfo(iTop, "m_hSentryBase");
    }

    g_bPropsCached = true;

    if (g_cvDebug.BoolValue)
    {
        PrintToServer("[机枪塔] 属性偏移缓存完成:");
        PrintToServer("  base: MaxHealth=%d Health=%d Ammo=%d GunType=%d SentryTop=%d Takedamage=%d Coll=%d Team=%d",
            g_offBaseMaxHealth, g_offBaseHealth, g_offBaseAmmo, g_offBaseGunType,
            g_offBaseSentryTop, g_offBaseTakedamage, g_offBaseCollisionGrp, g_offBaseTeamNum);
        PrintToServer("  top:  ShootRange=%d NextFire=%d Enemy=%d SentryBase=%d",
            g_offTopShootRange, g_offTopNextFireTime, g_offTopEnemy, g_offTopSentryBase);
    }
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
    // 已存在则跳过（除非 Force）
    int idx = FindSentryByEntIndex(iBase);
    if (!bForce && idx >= 0)
        return;

    // 查找 top 实体
    int iTop = FindSentryTop(iBase);
    CachePropOffsets(iBase, iTop);

    float fHealthMult = g_cvHealthMult.FloatValue;
    float fAmmoMult   = g_cvAmmoMult.FloatValue;
    float fRangeMult  = g_cvRangeMult.FloatValue;

    // ─── 已存在：保留原始值和头顶塔状态，只重新应用增强 ───
    if (idx >= 0)
    {
        SentryData data;
        g_hSentries.GetArray(idx, data);

        // 刷新 topRef（可能变化）
        if (iTop > 0)
            data.topRef = EntIndexToEntRef(iTop);

        // 用保存的原始值重新应用增强
        ReapplyEnhance(iBase, data);

        // 补满弹药
        if (data.origAmmo > 0)
        {
            int iFullAmmo = RoundToFloor(float(data.origAmmo) * fAmmoMult);
            SetEntProp(iBase, Prop_Data, "m_iAmmo", iFullAmmo);
        }

        // 重新应用无敌
        if (g_cvInvulnerable.BoolValue && g_offBaseTakedamage >= 0)
            SetEntProp(iBase, Prop_Data, "m_takedamage", 0);

        // 重新应用禁伤
        if (g_cvNoPlayerDamage.BoolValue && g_offBaseTeamNum >= 0)
            SetEntProp(iBase, Prop_Send, "m_iTeamNum", ASRD_TEAM_PLAYERS);

        g_hSentries.SetArray(idx, data);

        char sTypeName[32];
        GetSentryTypeName(data.gunType, sTypeName, sizeof(sTypeName));
        PrintToServer("[机枪塔刷新] #%d [%s] (生命x%.1f 射速x%.1f 射程x%.1f 弹药x%.1f)",
            iBase, sTypeName, fHealthMult, g_cvFireRateMult.FloatValue,
            fRangeMult, fAmmoMult);
        return;
    }

    // ─── 新塔：构建记录 ───
    SentryData data;
    data.baseRef = EntIndexToEntRef(iBase);
    data.topRef  = (iTop > 0) ? EntIndexToEntRef(iTop) : 0;
    data.hatUserId    = 0;
    data.hatMarineRef = 0;
    data.hatYawOffset = 0.0;
    data.lastNextFireTime = 0.0;

    // 读取原始值
    data.origMaxHealth = (g_offBaseMaxHealth >= 0) ? GetEntProp(iBase, Prop_Data, "m_iMaxHealth") : 0;
    data.origAmmo      = (g_offBaseAmmo     >= 0) ? GetEntProp(iBase, Prop_Data, "m_iAmmo")       : 0;
    data.origCollision = (g_offBaseCollisionGrp >= 0) ? GetEntProp(iBase, Prop_Send, "m_CollisionGroup") : 0;
    data.origTakedamage= (g_offBaseTakedamage >= 0) ? GetEntProp(iBase, Prop_Data, "m_takedamage") : 1;
    data.origTeamNum   = (g_offBaseTeamNum  >= 0) ? GetEntProp(iBase, Prop_Send, "m_iTeamNum")    : ASRD_TEAM_PLAYERS;
    data.gunType       = (g_offBaseGunType  >= 0) ? GetEntProp(iBase, Prop_Data, "m_nGunType")    : 0;
    data.origShootRange = (iTop > 0 && g_offTopShootRange >= 0) ? GetEntPropFloat(iTop, Prop_Data, "m_flShootRange") : 0.0;

    // 应用增强
    if (data.origMaxHealth > 0 && fHealthMult != 1.0)
    {
        int iNewHealth = RoundToFloor(float(data.origMaxHealth) * fHealthMult);
        SetEntProp(iBase, Prop_Data, "m_iMaxHealth", iNewHealth);
        SetEntProp(iBase, Prop_Data, "m_iHealth", iNewHealth);
    }

    if (data.origAmmo > 0 && fAmmoMult != 1.0)
    {
        int iNewAmmo = RoundToFloor(float(data.origAmmo) * fAmmoMult);
        SetEntProp(iBase, Prop_Data, "m_iAmmo", iNewAmmo);
    }

    if (iTop > 0 && data.origShootRange > 0.0 && fRangeMult != 1.0)
    {
        SetEntPropFloat(iTop, Prop_Data, "m_flShootRange", data.origShootRange * fRangeMult);
    }

    if (g_cvInvulnerable.BoolValue && g_offBaseTakedamage >= 0)
        SetEntProp(iBase, Prop_Data, "m_takedamage", 0);

    if (g_cvNoPlayerDamage.BoolValue && g_offBaseTeamNum >= 0)
        SetEntProp(iBase, Prop_Send, "m_iTeamNum", ASRD_TEAM_PLAYERS);

    g_hSentries.PushArray(data);

    char sTypeName[32];
    GetSentryTypeName(data.gunType, sTypeName, sizeof(sTypeName));

    PrintToServer("[机枪塔增强] #%d [%s] (生命x%.1f 射速x%.1f 射程x%.1f 弹药x%.1f 无敌%s 禁伤%s)",
        iBase, sTypeName, fHealthMult, g_cvFireRateMult.FloatValue,
        fRangeMult, fAmmoMult,
        g_cvInvulnerable.BoolValue ? "开" : "关",
        g_cvNoPlayerDamage.BoolValue ? "开" : "关");
}

// ============================================================================
//  OnGameFrame：射速 + 无敌 + 禁伤 + 头顶追踪
//  只遍历 ArrayList（通常 <20 个），不遍历 MAX_ENTITIES
// ============================================================================
public void OnGameFrame()
{
    if (!g_cvEnabled.BoolValue)
        return;
    if (g_hSentries.Length == 0)
        return;

    float fGameTime     = GetGameTime();
    float fFireRateMult = g_cvFireRateMult.FloatValue;
    bool  bInvuln       = g_cvInvulnerable.BoolValue;
    bool  bNoPlayerDmg  = g_cvNoPlayerDamage.BoolValue;
    float fTickInterval = GetTickInterval();
    float fTurnSpeed    = g_cvHatTurnSpeed.FloatValue;

    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);

        // 校验 base 实体有效性（防实体复用）
        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
        {
            g_hSentries.Erase(i);
            i--;
            continue;
        }

        // 校验/刷新 top 实体
        int iTop = EntRefToEntIndex(data.topRef);
        if (iTop == INVALID_ENT_REFERENCE || !IsValidEntity(iTop))
        {
            iTop = FindSentryTop(iBase);
            if (iTop > 0)
            {
                data.topRef = EntIndexToEntRef(iTop);
                CachePropOffsets(iBase, iTop);
            }
        }

        // ─── 射速加速（动态检测开火瞬间） ───
        if (fFireRateMult > 1.0 && iTop > 0 && g_offTopNextFireTime >= 0)
        {
            float fNextFire = GetEntPropFloat(iTop, Prop_Data, "m_fNextFireTime");

            // 检测塔刚开火：m_fNextFireTime 突然变大（引擎重置为 now + baseInterval）
            if (fNextFire > data.lastNextFireTime && fNextFire > fGameTime)
            {
                // 将剩余等待时间压缩为 1/倍率
                float fRemaining = fNextFire - fGameTime;
                float fNewNext   = fGameTime + (fRemaining / fFireRateMult);
                SetEntPropFloat(iTop, Prop_Data, "m_fNextFireTime", fNewNext);
                data.lastNextFireTime = fNewNext;
            }
            else
            {
                data.lastNextFireTime = fNextFire;
            }
        }

        // ─── 无敌：保持 m_takedamage = 0 ───
        if (bInvuln && g_offBaseTakedamage >= 0)
        {
            if (GetEntProp(iBase, Prop_Data, "m_takedamage") != 0)
                SetEntProp(iBase, Prop_Data, "m_takedamage", 0);
            // 同时保持血量满
            if (g_offBaseHealth >= 0 && g_offBaseMaxHealth >= 0)
            {
                int iMaxHp = GetEntProp(iBase, Prop_Data, "m_iMaxHealth");
                if (iMaxHp > 0 && GetEntProp(iBase, Prop_Data, "m_iHealth") < iMaxHp)
                    SetEntProp(iBase, Prop_Data, "m_iHealth", iMaxHp);
            }
        }

        // ─── 禁用对玩家伤害：清除指向 marine 的目标 + 强制同队 ───
        if (bNoPlayerDmg && iTop > 0)
        {
            // 强制塔与玩家同队
            if (g_offBaseTeamNum >= 0 && GetEntProp(iBase, Prop_Send, "m_iTeamNum") != ASRD_TEAM_PLAYERS)
                SetEntProp(iBase, Prop_Send, "m_iTeamNum", ASRD_TEAM_PLAYERS);

            // 清除指向 marine 的目标
            if (g_offTopEnemy >= 0)
            {
                int iEnemy = GetEntPropEnt(iTop, Prop_Data, "m_hEnemy");
                if (iEnemy > 0 && IsValidEntity(iEnemy) && IsMarineEntity(iEnemy))
                {
                    SetEntPropEnt(iTop, Prop_Data, "m_hEnemy", -1);
                    if (g_cvDebug.BoolValue)
                        PrintToServer("[机枪塔] #%d 清除指向 marine #%d 的目标", iBase, iEnemy);
                }
            }
        }

        // 先写回射速/无敌/禁伤的修改
        g_hSentries.SetArray(i, data);

        // ─── 头顶塔追踪（内部自己管理 data 读写） ───
        if (data.hatUserId != 0)
        {
            UpdateHatSentry(i, iBase, fTurnSpeed, fTickInterval);
        }
    }
}

// ============================================================================
//  头顶塔位置追踪（每帧）
//  内部自己从 ArrayList 读取/写回 data，避免与 OnGameFrame 的 data 副本冲突
// ============================================================================
void UpdateHatSentry(int listIdx, int iBase, float fTurnSpeed, float fTickInterval)
{
    SentryData data;
    g_hSentries.GetArray(listIdx, data);

    int iClient = GetClientOfUserId(data.hatUserId);
    if (iClient <= 0 || !IsClientInGame(iClient))
    {
        // 玩家离线，取消头顶塔
        ClearHatState(listIdx, data, iBase);
        return;
    }

    // 获取/刷新 marine 实体
    int iMarine = EntRefToEntIndex(data.hatMarineRef);
    if (iMarine == INVALID_ENT_REFERENCE || !IsValidEntity(iMarine))
    {
        iMarine = GetPlayerMarine(iClient);
        if (iMarine > 0)
        {
            data.hatMarineRef = EntIndexToEntRef(iMarine);
            g_hSentries.SetArray(listIdx, data);  // 写回刷新的 marineRef
        }
    }

    if (iMarine <= 0 || !IsValidEntity(iMarine))
    {
        // marine 还没部署，跳过本帧
        return;
    }

    // marine 死亡则取消
    if (GetEntProp(iMarine, Prop_Data, "m_iHealth") <= 0)
    {
        ClearHatState(listIdx, data, iBase);
        return;
    }

    // 获取 marine 位置
    float fOrigin[3], fAngles[3];
    GetEntPropVector(iMarine, Prop_Data, "m_vecOrigin", fOrigin);
    fOrigin[2] += 80.0;

    // 有角度偏移的塔放更高，避免重叠
    if (data.hatYawOffset != 0.0)
        fOrigin[2] += 70.0;

    // 朝向：玩家视角 + 180 + 偏移
    float fEyeAngles[3];
    GetClientEyeAngles(iClient, fEyeAngles);
    GetEntPropVector(iMarine, Prop_Data, "m_angRotation", fAngles);

    float fTargetYaw = fEyeAngles[1] + 180.0 + data.hatYawOffset;

    if (fTurnSpeed <= 0.0)
    {
        fAngles[1] = fTargetYaw;
    }
    else
    {
        float fDelta = fTargetYaw - fAngles[1];
        while (fDelta > 180.0)  fDelta -= 360.0;
        while (fDelta < -180.0) fDelta += 360.0;

        float fMaxTurn = fTurnSpeed * fTickInterval;
        if (fDelta > fMaxTurn)      fDelta = fMaxTurn;
        else if (fDelta < -fMaxTurn) fDelta = -fMaxTurn;
        fAngles[1] += fDelta;
    }
    fAngles[0] = 0.0;

    TeleportEntity(iBase, fOrigin, fAngles, NULL_VECTOR);
}

// ============================================================================
//  清除头顶塔状态（恢复碰撞组等）
// ============================================================================
void ClearHatState(int listIdx, SentryData data, int iBase)
{
    // 恢复原始碰撞组
    if (g_offBaseCollisionGrp >= 0 && IsValidEntity(iBase))
        SetEntProp(iBase, Prop_Send, "m_CollisionGroup", data.origCollision);

    // 同时恢复 top 碰撞组
    int iTop = EntRefToEntIndex(data.topRef);
    if (iTop > 0 && IsValidEntity(iTop))
        SetEntProp(iTop, Prop_Send, "m_CollisionGroup", 0);

    data.hatUserId    = 0;
    data.hatMarineRef = 0;
    data.hatYawOffset = 0.0;
    g_hSentries.SetArray(listIdx, data);
}

// ============================================================================
//  辅助：判断实体是否是 marine（玩家控制的角色）
// ============================================================================
bool IsMarineEntity(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;

    char sClass[32];
    if (!GetEntityClassname(entity, sClass, sizeof(sClass)))
        return false;

    return StrEqual(sClass, "asw_marine");
}

// ============================================================================
//  辅助：获取塔类型名称
// ============================================================================
void GetSentryTypeName(int iGunType, char[] sName, int iLen)
{
    switch (iGunType)
    {
        case 0: strcopy(sName, iLen, "哨戒枪");
        case 1: strcopy(sName, iLen, "哨戒炮");
        case 2: strcopy(sName, iLen, "喷火型");
        case 3: strcopy(sName, iLen, "冷冻型");
        default: Format(sName, iLen, "未知(%d)", iGunType);
    }
}

// ============================================================================
//  辅助：通过 base 找 top（优先用 m_hSentryTop 句柄，避免全实体遍历）
// ============================================================================
int FindSentryTop(int iBase)
{
    if (!IsValidEntity(iBase))
        return -1;

    // 方法1：通过 m_hSentryTop 句柄（O(1)，无 IO）
    if (g_offBaseSentryTop >= 0 || FindDataMapInfo(iBase, "m_hSentryTop") != -1)
    {
        int iTop = GetEntPropEnt(iBase, Prop_Data, "m_hSentryTop");
        if (iTop > 0 && IsValidEntity(iTop))
            return iTop;
    }

    // 方法2：遍历 top 实体类名（仅兜底）
    char sTopClasses[][] = {
        "asw_sentry_top_machinegun",
        "asw_sentry_top_cannon",
        "asw_sentry_top_flamer",
        "asw_sentry_top_freeze"
    };

    for (int t = 0; t < sizeof(sTopClasses); t++)
    {
        int entity = -1;
        while ((entity = FindEntityByClassname(entity, sTopClasses[t])) != -1)
        {
            int iMyBase = GetEntPropEnt(entity, Prop_Data, "m_hSentryBase");
            if (iMyBase == iBase)
                return entity;
        }
    }
    return -1;
}

// ============================================================================
//  辅助：按实体索引查找列表中的位置
// ============================================================================
int FindSentryByEntIndex(int iBase)
{
    if (iBase <= 0)
        return -1;

    int ref = EntIndexToEntRef(iBase);
    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        if (data.baseRef == ref)
            return i;
    }
    return -1;
}

// ============================================================================
//  辅助：获取玩家控制的 marine 实体
//  优先用 m_hInhabiting（Prop_Send），回退到遍历 asw_marine
// ============================================================================
int GetPlayerMarine(int iClient)
{
    if (iClient <= 0 || !IsClientInGame(iClient))
        return -1;

    // 方法1: m_hInhabiting（Prop_Send）
    char sNetClass[64];
    if (GetEntityNetClass(iClient, sNetClass, sizeof(sNetClass)))
    {
        if (FindSendPropInfo(sNetClass, "m_hInhabiting") != -1)
        {
            int iMarine = GetEntPropEnt(iClient, Prop_Send, "m_hInhabiting");
            if (iMarine > 0 && IsValidEntity(iMarine))
                return iMarine;
        }
    }

    // 方法2: Prop_Data
    if (FindDataMapInfo(iClient, "m_hInhabiting") != -1)
    {
        int iMarine = GetEntPropEnt(iClient, Prop_Data, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    // 方法3: 遍历 asw_marine 匹配 m_hCommander
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "asw_marine")) != -1)
    {
        int iCommander = -1;
        if (FindDataMapInfo(entity, "m_hCommander") != -1)
            iCommander = GetEntPropEnt(entity, Prop_Data, "m_hCommander");

        if (iCommander <= 0)
        {
            if (GetEntityNetClass(entity, sNetClass, sizeof(sNetClass))
                && FindSendPropInfo(sNetClass, "m_hCommander") != -1)
                iCommander = GetEntPropEnt(entity, Prop_Send, "m_hCommander");
        }

        if (iCommander == iClient)
            return entity;
    }

    return -1;
}

// ============================================================================
//  ConVar 变更：倍率修改 → 自动重新增强
// ============================================================================
void OnMultCvarChanged(ConVar cv, const char[] oldValue, const char[] newValue)
{
    if (!g_cvEnabled.BoolValue || g_hSentries.Length == 0)
        return;

    // 重新增强所有已追踪的塔
    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase != INVALID_ENT_REFERENCE && IsValidEntity(iBase))
            ReapplyEnhance(iBase, data);
    }
}

// ============================================================================
//  ConVar 变更：无敌切换
// ============================================================================
void OnInvulnCvarChanged(ConVar cv, const char[] oldValue, const char[] newValue)
{
    if (g_hSentries.Length == 0)
        return;

    bool bInvuln = g_cvInvulnerable.BoolValue;
    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
            continue;

        if (g_offBaseTakedamage >= 0)
        {
            if (bInvuln)
                SetEntProp(iBase, Prop_Data, "m_takedamage", 0);
            else
                SetEntProp(iBase, Prop_Data, "m_takedamage", data.origTakedamage);
        }
    }
}

// ============================================================================
//  ConVar 变更：禁伤玩家切换
// ============================================================================
void OnNoDamageCvarChanged(ConVar cv, const char[] oldValue, const char[] newValue)
{
    if (g_hSentries.Length == 0)
        return;

    bool bNoDmg = g_cvNoPlayerDamage.BoolValue;
    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
            continue;

        if (g_offBaseTeamNum >= 0)
        {
            if (bNoDmg)
                SetEntProp(iBase, Prop_Send, "m_iTeamNum", ASRD_TEAM_PLAYERS);
            else
                SetEntProp(iBase, Prop_Send, "m_iTeamNum", data.origTeamNum);
        }
    }
}

// ============================================================================
//  重新应用增强（倍率变更时）
// ============================================================================
void ReapplyEnhance(int iBase, SentryData data)
{
    float fHealthMult = g_cvHealthMult.FloatValue;
    float fAmmoMult   = g_cvAmmoMult.FloatValue;
    float fRangeMult  = g_cvRangeMult.FloatValue;

    if (data.origMaxHealth > 0 && fHealthMult != 1.0)
    {
        int iNewHealth = RoundToFloor(float(data.origMaxHealth) * fHealthMult);
        SetEntProp(iBase, Prop_Data, "m_iMaxHealth", iNewHealth);
        SetEntProp(iBase, Prop_Data, "m_iHealth", iNewHealth);
    }

    if (data.origAmmo > 0 && fAmmoMult != 1.0)
    {
        int iNewAmmo = RoundToFloor(float(data.origAmmo) * fAmmoMult);
        SetEntProp(iBase, Prop_Data, "m_iAmmo", iNewAmmo);
    }

    int iTop = EntRefToEntIndex(data.topRef);
    if (iTop > 0 && IsValidEntity(iTop) && data.origShootRange > 0.0 && fRangeMult != 1.0)
    {
        SetEntPropFloat(iTop, Prop_Data, "m_flShootRange", data.origShootRange * fRangeMult);
    }
}

// ============================================================================
//  命令：把最近的机枪塔放到自己头顶
// ============================================================================
public Action Command_SentryHat(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "你必须存活才能使用此命令");
        return Plugin_Handled;
    }

    // 参数：Yaw 偏移
    float fYawOffset = 0.0;
    if (args >= 1)
    {
        char sArg[16];
        GetCmdArg(1, sArg, sizeof(sArg));
        fYawOffset = StringToFloat(sArg);
    }

    // 找最近的、未被占用的 base
    int iBase = FindNearestSentryBase(client);
    if (iBase == -1)
    {
        ReplyToCommand(client, "附近没有可用的机枪塔");
        return Plugin_Handled;
    }

    // 获取 marine
    int iMarine = GetPlayerMarine(client);
    if (iMarine <= 0)
    {
        ReplyToCommand(client, "未找到你控制的 marine，请先部署角色");
        return Plugin_Handled;
    }

    // 查找/创建增强记录
    int idx = FindSentryByEntIndex(iBase);
    if (idx < 0)
    {
        // 未增强过的塔，先增强
        EnhanceSentry(iBase, false);
        idx = FindSentryByEntIndex(iBase);
    }
    if (idx < 0)
    {
        ReplyToCommand(client, "机枪塔记录创建失败");
        return Plugin_Handled;
    }

    SentryData data;
    g_hSentries.GetArray(idx, data);

    // 关闭碰撞（保存原始值已在增强时记录）
    if (g_offBaseCollisionGrp >= 0)
        SetEntProp(iBase, Prop_Send, "m_CollisionGroup", 1);  // debris
    int iTop = EntRefToEntIndex(data.topRef);
    if (iTop > 0 && IsValidEntity(iTop))
        SetEntProp(iTop, Prop_Send, "m_CollisionGroup", 1);

    // 设置头顶塔归属（按 userid 隔离，多玩家互不干扰）
    data.hatUserId    = GetClientUserId(client);
    data.hatMarineRef = EntIndexToEntRef(iMarine);
    data.hatYawOffset = fYawOffset;
    g_hSentries.SetArray(idx, data);

    // 初始传送到头顶
    float fOrigin[3], fAngles[3];
    GetEntPropVector(iMarine, Prop_Data, "m_vecOrigin", fOrigin);
    fOrigin[2] += (fYawOffset != 0.0) ? 150.0 : 80.0;
    GetEntPropVector(iMarine, Prop_Data, "m_angRotation", fAngles);
    fAngles[0] = 0.0;
    TeleportEntity(iBase, fOrigin, fAngles, NULL_VECTOR);

    char sTypeName[32];
    GetSentryTypeName(data.gunType, sTypeName, sizeof(sTypeName));
    ReplyToCommand(client, "已把[%s]放到你头顶", sTypeName);
    return Plugin_Handled;
}

// ============================================================================
//  命令：取消所有头顶机枪塔（管理员）
// ============================================================================
public Action Command_SentryHatOff(int client, int args)
{
    int iCount = 0;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        SentryData data;
        g_hSentries.GetArray(i, data);
        if (data.hatUserId == 0)
            continue;

        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase != INVALID_ENT_REFERENCE && IsValidEntity(iBase))
            ClearHatState(i, data, iBase);
        iCount++;
    }
    ReplyToCommand(client, "已取消 %d 个头顶机枪塔", iCount);
    return Plugin_Handled;
}

// ============================================================================
//  公共命令：玩家头顶机枪塔（需管理员开启）
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

    // 普通玩家只能取消自己的头顶塔（按 userid 隔离）
    int iUserId = GetClientUserId(client);
    int iCount = 0;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        SentryData data;
        g_hSentries.GetArray(i, data);
        if (data.hatUserId != iUserId)
            continue;

        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase != INVALID_ENT_REFERENCE && IsValidEntity(iBase))
            ClearHatState(i, data, iBase);
        iCount++;
    }
    ReplyToCommand(client, "已取消你的 %d 个头顶机枪塔", iCount);
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
    PrintToConsole(client, "倍率: 生命x%.1f | 射速x%.1f | 射程x%.1f | 弹药x%.1f",
        g_cvHealthMult.FloatValue, g_cvFireRateMult.FloatValue,
        g_cvRangeMult.FloatValue, g_cvAmmoMult.FloatValue);
    PrintToConsole(client, "无敌: %s | 禁伤玩家: %s | 头顶塔数量: %d",
        g_cvInvulnerable.BoolValue ? "开" : "关",
        g_cvNoPlayerDamage.BoolValue ? "开" : "关",
        g_hSentries.Length);
    PrintToConsole(client, "------------------------------");

    int count = 0;
    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        int iBase = EntRefToEntIndex(data.baseRef);
        if (iBase == INVALID_ENT_REFERENCE || !IsValidEntity(iBase))
            continue;

        count++;
        char sTypeName[32];
        GetSentryTypeName(data.gunType, sTypeName, sizeof(sTypeName));

        int iHealth = GetEntProp(iBase, Prop_Data, "m_iHealth");
        int iMaxHp  = GetEntProp(iBase, Prop_Data, "m_iMaxHealth");
        int iAmmo   = GetEntProp(iBase, Prop_Data, "m_iAmmo");

        PrintToConsole(client, "[#%d %s] 生命: %d/%d | 弹药: %d | 头顶: %s",
            iBase, sTypeName, iHealth, iMaxHp, iAmmo,
            data.hatUserId != 0 ? "是" : "否");

        int iTop = EntRefToEntIndex(data.topRef);
        if (iTop > 0 && IsValidEntity(iTop))
        {
            float fRange = GetEntPropFloat(iTop, Prop_Data, "m_flShootRange");
            PrintToConsole(client, "  [top #%d] 射程: %.0f", iTop, fRange);
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
    PrintToConsole(client, "====== 属性偏移缓存 ======");
    PrintToConsole(client, "base: MaxHealth=%d Health=%d Ammo=%d GunType=%d SentryTop=%d Takedamage=%d Coll=%d Team=%d",
        g_offBaseMaxHealth, g_offBaseHealth, g_offBaseAmmo, g_offBaseGunType,
        g_offBaseSentryTop, g_offBaseTakedamage, g_offBaseCollisionGrp, g_offBaseTeamNum);
    PrintToConsole(client, "top:  ShootRange=%d NextFire=%d Enemy=%d SentryBase=%d",
        g_offTopShootRange, g_offTopNextFireTime, g_offTopEnemy, g_offTopSentryBase);
    PrintToConsole(client, "列表长度: %d", g_hSentries.Length);
    PrintToConsole(client, "------------------------------");

    SentryData data;
    for (int i = 0; i < g_hSentries.Length; i++)
    {
        g_hSentries.GetArray(i, data);
        int iBase = EntRefToEntIndex(data.baseRef);
        int iTop  = EntRefToEntIndex(data.topRef);

        char sTypeName[32];
        GetSentryTypeName(data.gunType, sTypeName, sizeof(sTypeName));

        PrintToConsole(client, "[%d] base=%d top=%d [%s] origHp=%d origAmmo=%d origRange=%.0f hatUid=%d",
            i, iBase, iTop, sTypeName, data.origMaxHealth, data.origAmmo,
            data.origShootRange, data.hatUserId);
    }

    ReplyToCommand(client, "属性已转储到控制台");
    return Plugin_Handled;
}

// ============================================================================
//  命令：转储玩家实体属性（调试）
// ============================================================================
public Action Command_DumpPlayer(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "只能在游戏内使用");
        return Plugin_Handled;
    }

    PrintToConsole(client, "====== 玩家 #%d 属性 ======", client);
    PrintToConsole(client, "--- GetPlayerMarine 测试 ---");

    char sNetClass[64];
    if (GetEntityNetClass(client, sNetClass, sizeof(sNetClass)))
    {
        PrintToConsole(client, "玩家网络类: %s", sNetClass);
        PrintToConsole(client, "  m_hInhabiting Send=%d", FindSendPropInfo(sNetClass, "m_hInhabiting"));
    }
    PrintToConsole(client, "  m_hInhabiting Data=%d", FindDataMapInfo(client, "m_hInhabiting"));

    bool bOldDebug = g_cvDebug.BoolValue;
    g_cvDebug.SetBool(true);
    int iMarine = GetPlayerMarine(client);
    g_cvDebug.SetBool(bOldDebug);
    PrintToConsole(client, "  GetPlayerMarine(%d) = %d", client, iMarine);

    if (iMarine > 0)
    {
        char sMarineClass[64];
        GetEntityClassname(iMarine, sMarineClass, sizeof(sMarineClass));
        PrintToConsole(client, "  marine 类: %s", sMarineClass);

        float fOrigin[3];
        GetEntPropVector(iMarine, Prop_Data, "m_vecOrigin", fOrigin);
        PrintToConsole(client, "  marine 位置: %.1f %.1f %.1f", fOrigin[0], fOrigin[1], fOrigin[2]);
    }

    ReplyToCommand(client, "属性已转储到控制台");
    return Plugin_Handled;
}

// ============================================================================
//  辅助：找最近的、未被占用为头顶塔的 base 实体
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
        // 跳过已经被占用为头顶塔的
        int idx = FindSentryByEntIndex(entity);
        if (idx >= 0)
        {
            SentryData data;
            g_hSentries.GetArray(idx, data);
            if (data.hatUserId != 0)
                continue;
        }

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
