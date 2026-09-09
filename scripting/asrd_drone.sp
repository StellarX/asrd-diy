// asrd_drone.sp
// 战斗无人机插件（从"便携式油桶(背上可爆炸版)"挑战拆出）
// 还原自 challenge_portable_oil_drum_2.nut 的 "/生成无人机" 部分：
//   1) 管理员在目标处生成一个扫描无人机信标（prop_dynamic combine_scanner）
//      以及一个加锁的破解按钮（trigger_asw_button_area，4 线缆）
//   2) 任意玩家破解按钮后，生成战斗无人机（npc_cscanner），并挂载：
//        - 爆炸弹粒子特效（跟随）
//        - 动态聚光灯
//        - 机枪塔 + 加农炮塔（modelscale 0.01，前向朝下倾斜）
// 命令（仅管理员，sm_ 前缀对应游戏内 / 或 !）：
//   sm_gd [目标]   -- 在目标处生成无人机信标；目标省略时对执行者自己

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"

#define BEACON_MODEL   "models/combine_scanner.mdl"
#define BEACON_SCALE   2.0
#define BUTTON_NAME    "asrd_drone_unlock_btn"
#define PARTICLE_FX    "powerup_explosive_bullets"
#define BUTTON_MSG     "解锁战斗无人机"
#define DRONE_HEALTH   20000
#define DRONES_PER_BEACON  1

// 信标记录字段
#define REC_BEACON  0
#define REC_BUTTON  1
#define REC_SIZE    2

ConVar g_cvEnable;
ConVar g_cvLimit;
ArrayList g_Beacons;

public Plugin myinfo =
{
    name        = "ASRD 战斗无人机",
    author      = "TraeCode",
    description = "生成无人机信标，破解后召唤战斗无人机（从便携式油桶挑战拆出）",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    LoadTranslations("common.phrases");

    RegAdminCmd("sm_gd", Cmd_SummonDrone, ADMFLAG_GENERIC, "sm_gd [目标] - 在目标处生成战斗无人机信标");

    g_cvEnable = CreateConVar("asrd_drone_enable", "1", "是否启用战斗无人机插件", FCVAR_NOTIFY);
    g_cvLimit  = CreateConVar("asrd_drone_limit", "3", "场上同时允许存在的无人机信标数量", FCVAR_NOTIFY);

    HookEvent("button_area_used", Event_ButtonAreaUsed);

    g_Beacons = new ArrayList(REC_SIZE);
}

public void OnMapEnd()
{
    g_Beacons.Clear();
}

public void OnPluginEnd()
{
    delete g_Beacons;
}

// ------------------------------------------------ 生成信标 --------------------------------------------------

