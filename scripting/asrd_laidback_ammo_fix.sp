/**
 * ============================================================================
 *  [AS:RD] 挑战弹药回弹兜底 (NoClip Ammo Fix)
 *  版本 1.0.0  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 解决什么问题 ──────────────────────────────────────
 *  部分挑战（如 laidback ultimate）用 VScript 自己做"子弹自动恢复"：
 *  scripts/vscripts/lp_ultimate_addon/ultimate/lp_ultimate_function.nut 的
 *  Update_Ammo / HandlePrimaryAmmo 每 0.1~0.2 秒遍历陆战队员身上的武器，
 *  按 GetMaxClip1()/GetMaxAmmo1() 计算回弹节奏，并把本轮最小延迟 minDelay
 *  作为下次执行时间返回给调度器。
 *
 *  对于"不使用弹匣"的道具（弹药包 asw_weapon_ammo_bag、加速冲刺
 *  asw_weapon_speed_burst、复活工具 asw_weapon_revive_tool、骇客工具
 *  asw_weapon_hack_tool 等），装备表里对应的弹药 ConVar 是 NULL，
 *  因此 GetMaxClip1() = GetMaxAmmo1() = -1（WEAPON_NOCLIP，
 *  src/game/shared/shareddefs.h:121），引擎 Spawn 时 m_iClip1 也是 -1。
 *  挑战算出 maxClip1 = 0，而 Clip1() = -1 < 0，于是把它当"缺 1 发"来补：
 *  baseDelay = 0.1 + 75 / (-1) = 负数。
 *
 *  这个负数会作为 minDelay 返回，hooks.nut 的调度器看到 flUpdateTime < 0.0
 *  就执行 delete tCallbackFunctionList[...]，把 Update_Ammo 永久删掉。
 *  结果：整局所有枪械的自动回弹全部失效（不只是黏弹/霰弹枪）。
 *
 *  ── 本插件怎么做 ──────────────────────────────────────
 *  把"不使用弹匣"的武器实体的 m_iClip1 从 -1 改成 0。
 *  这些道具本来就不用弹匣（引擎 UsesClipsForAmmo1() 为假），改成 0 不影响
 *  任何游戏逻辑；而挑战侧看到 Clip1()(0) 不再小于 maxClip1(0)，就不会产生
 *  负延迟，Update_Ammo 也就不会被调度器删除。
 *
 *  ── 实现 ──────────────────────────────────────────────
 *  - 实体创建时如果是 asw_weapon_*，挂 SDKHook_SpawnPost，
 *    在引擎 GiveDefaultAmmo（把 m_iClip1 写成 -1）之后立刻修正为 0。
 *  - 每 2 秒全图扫一遍 asw_weapon_* 兜底，覆盖引擎/其它脚本再次写回 -1 的情况。
 *
 *  ── ConVar (自动生成 cfg/sourcemod/asrd_laidback_ammo_fix.cfg) ─
 *   sm_asrd_lpf_ammo_fix        总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_lpf_ammo_fix_debug  调试输出 (0=关 1=开, 默认 0; 修正时写服务器日志)
 *
 *  依赖: SourceMod 1.11+ (只用核心 API + sdktools + sdkhooks，无扩展)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] 挑战弹药回弹兜底"
#define PLUGIN_VERSION "1.0.0"

// WEAPON_NOCLIP: 装备表弹药 ConVar 为 NULL 时 GetMaxClip1()/GetMaxAmmo1() 的返回值
#define WEAPON_NOCLIP_VALUE (-1)

// 兜底扫描间隔（秒）。SpawnPost 已覆盖绝大多数情况，这里只防再次被写回
#define SWEEP_INTERVAL 2.0

ConVar g_cvEnabled;
ConVar g_cvDebug;

float g_fNextSweep;

public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "把不使用弹匣的武器 m_iClip1 由 -1 修正为 0，避免挑战回弹调度器因负延迟自我删除",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_lpf_ammo_fix", "1",
        "启用挑战弹药回弹兜底 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_lpf_ammo_fix_debug", "0",
        "调试输出 (0=关 1=开; 开启后每次修正写一条服务器日志)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    AutoExecConfig(true, "asrd_laidback_ammo_fix");
}

public void OnMapStart()
{
    g_fNextSweep = 0.0;   // 换图后立刻扫一次
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnabled.BoolValue)
        return;
    if (strncmp(classname, "asw_weapon_", 11, false) != 0)
        return;

    SDKHook(entity, SDKHook_SpawnPost, Hook_WeaponSpawnPost);
}

public void Hook_WeaponSpawnPost(int entity)
{
    FixWeaponClip(entity);
}

public void OnGameFrame()
{
    if (!g_cvEnabled.BoolValue)
        return;

    float fNow = GetGameTime();
    if (fNow < g_fNextSweep)
        return;
    g_fNextSweep = fNow + SWEEP_INTERVAL;

    SweepWeapons();
}

void SweepWeapons()
{
    int iMax = GetMaxEntities();
    char szClass[64];

    for (int i = MaxClients + 1; i <= iMax; i++)
    {
        if (!IsValidEntity(i))
            continue;

        GetEdictClassname(i, szClass, sizeof(szClass));
        if (strncmp(szClass, "asw_weapon_", 11, false) != 0)
            continue;

        FixWeaponClip(i);
    }
}

void FixWeaponClip(int entity)
{
    if (entity <= MaxClients || entity > GetMaxEntities())
        return;
    if (!IsValidEntity(entity))
        return;

    // m_iClip1 是 CBaseCombatWeapon 的网络变量 (CNetworkVar)
    if (!HasEntProp(entity, Prop_Send, "m_iClip1"))
        return;
    if (GetEntProp(entity, Prop_Send, "m_iClip1") != WEAPON_NOCLIP_VALUE)
        return;

    SetEntProp(entity, Prop_Send, "m_iClip1", 0);

    if (g_cvDebug.BoolValue)
    {
        char szClass[64];
        GetEdictClassname(entity, szClass, sizeof(szClass));
        LogMessage("[LPF] %s (#%d) m_iClip1: -1 -> 0", szClass, entity);
    }
}
