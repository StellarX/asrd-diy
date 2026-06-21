/**
 * ============================================================================
 *  Plugin: [AS:RD] Challenge - ASBI WB RNG 10x Barrels
 *
 *  描述: 基于 ASBI WB RNG 挑战，增加地图上的油桶10倍
 *  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  功能:
 *    - 应用 ASBI 挑战规则（真实友伤、虫群覆盖、残酷难度等）
 *    - 地图加载时将爆炸油桶数量增加至10倍
 *    - 新油桶在原始油桶附近随机偏移生成
 *    - 油桶倍率可通过 CVar 调整
 *    - 支持手动刷新油桶
 *
 *  ASBI 规则来源:
 *    - 官方 challenge_asbi.nut + asbi.txt
 *    - 真实友伤(FF=2)、虫群/游荡覆盖、无技能点、无死亡保护
 *    - 虫群加速、更频繁的尸潮
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

#define PLUGIN_NAME    "[AS:RD] ASBI WB RNG 10x Barrels"
#define PLUGIN_VERSION "1.0.0"

#define MAX_ENTITIES  2048
#define BARREL_CLASS  "asw_barrel_explosive"
#define BARREL_MODEL  "models/swarm/Barrel/barrel.mdl"

// ─── CVar 句柄 ──────────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvBarrelMult;
ConVar g_cvBarrelSpread;
ConVar g_cvApplyASBI;
ConVar g_cvDebug;

// ─── 追踪已生成的油桶 ───────────────────────────────────
ArrayList g_hSpawnedBarrels;

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "ASBI WB RNG 挑战 + 地图油桶10倍",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件加载
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_barrel_enabled", "1",
        "启用/禁用油桶增强 (0=禁用, 1=启用)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvBarrelMult = CreateConVar(
        "sm_asrd_barrel_mult", "10",
        "油桶数量倍率 (1=原始数量, 10=10倍)",
        FCVAR_NOTIFY, true, 1.0
    );

    g_cvBarrelSpread = CreateConVar(
        "sm_asrd_barrel_spread", "80",
        "新生成油桶相对原始油桶的最大偏移距离（游戏单位）",
        FCVAR_NOTIFY, true, 10.0
    );

    g_cvApplyASBI = CreateConVar(
        "sm_asrd_barrel_asbi", "1",
        "是否同时应用 ASBI 挑战规则 (0=仅油桶, 1=油桶+ASBI)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_cvDebug = CreateConVar(
        "sm_asrd_barrel_debug", "0",
        "调试模式，输出详细生成信息",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    AutoExecConfig(true, "asrd_barrel_challenge");

    g_hSpawnedBarrels = new ArrayList();

    RegAdminCmd("sm_barrel_refresh", Command_RefreshBarrels, ADMFLAG_GENERIC, "重新生成油桶");
    RegAdminCmd("sm_barrel_status", Command_BarrelStatus, ADMFLAG_GENERIC, "查看油桶状态");
    RegAdminCmd("sm_barrel_asbi_apply", Command_ApplyASBI, ADMFLAG_GENERIC, "手动应用 ASBI 规则");
}

public void OnMapStart()
{
    // 预缓存油桶模型
    PrecacheModel(BARREL_MODEL);

    // 延迟执行，等待地图实体完全加载
    CreateTimer(2.0, Timer_SpawnBarrels, _, TIMER_FLAG_NO_MAPCHANGE);
}

// ============================================================================
//  延迟生成油桶
// ============================================================================
public Action Timer_SpawnBarrels(Handle timer)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Stop;

    // 先应用 ASBI 规则
    if (g_cvApplyASBI.BoolValue)
        ApplyASBIRules();

    // 生成额外油桶
    SpawnExtraBarrels();

    return Plugin_Stop;
}

// ============================================================================
//  ASBI 挑战规则
//  来源: 官方 challenge_asbi.nut + asbi.txt
// ============================================================================
void ApplyASBIRules()
{
    // ─── 基础 ASBI 规则（来自 asbi.txt） ───
    SetConVarInt(FindConVar("asw_horde_override"), 1);
    SetConVarInt(FindConVar("asw_wanderer_override"), 1);
    SetConVarInt(FindConVar("rd_ready_mark_override"), 1);
    SetConVarInt(FindConVar("asw_sentry_friendly_fire_scale"), 1);
    SetConVarInt(FindConVar("asw_marine_ff_absorption"), 0);
    SetConVarInt(FindConVar("asw_adjust_difficulty_by_number_of_marines"), 0);
    SetConVarInt(FindConVar("asw_batch_interval"), 3);
    SetConVarInt(FindConVar("rd_auto_kick_low_level_player"), 1);
    SetConVarInt(FindConVar("rd_stuck_bot_teleport"), 0);

    // ─── ASBI 脚本规则（来自 challenge_asbi.nut） ───
    SetConVarInt(FindConVar("asw_realistic_death_chatter"), 1);
    SetConVarInt(FindConVar("asw_marine_ff"), 2);            // 真实友伤
    SetConVarFloat(FindConVar("asw_marine_ff_dmg_base"), 3.0);
    SetConVarInt(FindConVar("asw_custom_skill_points"), 0);  // 无技能点
    SetConVarFloat(FindConVar("asw_marine_death_cam_slowdown"), 0.0);
    SetConVarInt(FindConVar("asw_marine_death_protection"), 0); // 无死亡保护
    SetConVarInt(FindConVar("asw_marine_collision"), 1);
    SetConVarFloat(FindConVar("asw_difficulty_alien_health_step"), 0.2);
    SetConVarFloat(FindConVar("asw_difficulty_alien_damage_step"), 0.2);
    SetConVarFloat(FindConVar("asw_marine_time_until_ignite"), 0.0);
    SetConVarInt(FindConVar("rd_marine_ignite_immediately"), 1);
    SetConVarFloat(FindConVar("asw_marine_burn_time_easy"), 60.0);
    SetConVarFloat(FindConVar("asw_marine_burn_time_normal"), 60.0);
    SetConVarFloat(FindConVar("asw_marine_burn_time_hard"), 60.0);
    SetConVarFloat(FindConVar("asw_marine_burn_time_insane"), 60.0);

    // ─── 根据当前难度调整 ASBI 参数 ───
    int iSkill = GetConVarInt(FindConVar("asw_skill"));

    switch (iSkill)
    {
        case 1: // Easy
        {
            SetConVarFloat(FindConVar("asw_marine_speed_scale_easy"), 0.96);
            SetConVarFloat(FindConVar("asw_alien_speed_scale_easy"), 0.7);
            SetConVarFloat(FindConVar("asw_drone_acceleration"), 5.0);
            SetConVarFloat(FindConVar("asw_horde_interval_min"), 10.0);
            SetConVarFloat(FindConVar("asw_horde_interval_max"), 30.0);
            SetConVarFloat(FindConVar("asw_director_peak_min_time"), 2.0);
            SetConVarFloat(FindConVar("asw_director_peak_max_time"), 4.0);
            SetConVarFloat(FindConVar("asw_director_relaxed_min_time"), 15.0);
            SetConVarFloat(FindConVar("asw_director_relaxed_max_time"), 30.0);
        }
        case 2: // Normal
        {
            SetConVarFloat(FindConVar("asw_marine_speed_scale_normal"), 1.0);
            SetConVarFloat(FindConVar("asw_alien_speed_scale_normal"), 1.0);
            SetConVarFloat(FindConVar("asw_drone_acceleration"), 5.0);
            SetConVarFloat(FindConVar("asw_horde_interval_min"), 15.0);
            SetConVarFloat(FindConVar("asw_horde_interval_max"), 60.0);
            SetConVarFloat(FindConVar("asw_director_peak_min_time"), 2.0);
            SetConVarFloat(FindConVar("asw_director_peak_max_time"), 4.0);
            SetConVarFloat(FindConVar("asw_director_relaxed_min_time"), 15.0);
            SetConVarFloat(FindConVar("asw_director_relaxed_max_time"), 30.0);
        }
        case 3: // Hard
        {
            SetConVarFloat(FindConVar("asw_marine_speed_scale_hard"), 1.024);
            SetConVarFloat(FindConVar("asw_alien_speed_scale_hard"), 1.7);
            SetConVarFloat(FindConVar("asw_drone_acceleration"), 8.0);
            SetConVarFloat(FindConVar("asw_horde_interval_min"), 15.0);
            SetConVarFloat(FindConVar("asw_horde_interval_max"), 120.0);
            SetConVarFloat(FindConVar("asw_director_peak_min_time"), 2.0);
            SetConVarFloat(FindConVar("asw_director_peak_max_time"), 4.0);
            SetConVarFloat(FindConVar("asw_director_relaxed_min_time"), 15.0);
            SetConVarFloat(FindConVar("asw_director_relaxed_max_time"), 30.0);
        }
        case 4: // Insane
        {
            SetConVarFloat(FindConVar("asw_marine_speed_scale_insane"), 1.048);
            SetConVarFloat(FindConVar("asw_alien_speed_scale_insane"), 1.8);
            SetConVarFloat(FindConVar("asw_drone_acceleration"), 9.0);
            SetConVarFloat(FindConVar("asw_horde_interval_min"), 15.0);
            SetConVarFloat(FindConVar("asw_horde_interval_max"), 80.0);
            SetConVarFloat(FindConVar("asw_director_peak_min_time"), 2.0);
            SetConVarFloat(FindConVar("asw_director_peak_max_time"), 4.0);
            SetConVarFloat(FindConVar("asw_director_relaxed_min_time"), 15.0);
            SetConVarFloat(FindConVar("asw_director_relaxed_max_time"), 30.0);
        }
        case 5: // Brutal
        {
            SetConVarFloat(FindConVar("asw_marine_speed_scale_insane"), 1.048);
            SetConVarFloat(FindConVar("asw_alien_speed_scale_insane"), 1.9);
            SetConVarFloat(FindConVar("asw_drone_acceleration"), 10.0);
            SetConVarFloat(FindConVar("asw_horde_interval_min"), 15.0);
            SetConVarFloat(FindConVar("asw_horde_interval_max"), 60.0);
            SetConVarFloat(FindConVar("asw_director_peak_min_time"), 2.0);
            SetConVarFloat(FindConVar("asw_director_peak_max_time"), 4.0);
            SetConVarFloat(FindConVar("asw_director_relaxed_min_time"), 10.0);
            SetConVarFloat(FindConVar("asw_director_relaxed_max_time"), 30.0);
        }
    }

    PrintToServer("[ASBI WB RNG] ASBI 挑战规则已应用 (难度: %d)", iSkill);
}

// ============================================================================
//  生成额外油桶
// ============================================================================
void SpawnExtraBarrels()
{
    // 清除之前生成的油桶引用
    g_hSpawnedBarrels.Clear();

    float fMult = g_cvBarrelMult.FloatValue;
    int iExtraPerBarrel = RoundToFloor(fMult) - 1;
    if (iExtraPerBarrel < 1)
        return;

    float fSpread = g_cvBarrelSpread.FloatValue;

    // 收集所有原始油桶的位置和角度
    ArrayList hOrigins = new ArrayList(3);
    ArrayList hAngles  = new ArrayList(3);

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, BARREL_CLASS)) != -1)
    {
        float fOrigin[3], fAngles[3];
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", fOrigin);
        GetEntPropVector(entity, Prop_Data, "m_angRotation", fAngles);
        hOrigins.PushArray(fOrigin);
        hAngles.PushArray(fAngles);
    }

    int iOriginalCount = hOrigins.Length;

    if (iOriginalCount == 0)
    {
        if (g_cvDebug.BoolValue)
            PrintToServer("[ASBI WB RNG] 当前地图没有找到爆炸油桶");
        delete hOrigins;
        delete hAngles;
        return;
    }

    // 为每个原始油桶生成额外副本
    int iTotalSpawned = 0;

    for (int i = 0; i < iOriginalCount; i++)
    {
        float fBaseOrigin[3], fBaseAngles[3];
        hOrigins.GetArray(i, fBaseOrigin);
        hAngles.GetArray(i, fBaseAngles);

        for (int j = 0; j < iExtraPerBarrel; j++)
        {
            float fNewOrigin[3];
            fNewOrigin = fBaseOrigin;

            // 在原始位置附近随机偏移
            fNewOrigin[0] += GetRandomFloat(-fSpread, fSpread);
            fNewOrigin[1] += GetRandomFloat(-fSpread, fSpread);
            fNewOrigin[2] += GetRandomFloat(-5.0, 5.0); // Z轴偏移较小

            // 随机旋转
            float fNewAngles[3];
            fNewAngles[0] = fBaseAngles[0];
            fNewAngles[1] = fBaseAngles[1] + GetRandomFloat(0.0, 360.0);
            fNewAngles[2] = fBaseAngles[2];

            int iBarrel = CreateEntityByName(BARREL_CLASS);
            if (iBarrel == -1)
            {
                if (g_cvDebug.BoolValue)
                    PrintToServer("[ASBI WB RNG] 创建油桶实体失败");
                continue;
            }

            // 设置位置和角度
            TeleportEntity(iBarrel, fNewOrigin, fNewAngles, NULL_VECTOR);

            // 生成实体
            DispatchSpawn(iBarrel);
            ActivateEntity(iBarrel);

            // 记录生成的油桶
            g_hSpawnedBarrels.Push(EntIndexToEntRef(iBarrel));

            iTotalSpawned++;

            if (g_cvDebug.BoolValue)
            {
                PrintToServer("[ASBI WB RNG] 生成油桶 #%d 于 (%.1f, %.1f, %.1f) 偏移自油桶 %d",
                    iBarrel, fNewOrigin[0], fNewOrigin[1], fNewOrigin[2], i + 1);
            }
        }
    }

    delete hOrigins;
    delete hAngles;

    PrintToServer("[ASBI WB RNG] 油桶生成完成: 原始 %d 个, 新增 %d 个, 总计 %d 个 (x%.0f)",
        iOriginalCount, iTotalSpawned, iOriginalCount + iTotalSpawned, fMult);
}

// ============================================================================
//  管理命令：重新生成油桶
// ============================================================================
public Action Command_RefreshBarrels(int client, int args)
{
    if (!g_cvEnabled.BoolValue)
    {
        ReplyToCommand(client, "油桶增强功能已禁用");
        return Plugin_Handled;
    }

    // 先移除之前生成的油桶
    RemoveSpawnedBarrels();

    // 重新生成
    SpawnExtraBarrels();

    ReplyToCommand(client, "油桶已重新生成");
    return Plugin_Handled;
}

// ============================================================================
//  管理命令：查看油桶状态
// ============================================================================
public Action Command_BarrelStatus(int client, int args)
{
    int iTotal = 0;
    int iOriginal = 0;
    int iSpawned = 0;

    // 统计所有油桶
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, BARREL_CLASS)) != -1)
    {
        iTotal++;
    }

    // 统计仍然存活的已生成油桶
    for (int i = 0; i < g_hSpawnedBarrels.Length; i++)
    {
        int ref = g_hSpawnedBarrels.Get(i);
        int ent = EntRefToEntIndex(ref);
        if (ent != INVALID_ENT_REFERENCE && IsValidEntity(ent))
            iSpawned++;
    }

    iOriginal = iTotal - iSpawned;

    PrintToConsole(client, "========== 油桶状态 (v%s) ==========", PLUGIN_VERSION);
    PrintToConsole(client, "倍率: x%.0f | 散布: %.0f | ASBI: %s",
        g_cvBarrelMult.FloatValue, g_cvBarrelSpread.FloatValue,
        g_cvApplyASBI.BoolValue ? "启用" : "禁用");
    PrintToConsole(client, "原始油桶: %d | 生成油桶: %d | 总计: %d",
        iOriginal, iSpawned, iTotal);
    PrintToConsole(client, "==============================");

    return Plugin_Handled;
}

// ============================================================================
//  管理命令：手动应用 ASBI 规则
// ============================================================================
public Action Command_ApplyASBI(int client, int args)
{
    ApplyASBIRules();
    ReplyToCommand(client, "ASBI 规则已手动应用");
    return Plugin_Handled;
}

// ============================================================================
//  移除之前生成的油桶
// ============================================================================
void RemoveSpawnedBarrels()
{
    for (int i = 0; i < g_hSpawnedBarrels.Length; i++)
    {
        int ref = g_hSpawnedBarrels.Get(i);
        int ent = EntRefToEntIndex(ref);
        if (ent != INVALID_ENT_REFERENCE && IsValidEntity(ent))
        {
            AcceptEntityInput(ent, "Kill");
        }
    }
    g_hSpawnedBarrels.Clear();
}

// ============================================================================
//  地图结束清理
// ============================================================================
public void OnMapEnd()
{
    g_hSpawnedBarrels.Clear();
}