public Action Cmd_SummonDrone(int client, int args)
{
    if (!g_cvEnable.BoolValue)
    {
        ReplyToCommand(client, "[无人机] 插件已通过 asrd_drone_enable 关闭。");
        return Plugin_Handled;
    }

    int target = client;
    if (args >= 1)
    {
        char arg1[64];
        GetCmdArg(1, arg1, sizeof(arg1));
        target = FindTarget(client, arg1, true, false);
        if (target == -1)
            return Plugin_Handled;
    }

    int marine = GetEntPropEnt(target, Prop_Send, "m_hInhabiting");
    if (marine <= 0)
    {
        ReplyToCommand(client, "[无人机] 无法获取 %N 所控制的陆战队员实体。", target);
        return Plugin_Handled;
    }

    if (g_Beacons.Length >= g_cvLimit.IntValue)
    {
        ReplyToCommand(client, "[无人机] 场上信标已达上限(%d)，先让场上的信标被解锁或换图后再试。", g_cvLimit.IntValue);
        return Plugin_Handled;
    }

    // 信标 prop_dynamic
    int beacon = CreateEntityByName("prop_dynamic");
    if (beacon <= 0)
    {
        ReplyToCommand(client, "[无人机] 创建信标实体失败。");
        return Plugin_Handled;
    }

    char beaconName[40];
    Format(beaconName, sizeof(beaconName), "asrd_drone_beacon_%d", beacon);
    DispatchKeyValue(beacon, "targetname", beaconName);
    DispatchKeyValue(beacon, "model", BEACON_MODEL);
    DispatchSpawn(beacon);
    ActivateEntity(beacon);
    SetEntPropFloat(beacon, Prop_Send, "m_flModelScale", BEACON_SCALE);

    float pos[3], ang[3];
    GetEntPropVector(marine, Prop_Send, "m_vecOrigin", pos);
    GetEntPropVector(marine, Prop_Send, "m_angRotation", ang);
    pos[2] += 30.0;
    TeleportEntity(beacon, pos, ang, NULL_VECTOR);

    // 待机动画
    SetVariantString("idle");
    AcceptEntityInput(beacon, "SetDefaultAnimation");
    SetVariantString("idle");
    AcceptEntityInput(beacon, "SetAnimation");

    // 破解按钮 trigger_asw_button_area
    int btn = CreateEntityByName("trigger_asw_button_area");
    if (btn <= 0)
    {
        AcceptEntityInput(beacon, "Kill");
        ReplyToCommand(client, "[无人机] 创建按钮实体失败。");
        return Plugin_Handled;
    }

    DispatchKeyValue(btn, "targetname", BUTTON_NAME);
    DispatchKeyValue(btn, "panelpropname", beaconName);
    DispatchKeyValue(btn, "model", BEACON_MODEL);
    DispatchKeyValue(btn, "HackPanelMessage", BUTTON_MSG);
    DispatchKeyValue(btn, "StartDisabled", "0");
    DispatchKeyValue(btn, "locked", "1");
    DispatchKeyValue(btn, "NumWires", "2");
    DispatchKeyValue(btn, "useafterhack", "1");
    DispatchKeyValue(btn, "spawnflags", "16");
    DispatchSpawn(btn);
    ActivateEntity(btn);

    // 位置：信标前方 1 单位 + 高 1 单位（还原挑战 TY_Button 的 ForwardX=1）
    float fwd[3];
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    float btnPos[3];
    btnPos[0] = pos[0] + fwd[0];
    btnPos[1] = pos[1] + fwd[1];
    btnPos[2] = pos[2] + 1.0;
    TeleportEntity(btn, btnPos, ang, NULL_VECTOR);

    // 父级绑定到信标
    SetVariantString("!activator");
    AcceptEntityInput(btn, "SetParent", beacon, beacon);

    // 记录
    int rec[REC_SIZE];
    rec[REC_BEACON] = beacon;
    rec[REC_BUTTON] = btn;
    g_Beacons.PushArray(rec, REC_SIZE);

    // 全服公告：已在目标玩家身边部署信标
    PrintToChatAll("（%N）身边已部署无人机支援信标", target);

    ReplyToCommand(client, "[无人机] 已在 %N 处生成无人机信标，破解上方按钮即可解锁战斗无人机。", target);
    return Plugin_Handled;
}

// ------------------------------------------------ 破解按钮 → 召唤无人机 --------------------------------------------------

public void Event_ButtonAreaUsed(Event event, const char[] name, bool dontBroadcast)
{
    int btn = event.GetInt("entindex");
    if (btn <= 0 || !IsValidEdict(btn))
        return;

    char entName[64];
    GetEntPropString(btn, Prop_Data, "m_iName", entName, sizeof(entName));
    if (!StrEqual(entName, BUTTON_NAME, false))
        return;

    for (int i = g_Beacons.Length - 1; i >= 0; i--)
    {
        int rec[REC_SIZE];
        g_Beacons.GetArray(i, rec, REC_SIZE);
        if (rec[REC_BUTTON] != btn)
            continue;

        int beacon = rec[REC_BEACON];
        if (beacon <= 0 || !IsValidEdict(beacon))
        {
            g_Beacons.Erase(i);
            continue;
        }

        // 获取破解人并全服聊天提示
        int userid = event.GetInt("userid");
        int hacker = GetClientOfUserId(userid);
        if (hacker >= 1 && hacker <= MaxClients && IsClientInGame(hacker))
            PrintToChatAll("（%N）已召唤无人机支援", hacker);
        else
            PrintToChatAll("（未知陆战队员）已召唤无人机支援");

        SpawnCombatDrone(beacon);

        // 清除信标与按钮
        AcceptEntityInput(btn, "Kill");
        AcceptEntityInput(beacon, "Kill");
        g_Beacons.Erase(i);
        return;
    }
}

// ------------------------------------------------ 生成战斗无人机本体 --------------------------------------------------

