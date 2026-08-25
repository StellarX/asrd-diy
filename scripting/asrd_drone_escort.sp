/** ============================================================================
 *  [AS:RD] 无人机随从 (Drone Escort)
 *  版本 1.0.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 功能 ───────────────────────────────────────────
 *  玩家按一个按键生成一架"机器无人机", 自动环绕跟随玩家并攻击附近异形:
 *    - 按一下 → 生成一架, 最多 sm_asrd_drone_limit 架 (默认 10)
 *    - 每架自动环绕玩家飞行(不同相位交错), 发现异形自动开火
 *    - 玩家断开/换图/卸载时自动回收所有无人机
 *
 *  ── 玩家命令 (绑 1 个按键即可) ─────────────────────
 *   sm_drone      生成 1 架随从无人机 (最多 10 架)
 *   示例(控制台输入一次, 自动保存到 config.cfg):
 *     bind F8 "sm_drone"
 *
 *  ── 管理员命令 ─────────────────────────────────────
 *   sm_drone_clear   清空无人机 (不填则清所有, 可填玩家名)
 *   sm_drone_status  查看每名玩家的无人机数量
 *
 *  ── 常用 ConVar (自动生成 cfg/sourcemod/asrd_drone_escort.cfg) ─
 *   sm_asrd_drone_enabled       总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_drone_public        是否允许普通玩家生成 (0=仅管理员 1=公开, 默认 1)
 *   sm_asrd_drone_limit         每名玩家最大无人机数 (默认 10)
 *   sm_asrd_drone_model         无人机模型 (默认哨戒遥控炮塔)
 *   sm_asrd_drone_follow_dist   环绕跟随半径 (默认 120)
 *   sm_asrd_drone_follow_height 环绕相对高度 (默认 55)
 *   sm_asrd_drone_omega         环绕角速度 rad/s (默认 1.2)
 *   sm_asrd_drone_tick          跟随/攻击刷新间隔秒 (默认 0.1)
 *   sm_asrd_drone_attack        是否自动攻击异形 (0/1, 默认 1)
 *   sm_asrd_drone_damage        每次开火伤害 (默认 30)
 *   sm_asrd_drone_firerate      攻击冷却秒 (默认 0.35)
 *   sm_asrd_drone_range         攻击距离 (默认 600)
 *   sm_asrd_drone_debug         调试输出 (默认 0)
 *
 *  ── 实现原理 ───────────────────────────────────────
 *   - 载体: 生成 prop_dynamic 机械炮塔模型(非实心), 无原生 AI, 完全由插件驱动
 *   - 跟随: 单一定时器(默认 0.1s)按环绕相位算出目标位置并 TeleportEntity 吸附
 *   - 攻击: 同一定时器扫描附近"asw_"外星目标, 直接结算伤害(减 m_iHealth, 归零 Die),
 *           不依赖 SDKHooks(当前分支不兼容)
 *
 *  依赖: SourceMod 1.11+ (仅核心 API + sdktools, 不依赖 SDKHooks)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Drone Escort"
#define PLUGIN_VERSION "1.0.0"

// 每玩家最大无人机上限的硬顶(防止 ConVar 设置过大)
#define MAX_DRONES 32
// 实体索引→owner 的查询表长度(AS:RD 实体数级数百, 4K 足够且非循环内分配)
#define MAX_ENT_TABLE 4096

// 环绕相位差基准(多架时交错分布)
#define DRONE_TWO_PI 6.283185307

// ─── ConVar 句柄 ──────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvPublic;
ConVar g_cvLimit;
ConVar g_cvModel;
ConVar g_cvFollowDist;
ConVar g_cvFollowHeight;
ConVar g_cvOmega;
ConVar g_cvTick;
ConVar g_cvAttack;
ConVar g_cvDamage;
ConVar g_cvFireRate;
ConVar g_cvRange;
ConVar g_cvDebug;

// 模型路径缓存(懒加载: 首次使用时从 ConVar 复制, 避免每 tick 读字符串)
char g_szModel[PLATFORM_MAX_PATH];

// ─── 运行时状态 ───────────────────────────────────────
// 玩家的实体索引表: g_iDrones[client][slot] 存实体索引, 0 为空位
int g_iDrones[MAXPLAYERS + 1][MAX_DRONES];
int g_iDroneCount[MAXPLAYERS + 1];
// 实体→归属玩家 与 单架攻击冷却
int   g_iDroneOwner[MAX_ENT_TABLE];
float g_fNextAttack[MAX_ENT_TABLE];
Handle g_hMainTimer = null;

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "按一个键生成一架跟随玩家、自动攻击异形的机器无人机(最多10架)",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件加载
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_drone_enabled", "1",
        "启用/禁用无人机随从 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvPublic = CreateConVar(
        "sm_asrd_drone_public", "1",
        "是否允许普通玩家生成无人机 (0=仅管理员 1=公开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvLimit = CreateConVar(
        "sm_asrd_drone_limit", "10",
        "每名玩家最大无人机数 (1~32)",
        FCVAR_NOTIFY, true, 1.0, true, float(MAX_DRONES)
    );
    g_cvModel = CreateConVar(
        "sm_asrd_drone_model", "models/swarm/sentrygun/remoteturret.mdl",
        "无人机模型的 .mdl 路径 (需为游戏中存在的机械模型)",
        FCVAR_NOTIFY
    );
    g_cvFollowDist = CreateConVar(
        "sm_asrd_drone_follow_dist", "120",
        "无人机环绕跟随玩家的水平半径",
        FCVAR_NOTIFY, true, 20.0, true, 400.0
    );
    g_cvFollowHeight = CreateConVar(
        "sm_asrd_drone_follow_height", "55",
        "无人机相对玩家的悬停高度",
        FCVAR_NOTIFY, true, -100.0, true, 300.0
    );
    g_cvOmega = CreateConVar(
        "sm_asrd_drone_omega", "1.2",
        "无人机环绕玩家的角速度 rad/s",
        FCVAR_NOTIFY, true, 0.0, true, 6.0
    );
    g_cvTick = CreateConVar(
        "sm_asrd_drone_tick", "0.1",
        "跟随与攻击的刷新间隔秒 (不建议低于 0.05)",
        FCVAR_NOTIFY, true, 0.05, true, 1.0
    );
    g_cvAttack = CreateConVar(
        "sm_asrd_drone_attack", "1",
        "无人机是否自动攻击异形 (0=仅跟随 1=开火)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDamage = CreateConVar(
        "sm_asrd_drone_damage", "30",
        "无人机每次开火的伤害",
        FCVAR_NOTIFY, true, 1.0
    );
    g_cvFireRate = CreateConVar(
        "sm_asrd_drone_firerate", "0.35",
        "无人机开火冷却秒",
        FCVAR_NOTIFY, true, 0.1, true, 5.0
    );
    g_cvRange = CreateConVar(
        "sm_asrd_drone_range", "600",
        "无人机索敌攻击距离",
        FCVAR_NOTIFY, true, 100.0, true, 2000.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_drone_debug", "0",
        "调试输出到服务器控制台 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    // 懒加载模型路径缓存
    g_cvModel.GetString(g_szModel, sizeof(g_szModel));

    AutoExecConfig(true, "asrd_drone_escort");

    // 玩家命令
    RegConsoleCmd("sm_drone", Cmd_SpawnDrone, "生成 1 架随从无人机(按一下1架)");

    // 管理员命令
    RegAdminCmd("sm_drone_clear",  Cmd_ClearDrones, ADMFLAG_GENERIC, "清空玩家无人机(可填玩家名, 缺省清全部)");
    RegAdminCmd("sm_drone_status", Cmd_Status,      ADMFLAG_GENERIC, "查看每名玩家的无人机数量");

    // 单一主循环(跟随+攻击), 资源统一在此释放/管理
    StartMainTimer();
}

// 启动/重启主循环定时器(按 tick 值刷新间隔)
void StartMainTimer()
{
    if (g_hMainTimer != null)
    {
        KillTimer(g_hMainTimer);
        g_hMainTimer = null;
    }
    float rate = g_cvTick.FloatValue;
    g_hMainTimer = CreateTimer(rate, Timer_Main, _, TIMER_REPEAT);
}

public void OnPluginEnd()
{
    CleanupAll();
    if (g_hMainTimer != null)
    {
        KillTimer(g_hMainTimer);
        g_hMainTimer = null;
    }
}

public void OnMapEnd()
{
    // 换图即回收所有无人机, 避免残留实体
    CleanupAll();
}

public void OnClientDisconnect(int client)
{
    // 玩家掉线时释放其无人机(及时回收资源)
    CleanupClient(client);
}

// ============================================================================
//  玩家命令: 按一下生成 1 架
// ============================================================================
public Action Cmd_SpawnDrone(int client, int args)
{
    if (!CanUseDrone(client))
        return Plugin_Handled;

    int limit = g_cvLimit.IntValue;
    if (g_iDroneCount[client] >= limit)
    {
        PrintToChat(client, "\x04[无人机]\x01 已达数量上限 \x05%d\x01 架", limit);
        ShowStatus(client);
        return Plugin_Handled;
    }

    SpawnDroneFor(client);
    ShowStatus(client);
    return Plugin_Handled;
}

// ============================================================================
//  管理员命令: 清空 / 查看
// ============================================================================
public Action Cmd_ClearDrones(int client, int args)
{
    if (args < 1)
    {
        CleanupAll();
        if (client > 0)
            PrintToChat(client, "\x04[无人机]\x01 已清空所有玩家无人机");
        else
            PrintToServer("[无人机] 已清空所有玩家无人机");
        return Plugin_Handled;
    }

    // 按玩家名清指定玩家
    char sName[MAX_NAME_LENGTH];
    GetCmdArg(1, sName, sizeof(sName));
    int target = FindTarget(client, sName, true, false);
    if (target == -1)
    {
        if (client > 0)
            ReplyToCommand(client, "[无人机] 未找到玩家 %s", sName);
        return Plugin_Handled;
    }

    CleanupClient(target);
    if (client > 0)
        PrintToChat(client, "\x04[无人机]\x01 已清空 \x05%N\x01 的无人机", target);
    return Plugin_Handled;
}

public Action Cmd_Status(int client, int args)
{
    int total = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_iDroneCount[i] <= 0)
            continue;
        total += g_iDroneCount[i];
        if (client > 0)
            PrintToConsole(client, "[无人机] %N: %d 架", i, g_iDroneCount[i]);
        else
            PrintToServer("[无人机] %N: %d 架", i, g_iDroneCount[i]);
    }
    if (client > 0)
        PrintToChat(client, "\x04[无人机]\x01 当前在场无人机总数 \x05%d\x01 架", total);
    else
        PrintToServer("[无人机] 当前在场无人机总数 %d 架", total);
    return Plugin_Handled;
}

// ============================================================================
//  生成在: 在某 slot 生成一架 prop_dynamic 无人机
// ============================================================================
void SpawnDroneFor(int client)
{
    int marine = GetPlayerMarine(client);
    if (marine <= 0)
    {
        PrintToChat(client, "\x04[无人机]\x01 请先操控一名陆战队员再生成");
        return;
    }

    float origin[3];
    GetEntPropVector(marine, Prop_Send, "m_vecOrigin", origin);

    // 找到空闲 slot
    int slot = -1;
    for (int s = 0; s < MAX_DRONES; s++)
    {
        if (g_iDrones[client][s] <= 0)
        {
            slot = s;
            break;
        }
    }
    if (slot == -1)
        return;

    int drone = CreateEntityByName("prop_dynamic");
    if (drone <= 0)
    {
        PrintToChat(client, "\x04[无人机]\x01 生成失败(无法创建实体)");
        return;
    }

    // 给实体 Dash 唯一 targetname(避免寻址冲突)
    char sName[64];
    Format(sName, sizeof(sName), "asrd_drone_%d_%d", client, slot);

    DispatchKeyValue(drone, "targetname", sName);
    DispatchKeyValue(drone, "model", g_szModel);
    DispatchKeyValue(drone, "solid", "0");          // 非实心, 环绕飞行不挡路/不卡人
    DispatchKeyValue(drone, "rendermode", "0");

    DispatchSpawn(drone);
    SetEntityMoveType(drone, MOVETYPE_NONE);

    // 生成点: 玩家头顶略前方, 避免卡在身体里
    origin[0] += 30.0;
    origin[2] += g_cvFollowHeight.FloatValue + 30.0;
    TeleportEntity(drone, origin, NULL_VECTOR, NULL_VECTOR);

    // 登记: 实体→玩家 与 玩家 slot→实体
    g_iDrones[client][slot] = drone;
    g_iDroneCount[client]++;
    if (drone > 0 && drone < MAX_ENT_TABLE)
    {
        g_iDroneOwner[drone] = client;
        g_fNextAttack[drone] = 0.0;
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[无人机] 玩家 %N 生成第 %d 架(共 %d)",
            client, g_iDroneCount[client], slot);
}

// ============================================================================
//  回收
// ============================================================================
void CleanupClient(int client)
{
    for (int s = 0; s < MAX_DRONES; s++)
    {
        int drone = g_iDrones[client][s];
        if (drone > 0 && IsValidEdict(drone))
        {
            if (drone > 0 && drone < MAX_ENT_TABLE)
                g_iDroneOwner[drone] = 0;
            RemoveEntity(drone);
        }
        g_iDrones[client][s] = 0;
    }
    g_iDroneCount[client] = 0;
}

void CleanupAll()
{
    for (int i = 1; i <= MaxClients; i++)
        CleanupClient(i);
}

// ============================================================================
//  权限与校验
// ============================================================================
bool CanUseDrone(int client)
{
    if (!g_cvEnabled.BoolValue)
    {
        if (client > 0)
            PrintToChat(client, "\x04[无人机]\x01 功能已关闭");
        return false;
    }
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return false;
    if (!g_cvPublic.BoolValue && !CheckCommandAccess(client, "sm_drone_admin", ADMFLAG_GENERIC))
    {
        PrintToChat(client, "\x04[无人机]\x01 仅管理员可使用");
        return false;
    }
    return true;
}

void ShowStatus(int client)
{
    PrintHintText(client, "随从无人机: %d / %d 架\n再次按键生成第 %d 架",
        g_iDroneCount[client], g_cvLimit.IntValue, g_iDroneCount[client] + 1);
}

// ============================================================================
//  主循环: 每秒 tick 次, 先同步环境(ConVar缓存/模型), 再跟随+攻击
// ============================================================================
public Action Timer_Main(Handle timer)
{
    // 总开关关闭时无人机的处理: 保持在场但不更新? 直接回收更干净
    if (!g_cvEnabled.BoolValue)
    {
        CleanupAll();
        return Plugin_Continue;
    }

    // 懒刷新模型缓存(管理员改了模型 ConVar 后无需重载)
    char sModel[PLATFORM_MAX_PATH];
    g_cvModel.GetString(sModel, sizeof(sModel));
    if (strcmp(sModel, g_szModel, false) != 0)
    {
        strcopy(g_szModel, sizeof(g_szModel), sModel);
        // 已有无人机切换新模型
        for (int i = 1; i <= MaxClients; i++)
        {
            for (int s = 0; s < MAX_DRONES; s++)
            {
                int drone = g_iDrones[i][s];
                if (drone > 0 && IsValidEdict(drone))
                    SetEntityModel(drone, g_szModel);
            }
        }
    }

    float now = GetGameTime();
    float dist = g_cvFollowDist.FloatValue;
    float height = g_cvFollowHeight.FloatValue;
    float omega = g_cvOmega.FloatValue;
    bool bAttack = g_cvAttack.BoolValue;

    for (int i = 1; i <= MaxClients; i++)
    {
        int count = g_iDroneCount[i];
        if (count <= 0 || !IsClientInGame(i) || IsFakeClient(i))
            continue;

        int marine = GetPlayerMarine(i);
        if (marine <= 0)
            continue;

        float ownerPos[3];
        GetEntPropVector(marine, Prop_Send, "m_vecOrigin", ownerPos);

        // 该玩家在场无人机数(用于相位交错)
        for (int s = 0; s < MAX_DRONES; s++)
        {
            int drone = g_iDrones[i][s];
            if (drone <= 0)
                continue;

            // 实体可能已被地图/其它系统移除, 自愈
            if (!IsValidEdict(drone))
            {
                g_iDrones[i][s] = 0;
                g_iDroneCount[i] = g_iDroneCount[i] > 0 ? g_iDroneCount[i] - 1 : 0;
                if (drone > 0 && drone < MAX_ENT_TABLE)
                    g_iDroneOwner[drone] = 0;
                continue;
            }

            // 环绕相位: 按 slot 交错, 并随时间旋转
            float theta = DRONE_TWO_PI * (s % count) / count + now * omega;
            float target[3];
            target[0] = ownerPos[0] + Cosine(theta) * dist;
            target[1] = ownerPos[1] + Sine(theta) * dist;
            target[2] = ownerPos[2] + height;

            // 机头朝向玩家中心: 手写向量→欧拉角 (VectorAngles 非 SM 内建)
            float ang[3];
            AnglesTowardPoint(target, ownerPos, ang);

            // 吸附到目标位(瞬贴, 视觉平滑)
            TeleportEntity(drone, target, ang, NULL_VECTOR);

            // 攻击
            if (bAttack && now >= g_fNextAttack[drone])
                AttackNearest(drone, now);
        }
    }
    return Plugin_Continue;
}

// ============================================================================
//  攻击: 在本无人机攻击距离内找最近异形并结算伤害
// ============================================================================
void AttackNearest(int drone, float now)
{
    float dronePos[3];
    GetEntPropVector(drone, Prop_Send, "m_vecOrigin", dronePos);

    float range = g_cvRange.FloatValue;
    float dmg = g_cvDamage.FloatValue;
    float rangeSq = range * range;

    int best = -1;
    float bestSq = rangeSq;

    int maxEnt = GetMaxEntities();
    for (int e = 1; e < maxEnt; e++)
    {
        if (e >= MAX_ENT_TABLE)
            break;
        if (!IsValidEdict(e) || !IsAlienTarget(e))
            continue;

        float pos[3];
        GetEntPropVector(e, Prop_Send, "m_vecOrigin", pos);
        float dx = pos[0] - dronePos[0];
        float dy = pos[1] - dronePos[1];
        float dz = pos[2] - dronePos[2];
        float sq = dx * dx + dy * dy + dz * dz;
        if (sq < bestSq)
        {
            bestSq = sq;
            best = e;
        }
    }

    if (best == -1)
        return;   // 无目标, 不进入冷却, 持续索敌

    // 结算伤害: 直接减外星 m_iHealth(简化实现), 归零触发 Die
    int hp = GetEntProp(best, Prop_Data, "m_iHealth");
    hp -= RoundToFloor(dmg);
    if (hp <= 0)
    {
        SetEntProp(best, Prop_Data, "m_iHealth", 1);
        AcceptEntityInput(best, "Die");
    }
    else
    {
        SetEntProp(best, Prop_Data, "m_iHealth", hp);
    }

    if (drone > 0 && drone < MAX_ENT_TABLE)
        g_fNextAttack[drone] = now + g_cvFireRate.FloatValue;

    if (g_cvDebug.BoolValue)
    {
        char cls[32];
        GetEdictClassname(best, cls, sizeof(cls));
        PrintToServer("[无人机] #%d 攻击 %s(#%d) 剩余HP %d", drone, cls, best, hp > 0 ? hp : 0);
    }
}

// 判断一个实体是不是可作为目标的"外星" (asw_ 前缀且排除非敌对机械/生物)
bool IsAlienTarget(int e)
{
    if (!HasEntProp(e, Prop_Data, "m_iHealth"))
        return false;

    char cls[32];
    if (!GetEdictClassname(e, cls, sizeof(cls)) || strncmp(cls, "asw_", 4) != 0)
        return false;

    // 排除玩家/机械/系统类(己方或非外星), 不误伤
    if (StrContains(cls, "marine", false) != -1) return false;
    if (StrContains(cls, "weapon", false) != -1) return false;
    if (StrContains(cls, "sentry", false) != -1) return false;
    if (StrContains(cls, "camera", false) != -1) return false;
    if (StrContains(cls, "spawner", false) != -1) return false;
    if (StrContains(cls, "holo", false) != -1) return false;
    if (StrContains(cls, "stasis", false) != -1) return false;
    if (StrEqual(cls, "asw_marine_laser", false)) return false;
    return true;
}

// 由 from 看向 to 的俯仰/偏航欧拉角 (SourceMod 无 VectorAngles, 手写)
void AnglesTowardPoint(const float from[3], const float to[3], float ang[3])
{
    float dir[3];
    dir[0] = to[0] - from[0];
    dir[1] = to[1] - from[1];
    dir[2] = to[2] - from[2];
    float horiz = SquareRoot(dir[0] * dir[0] + dir[1] * dir[1]);
    // yaw: 水平朝向; pitch: 看向高度差 (Source 俯仰向上为正)
    ang[0] = (horiz > 0.1) ? RadToDeg(ArcTangent2(-dir[2], horiz)) : 0.0;
    ang[1] = (dir[0] != 0.0 || dir[1] != 0.0) ? RadToDeg(ArcTangent2(dir[1], dir[0])) : 0.0;
    ang[2] = 0.0;
}

// ============================================================================
//  找某玩家当前控制的 marine 实体 (与 asrd_marine_power / asrd_chainsaw_turbo 相同)
// ============================================================================
int GetPlayerMarine(int client)
{
    if (client <= 0 || !IsClientInGame(client))
        return -1;

    char sNetClass[64];
    if (GetEntityNetClass(client, sNetClass, sizeof(sNetClass)))
    {
        if (FindSendPropInfo(sNetClass, "m_hInhabiting") > 0)
        {
            int marine = GetEntPropEnt(client, Prop_Send, "m_hInhabiting");
            if (marine > 0 && IsValidEntity(marine))
                return marine;
        }
    }

    if (FindDataMapInfo(client, "m_hInhabiting") > 0)
    {
        int marine = GetEntPropEnt(client, Prop_Data, "m_hInhabiting");
        if (marine > 0 && IsValidEntity(marine))
            return marine;
    }

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