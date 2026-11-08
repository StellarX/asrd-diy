/**
 * ============================================================================
 *  [AS:RD] 友伤惩罚 (Friendly Fire)
 *  版本 1.0.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 这个插件做什么 ──────────────────────────────────────
 *  统计每名玩家单局内对队友造成的累计伤害, 分级惩罚:
 *    - 达到 warn 阈值 (默认 200): 私聊警告该玩家"请注意友伤" (只提示一次)
 *    - 达到 punish 阈值 (默认 300): 没收该玩家全部武器 (武器实体直接删除,
 *      凭空消失), 全服广播; 随后该玩家计数清零重新累计 (警告标记一并复位)
 *  单局累计: 换图 / 同图重开 (mp_restartgame、restart、asw_mission_restart)
 *  / 玩家断线 均清零。
 *
 *  ── 统计口径 ───────────────────────────────────────────
 *  - 通过 OnEntityCreated 给所有 asw_marine 挂 OnTakeDamage 回调;
 *    攻击者与受害者必须是"两名不同玩家控制的 marine"才计入
 *    (自己打自己 / 世界伤害 / 无人控制的 AI marine 不计)。
 *  - 伤害取回调传入值, 简单直接 (爆炸/枪械/近战均含)。
 *
 *  ── ConVar (自动生成 cfg/sourcemod/asrd_ff.cfg) ────────
 *   sm_asrd_ff_enabled  总开关 (默认 1)
 *   sm_asrd_ff_warn     警告阈值: 累计达到即私聊提示注意友伤 (默认 200)
 *   sm_asrd_ff_punish   惩罚阈值: 累计达到即没收全部武器 (默认 300)
 *   sm_asrd_ff_debug    调试输出 (默认 0)
 *
 *  依赖: SourceMod 1.11+ (核心 + sdktools)
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_NAME    "[AS:RD] FF Punish"
#define PLUGIN_VERSION "1.0.0"

#define MARINE_CLASS "asw_marine"
#define STRIP_SLOTS  16      // 武器槽遍历范围 (AS:RD marine 最多 10 槽, 多留余量)

ConVar g_cvEnabled;
ConVar g_cvWarn;
ConVar g_cvPunish;
ConVar g_cvDebug;

// 单局累计状态 (按攻击者 client 索引)
int  g_iFFDamage[MAXPLAYERS + 1];
bool g_bFFWarned[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "友伤累计统计: 200 点私聊警告, 300 点没收全部武器 (单局重置)",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("sm_asrd_ff_enabled", "1",
        "友伤惩罚总开关 (0=关 1=开)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvWarn = CreateConVar("sm_asrd_ff_warn", "200",
        "友伤警告阈值: 单局累计达到即私聊提示该玩家注意友伤", FCVAR_NOTIFY, true, 0.0);
    g_cvPunish = CreateConVar("sm_asrd_ff_punish", "300",
        "友伤惩罚阈值: 单局累计达到即没收该玩家全部武器", FCVAR_NOTIFY, true, 0.0);
    g_cvDebug = CreateConVar("sm_asrd_ff_debug", "0",
        "调试输出 (0=关 1=开)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    AutoExecConfig(true, "asrd_ff");

    // 同图重开不触发 OnMapStart, 需在此也重置 (与积分插件同一套监听)
    AddCommandListener(Listener_Restart, "mp_restartgame");
    AddCommandListener(Listener_Restart, "restart");
    HookEventEx("asw_mission_restart", Event_MissionRestart, EventHookMode_Post);
}

// ── 新生成的陆战队员挂伤害统计回调 ──
public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity <= 0)
        return;
    if (StrEqual(classname, MARINE_CLASS, false))
        SDKHook(entity, SDKHook_OnTakeDamage, OnMarineDamaged);
}

public Action OnMarineDamaged(int victim, int &attacker, int &inflictor,
    float &damage, int &damagetype)
{
    if (!g_cvEnabled.BoolValue || damage <= 0.0)
        return Plugin_Continue;

    // 受害者: 必须是玩家控制的 marine
    int vClient = ClientOfMarine(victim);
    if (vClient <= 0)
        return Plugin_Continue;

    // 攻击者: marine 实体反查控制玩家 (枪械/爆炸的 attacker 即投手 marine)
    int aClient = 0;
    if (attacker > 0 && attacker <= MaxClients)
    {
        if (IsClientInGame(attacker))
            aClient = attacker;
    }
    else if (attacker > 0 && IsValidEntity(attacker))
    {
        char cls[32];
        GetEntityClassname(attacker, cls, sizeof(cls));
        if (StrEqual(cls, MARINE_CLASS, false))
            aClient = ClientOfMarine(attacker);
    }

    // 不同玩家之间才算友伤 (自己打自己 / 无归属不计)
    if (aClient <= 0 || aClient == vClient)
        return Plugin_Continue;

    g_iFFDamage[aClient] += RoundToCeil(damage);

    if (g_cvDebug.BoolValue)
        PrintToServer("[友伤] %N 打了 %N %.1f → 累计 %d",
            aClient, vClient, damage, g_iFFDamage[aClient]);

    // ── 300 惩罚: 没收全部武器, 计数清零重新累计 ──
    if (g_iFFDamage[aClient] >= g_cvPunish.IntValue)
    {
        int total = g_iFFDamage[aClient];
        StripAllWeapons(aClient);
        PrintToChatAll("\x04[友伤]\x01 \x05%N\x01 对队友累计造成 \x05%d\x01 点伤害, \x07全部武器已被没收\x01!",
            aClient, total);
        if (g_cvDebug.BoolValue)
            PrintToServer("[友伤] %N 触发没收武器 (累计 %d), 计数清零", aClient, total);

        g_iFFDamage[aClient] = 0;
        g_bFFWarned[aClient] = false;
    }
    // ── 200 警告: 私聊提示一次 (未达惩罚阈值时) ──
    else if (!g_bFFWarned[aClient] && g_iFFDamage[aClient] >= g_cvWarn.IntValue)
    {
        g_bFFWarned[aClient] = true;
        PrintToChat(aClient, "\x04[友伤]\x01 警告: 你已对队友累计造成 \x05%d\x01 点伤害, 请注意友伤! 达到 \x05%d\x01 点将没收你的全部武器",
            g_iFFDamage[aClient], g_cvPunish.IntValue);
    }

    return Plugin_Continue;
}

// 没收玩家全部武器: 逐槽取武器 → 脱手 → 删除实体 (凭空消失, 地上也没有)
void StripAllWeapons(int client)
{
    if (!IsClientInGame(client))
        return;

    for (int slot = 0; slot < STRIP_SLOTS; slot++)
    {
        int weapon = GetPlayerWeaponSlot(client, slot);
        if (weapon <= 0 || !IsValidEntity(weapon))
            continue;

        RemovePlayerItem(client, weapon);
        AcceptEntityInput(weapon, "Kill");
    }
}

// marine 实体 → 控制它的玩家 (无则返回 0)
int ClientOfMarine(int marine)
{
    if (marine <= 0)
        return 0;
    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsClientInGame(c))
            continue;
        if (GetPlayerMarine(c) == marine)
            return c;
    }
    return 0;
}

// 查找玩家当前控制的 marine 实体 (失败返回 0; 与其它插件同款实现)
int GetPlayerMarine(int client)
{
    if (client <= 0 || !IsClientInGame(client))
        return 0;

    char sNetClass[64];
    if (GetEntityNetClass(client, sNetClass, sizeof(sNetClass))
        && FindSendPropInfo(sNetClass, "m_hInhabiting") > 0)
    {
        int iMarine = GetEntPropEnt(client, Prop_Send, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }

    if (FindDataMapInfo(client, "m_hInhabiting") > 0)
    {
        int iMarine = GetEntPropEnt(client, Prop_Data, "m_hInhabiting");
        if (iMarine > 0 && IsValidEntity(iMarine))
            return iMarine;
    }
    return 0;
}

// ── 单局重置: 换图 ──
public void OnMapStart()
{
    ResetAllFF();
}

// ── 单局重置: 同图重开 (mp_restartgame / restart 命令) ──
public Action Listener_Restart(int client, const char[] command, int argc)
{
    ResetAllFF();
    return Plugin_Continue;
}

// ── 单局重置: 任务重开 (asw_mission_restart 事件) ──
public void Event_MissionRestart(Event event, const char[] name, bool dontBroadcast)
{
    ResetAllFF();
}

// ── 玩家断线: 清该玩家计数 (防止顶替 slot 的新玩家继承) ──
public void OnClientDisconnect(int client)
{
    g_iFFDamage[client] = 0;
    g_bFFWarned[client] = false;
}

void ResetAllFF()
{
    for (int i = 0; i <= MaxClients; i++)
    {
        g_iFFDamage[i] = 0;
        g_bFFWarned[i] = false;
    }
    if (g_cvDebug.BoolValue)
        PrintToServer("[友伤] 单局计数已全部清零");
}