static void SpawnCombatDrone(int beacon)
{
    float pos[3], ang[3];
    GetEntPropVector(beacon, Prop_Send, "m_vecOrigin", pos);
    GetEntPropVector(beacon, Prop_Send, "m_angRotation", ang);

    // 每信标召唤 DRONES_PER_BEACON 架无人机，两架在信标两侧错开，避免叠在一起
    float fwd[3], right[3];
    GetAngleVectors(ang, fwd, right, NULL_VECTOR);

    for (int d = 0; d < DRONES_PER_BEACON; d++)
    {
        // 无人机 npc_cscanner
        int drone = CreateEntityByName("npc_cscanner");
        if (drone <= 0)
            continue;

        DispatchKeyValue(drone, "NeutralScanner", "1");
        DispatchKeyValueFloat(drone, "physdamagescale", 0.0);
        DispatchKeyValue(drone, "Freezable", "0");
        DispatchKeyValue(drone, "Flammable", "0");
        DispatchKeyValue(drone, "Teslable", "0");
        DispatchSpawn(drone);
        ActivateEntity(drone);

        // 高血量
        SetEntProp(drone, Prop_Data, "m_iHealth", DRONE_HEALTH);
        SetEntProp(drone, Prop_Data, "m_iMaxHealth", DRONE_HEALTH);
        if (HasEntProp(drone, Prop_Send, "m_iHealth"))
            SetEntProp(drone, Prop_Send, "m_iHealth", DRONE_HEALTH);

        if (HasEntProp(drone, Prop_Send, "m_bOnlyInspectPlayers"))
            SetEntProp(drone, Prop_Send, "m_bOnlyInspectPlayers", 1);
        if (HasEntProp(drone, Prop_Data, "m_CollisionGroup"))
            SetEntProp(drone, Prop_Data, "m_CollisionGroup", 1);

        // 两架无人机在信标两侧各偏移 40 单位，高度依次抬高
        float dronePos[3];
        dronePos[0] = pos[0] + right[0] * (d == 0 ? -40.0 : 40.0);
        dronePos[1] = pos[1] + right[1] * (d == 0 ? -40.0 : 40.0);
        dronePos[2] = pos[2] + 100.0 + d * 20.0;
        TeleportEntity(drone, dronePos, ang, NULL_VECTOR);

        // 爆炸弹粒子特效（跟随无人机）
        int pfx = CreateEntityByName("info_particle_system");
        if (pfx > 0)
        {
            DispatchKeyValue(pfx, "effect_name", PARTICLE_FX);
            DispatchKeyValue(pfx, "start_active", "1");
            DispatchSpawn(pfx);
            ActivateEntity(pfx);
            float pfxPos[3];
            pfxPos = dronePos;
            pfxPos[2] += 5.0;
            TeleportEntity(pfx, pfxPos, NULL_VECTOR, NULL_VECTOR);
            SetVariantString("!activator");
            AcceptEntityInput(pfx, "SetParent", drone, drone);
            CreateTimer(3600.0, Timer_KillEntity, EntIndexToEntRef(pfx), TIMER_FLAG_NO_MAPCHANGE);
        }

        // 动态聚光灯
        int light = CreateEntityByName("light_dynamic");
        if (light > 0)
        {
            DispatchKeyValue(light, "_light", "255 128 0 200");
            DispatchKeyValue(light, "brightness", "3");
            DispatchKeyValue(light, "_inner_cone", "60");
            DispatchKeyValue(light, "_cone", "100");
            DispatchKeyValue(light, "Pitch", "-65");
            DispatchKeyValue(light, "distance", "600");
            DispatchKeyValue(light, "spotlight_radius", "130");
            DispatchKeyValue(light, "Appearance", "12");
            DispatchSpawn(light);
            ActivateEntity(light);
            float lightPos[3];
            lightPos = dronePos;
            lightPos[2] -= 10.0;
            TeleportEntity(light, lightPos, ang, NULL_VECTOR);
            SetVariantString("!activator");
            AcceptEntityInput(light, "SetParent", drone, drone);
        }

        // 机枪塔 + 加农炮塔
        SpawnTurret("asw_sentry_top_machinegun", drone, dronePos, fwd, -15.0);
        SpawnTurret("asw_sentry_top_cannon", drone, dronePos, fwd, -10.0);
    }
}

// 还原挑战：炮塔前向 = 无人机前向 + 向下 30，位置 = 无人机 + 前向*5 + 高度偏移
static void SpawnTurret(const char[] classname, int drone, const float dronePos[3], const float fwd[3], float heightOffset)
{
    int turret = CreateEntityByName(classname);
    if (turret <= 0)
        return;

    DispatchKeyValueFloat(turret, "modelscale", 0.01);
    DispatchSpawn(turret);
    ActivateEntity(turret);

    float tPos[3], tFwd[3], tAng[3];
    tPos[0] = dronePos[0] + fwd[0] * 5.0;
    tPos[1] = dronePos[1] + fwd[1] * 5.0;
    tPos[2] = dronePos[2] + heightOffset;
    tFwd = fwd;
    tFwd[2] -= 30.0;
    GetVectorAngles(tFwd, tAng);
    TeleportEntity(turret, tPos, tAng, NULL_VECTOR);

    SetVariantString("!activator");
    AcceptEntityInput(turret, "SetParent", drone, drone);
}

public Action Timer_KillEntity(Handle timer, any ref)
{
    int ent = EntRefToEntIndex(ref);
    if (ent != INVALID_ENT_REFERENCE && IsValidEdict(ent))
        AcceptEntityInput(ent, "Kill");
    return Plugin_Handled;
}
