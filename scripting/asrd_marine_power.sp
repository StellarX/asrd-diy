/**
 * ============================================================================
 *  [AS:RD] 陆战队员强化 (Marine Power)
 *  版本 1.2.1  |  游戏: Alien Swarm: Reactive Drop (AppID 563560)
 *
 *  ── 功能 ───────────────────────────────────────────
 *  玩家按键实时调大/调小自己的 血量 / 体型 / 近战 / 移速:
 *    - 放大(等级 1~5): 血量固定: L1=200 / L2=300 / L3=500 / L4=800 / L5=1000 + 体型 +0.1/级 + 移速同步(随等级) + 近战全局放大
 *    - 缩小(等级 -1~-3): 仅模型变小(0.8/0.6/0.4倍), 血量/近战/移速等属性不变
 *    - 等级0 = 恢复默认(100血 / 1.0倍体型 / 1.0倍移速)
 *  近战因 AS:RD 无逐人字段, 按当前最高"放大"等级做全局等比放大。
 *
 *  ── 玩家命令 (绑定 2 个按键即可) ─────────────────────
 *   sm_power_up      调大 1 级
 *   sm_power_down    调小 1 级
 *   sm_power_reset   恢复默认(等级0)
 *   示例(控制台输入一次, 自动保存到 config.cfg):
 *     bind F6 "sm_power_up"
 *     bind F7 "sm_power_down"
 *
 *  ── 管理员命令 ─────────────────────────────────────
 *   sm_power_status                查看所有玩家强化状态
 *   sm_power_set <玩家> <等级>      指定强化某个玩家 (等级= -缩小max ~ 放大max, 0=恢复默认)
 *                                  玩家可填 名字 / 部分名字 / #userid
 *
 *  ── 常用 ConVar (仅代码默认值, 不生成 cfg 文件) ─
 *   sm_asrd_power_enabled     总开关 (0=关 1=开, 默认 1)
 *   sm_asrd_power_public      是否允许普通玩家自行强化 (0=仅管理员 1=公开, 默认 1)
 *   sm_asrd_power_max_level   放大最大等级 (默认 5)
 *   血量上限(固定, 代码内配置): L1=200 / L2=300 / L3=500 / L4=800 / L5=1000
 *   sm_asrd_power_scale_step     每级体型增量 (默认 0.2, 5级=2.0)
 *   sm_asrd_power_shrink_max     缩小最大等级 (默认 3, 仅缩模型)
 *   sm_asrd_power_shrink_step    每级缩小比例 (默认 0.2, 3级=0.4倍)
 *   sm_asrd_power_speed_enabled  放大时是否同步提高移速 (0/1, 默认 1)
 *   sm_asrd_power_speed_step     每级移速增量 (默认 0.2, 与体型同比例)
 *   sm_asrd_power_melee_enabled  是否启用全局近战放大 (0/1, 默认 1)
 *   近战放大倍率(固定): 等级1~5 = x2 / x4 / x8 / x16 / x32
 *   sm_asrd_power_debug          调试输出 (默认 0)
 *
 *  ── 实现原理 ───────────────────────────────────────
 *   - 玩家控制的是"指挥官"实体, 真正带血量/模型/移速的是其 m_hInhabiting
 *     指向的 "asw_marine" 实体 (与 asrd_chainsaw_turbo 相同的查找方式)
 *   - 血量: 写 marine 的 m_iMaxHealth / m_iHealth (Prop_Data)
 *   - 体型: 写 marine 的 m_flModelScale (Prop_Send), 纯视觉缩放(不改变碰撞)
 *   - 移速: 写 marine 的 m_fSpeedScale (Prop_Send, AS:RD MaxSpeed 中的乘数)
 *   - 近战: 等比缩放 asw_skill_melee_dmg_base/_step (全局, 近战基础伤害, 影响所有陆战队员)
 *   - 定时器(1s)重新断言血量/体型/移速, 应对换人/复活, 但不会持续回血
 *
 *  依赖: SourceMod 1.11+ (仅核心 API + sdktools, 不依赖 SDKHooks)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME    "[AS:RD] Marine Power"
#define PLUGIN_VERSION "1.2.1"

// 重新断言周期(秒): 换陆战队员/复活后仍生效, 不回血
#define REAPPLY_INTERVAL 1.0

// 默认基础血量(AS:RD 陆战队员基础 100)
#define DEFAULT_BASE_HEALTH 100

// 各强化等级对应的血量上限(绝对上限值; 下标即等级)
//   L1=200  L2=300  L3=500  L4=800  L5=1000;  等级超过 LEVEL_COUNT 按 L5 封顶
#define LEVEL_COUNT 5
int g_iHpForLevel[LEVEL_COUNT + 1] = { 0, 200, 300, 500, 800, 1000 };

// ─── ConVar 句柄 ──────────────────────────────────────
ConVar g_cvEnabled;
ConVar g_cvPublic;
ConVar g_cvMaxLevel;
ConVar g_cvScaleStep;
ConVar g_cvMeleeEnabled;
ConVar g_cvShrinkMax;
ConVar g_cvShrinkStep;
ConVar g_cvSpeedEnabled;
ConVar g_cvSpeedStep;
ConVar g_cvDebug;

// ─── 近战(全局) ──────────────────────────────────────
ConVar g_hMeleeDmgBase = null;   // asw_skill_melee_dmg_base (近战基础伤害, 默认 30)
ConVar g_hMeleeDmgStep  = null;  // asw_skill_melee_dmg_step  (每技能点伤害, 默认 6)
float  g_fMeleeDmgBaseDefault = 30.0;
float  g_fMeleeDmgStepDefault  = 6.0;
bool   g_bMeleeConvarsReady   = false;

// ─── 每玩家状态 ───────────────────────────────────────
int  g_iLevel[MAXPLAYERS + 1];          // 当前强化等级 0..maxLevel
int  g_iBaseMaxHealth[MAXPLAYERS + 1];  // 首次强化前记录的原生最大血量(等级0恢复用)
Handle g_hReapplyTimer = null;

// ============================================================================
//  插件信息
// ============================================================================
public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "jack",
    description = "按键实时调大/调小血量/体型/移速(逐人)与近战(全局), 放大5级+缩小3级",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
//  插件加载
// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "sm_asrd_power_enabled", "1",
        "启用/禁用陆战队员强化 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvPublic = CreateConVar(
        "sm_asrd_power_public", "1",
        "是否允许普通玩家自行强化 (0=仅管理员 1=公开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvMaxLevel = CreateConVar(
        "sm_asrd_power_max_level", "5",
        "最大强化等级 (1~10)",
        FCVAR_NOTIFY, true, 1.0, true, 10.0
    );
    g_cvScaleStep = CreateConVar(
        "sm_asrd_power_scale_step", "0.1",
        "每级体型增量 (默认 0.2, 5级=2.0), 体型 = 1.0 + step*等级",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvMeleeEnabled = CreateConVar(
        "sm_asrd_power_melee_enabled", "1",
        "启用全局近战放大 (0=关 1=开, 影响所有陆战队员)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvShrinkMax = CreateConVar(
        "sm_asrd_power_shrink_max", "3",
        "缩小最大等级 (1~5, 仅缩小模型, 不改其他属性)",
        FCVAR_NOTIFY, true, 1.0, true, 5.0
    );
    g_cvShrinkStep = CreateConVar(
        "sm_asrd_power_shrink_step", "0.2",
        "每级缩小比例 (默认0.2, 3级=0.4倍模型)",
        FCVAR_NOTIFY, true, 0.05, true, 0.4
    );
    g_cvSpeedEnabled = CreateConVar(
        "sm_asrd_power_speed_enabled", "1",
        "放大时是否同步提高移速 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_cvSpeedStep = CreateConVar(
        "sm_asrd_power_speed_step", "0.1",
        "每级移速增量 (默认0.2, 与体型同比例, 5级=x2.0)",
        FCVAR_NOTIFY, true, 0.0
    );
    g_cvDebug = CreateConVar(
        "sm_asrd_power_debug", "0",
        "调试输出到服务器控制台 (0=关 1=开)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    // 不生成 cfg: 参数统一使用代码默认值, 避免旧 cfg 覆盖新默认值

    // 玩家命令
    RegConsoleCmd("sm_power_up",    Cmd_PowerUp,    "调大 1 级强化");
    RegConsoleCmd("sm_power_down",  Cmd_PowerDown,  "调小 1 级强化");
    RegConsoleCmd("sm_power_reset", Cmd_PowerReset, "恢复默认强化(等级0)");

    // 管理员命令
    RegAdminCmd("sm_power_status", Cmd_PowerStatus, ADMFLAG_GENERIC, "查看所有玩家强化状态");
    RegAdminCmd("sm_power_set", Cmd_PowerSet, ADMFLAG_GENERIC, "指定强化某个玩家 (用法: sm_power_set <玩家> <等级>)");

    // 任务即时重启(重新开始游戏): AS:RD 实测事件 asw_mission_restart, 用于清除上一局强化
    HookEventEx("asw_mission_restart", Event_MissionRestart, EventHookMode_Post);

    // 周期性重新断言(换人/复活后仍生效)
    g_hReapplyTimer = CreateTimer(REAPPLY_INTERVAL, Timer_Reapply, _, TIMER_REPEAT);
}

// AS:RD 任务即时重启(重新开始游戏, 不换图): 清除所有玩家的强化
public void Event_MissionRestart(Event event, const char[] name, bool dontBroadcast)
{
    // 该事件在游戏帧处理中段触发, 且 RestartMission 即刻重建陆战队员实体,
    // 延迟到实体重建后再恢复, 避免中途改写实体属性导致崩溃
    CreateTimer(REAPPLY_INTERVAL, Timer_ResetAllPower);
}

public Action Timer_ResetAllPower(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && g_iLevel[i] != 0)
            RestoreMarine(i);
        ResetPlayer(i);
    }
    ApplyMeleeConvars();
    return Plugin_Continue;
}

public void OnPluginEnd()
{
    // 插件卸载前恢复所有被强化玩家的体型/血量, 避免残留
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && g_iLevel[i] > 0)
            RestoreMarine(i);
        ResetPlayer(i);
    }
    RestoreMeleeDefaults();
    if (g_hReapplyTimer != null)
    {
        KillTimer(g_hReapplyTimer);
        g_hReapplyTimer = null;
    }
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        // 换图/新局: 上一局被强化的玩家先恢复实体属性, 再清内存等级
        if (g_iLevel[i] != 0)
            RestoreMarine(i);
        ResetPlayer(i);
    }
    ApplyMeleeConvars();
}

public void OnClientDisconnect(int client)
{
    if (g_iLevel[client] > 0)
        RestoreMarine(client);
    ResetPlayer(client);
    ApplyMeleeConvars();
}

// ============================================================================
//  玩家命令
// ============================================================================
public Action Cmd_PowerUp(int client, int args)
{
    if (!CanUsePower(client))
        return Plugin_Handled;

    int max = g_cvMaxLevel.IntValue;
    if (g_iLevel[client] >= max)
    {
        PrintToChat(client, "\x04[强化]\x01 已达最高等级 \x05%d\x01", max);
        ShowStatus(client);
        return Plugin_Handled;
    }

    g_iLevel[client]++;
    ApplyPower(client, true);
    ApplyMeleeConvars();
    ShowStatus(client);
    return Plugin_Handled;
}

public Action Cmd_PowerDown(int client, int args)
{
    if (!CanUsePower(client))
        return Plugin_Handled;

    int minLevel = -g_cvShrinkMax.IntValue;
    if (g_iLevel[client] <= minLevel)
    {
        PrintToChat(client, "\x04[强化]\x01 已达最小体型 (等级 \x05%d\x01)", minLevel);
        ShowStatus(client);
        return Plugin_Handled;
    }

    g_iLevel[client]--;
    ApplyPower(client, true);
    ApplyMeleeConvars();
    ShowStatus(client);
    return Plugin_Handled;
}

public Action Cmd_PowerReset(int client, int args)
{
    if (!CanUsePower(client))
        return Plugin_Handled;

    g_iLevel[client] = 0;
    ApplyPower(client, true);
    ApplyMeleeConvars();
    ShowStatus(client);
    return Plugin_Handled;
}

// ============================================================================
//  管理员命令: 指定强化某个玩家
//  sm_power_set <玩家> <等级>   (等级范围= -缩小max ~ 放大max, 0=恢复默认)
// ============================================================================
public Action Cmd_PowerSet(int client, int args)
{
    if (args < 2)
    {
        PrintToConsole(client, "用法: sm_power_set <玩家> <等级> (等级范围 %d~%d, 0=恢复默认)",
            -g_cvShrinkMax.IntValue, g_cvMaxLevel.IntValue);
        if (client > 0)
            PrintToChat(client, "\x04[强化]\x01 用法: \x05sm_power_set <玩家> <等级>\x01");
        return Plugin_Handled;
    }

    char sArg[64], sLevel[16];
    GetCmdArg(1, sArg, sizeof(sArg));
    GetCmdArg(2, sLevel, sizeof(sLevel));

    int target = FindTargetPlayer(client, sArg);
    if (target == 0)
        return Plugin_Handled;

    int level = StringToInt(sLevel);
    int minLevel = -g_cvShrinkMax.IntValue;
    int maxLevel = g_cvMaxLevel.IntValue;
    if (level < minLevel || level > maxLevel)
    {
        PrintToConsole(client, "等级超出范围 (%d~%d)", minLevel, maxLevel);
        if (client > 0)
            PrintToChat(client, "\x04[强化]\x01 等级必须在 \x05%d\x01 ~ \x05%d\x01 之间", minLevel, maxLevel);
        return Plugin_Handled;
    }

    // 写入目标玩家等级并应用(与普通玩家自调走同一套逻辑)
    g_iLevel[target] = level;
    ApplyPower(target, true);
    ApplyMeleeConvars();
    ShowStatus(target);

    if (client > 0)
        PrintToChat(client, "\x04[强化]\x01 已将 \x05%N\x01 设为等级 \x05%d\x01", target, level);
    PrintToServer("[强化] 管理员(玩家 %N) 将 %N 设为等级 %d", client, target, level);
    return Plugin_Handled;
}

// ============================================================================
//  按 名字 / 部分名字 / #userid 找一个在线玩家 (找不到或歧义时返回 0)
// ============================================================================
int FindTargetPlayer(int client, const char[] szArg)
{
    // #userid 形式
    if (szArg[0] == '#')
    {
        int who = GetClientOfUserId(StringToInt(szArg[1]));
        if (who > 0 && IsClientInGame(who) && !IsFakeClient(who))
            return who;
        PrintToConsole(client, "找不到该 userid 对应的在线玩家");
        return 0;
    }

    int found = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        char sName[MAX_NAME_LENGTH];
        GetClientName(i, sName, sizeof(sName));

        if (StrEqual(sName, szArg, false))   // 精确匹配: 直接命中
            return i;

        if (StrContains(sName, szArg, false) != -1)   // 部分匹配
        {
            if (found != 0)
            {
                PrintToConsole(client, "匹配到多名玩家, 请用更完整的名字或 #userid 精确定位");
                if (client > 0)
                    PrintToChat(client, "\x04[强化]\x01 匹配到多名玩家, 请用更完整的名字或 #userid");
                return 0;
            }
            found = i;
        }
    }

    if (found == 0)
        PrintToConsole(client, "找不到在线玩家 \"%s\"", szArg);
    return found;
}

// ============================================================================
//  管理员命令
// ============================================================================
public Action Cmd_PowerStatus(int client, int args)
{
    if (client > 0)
    {
        PrintToChat(client, "\x04[强化]\x01 ============ 玩家强化状态 (v%s) ============", PLUGIN_VERSION);
        PrintToChat(client, "\x04[强化]\x01 开关:%s | 公开:%s | 血量上限 %d/%d/%d/%d/%d | 体型+%.1f/级 | 移速+%.1f/级 | 等级%d~%d",
            g_cvEnabled.BoolValue ? "开" : "关",
            g_cvPublic.BoolValue ? "是" : "否",
            g_iHpForLevel[1], g_iHpForLevel[2], g_iHpForLevel[3], g_iHpForLevel[4], g_iHpForLevel[5],
            g_cvScaleStep.FloatValue,
            g_cvSpeedStep.FloatValue,
            -g_cvShrinkMax.IntValue, g_cvMaxLevel.IntValue);
    }

    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        count++;
        if (client > 0)
        {
            char sName[MAX_NAME_LENGTH];
            GetClientName(i, sName, sizeof(sName));
            PrintToConsole(client, "[%s] L%d | 血量%d | 体型x%.2f",
                sName, g_iLevel[i], GetHpForLevel(i), GetScaleForLevel(i));
        }
    }

    if (count == 0 && client > 0)
        PrintToChat(client, "\x04[强化]\x01 当前无真实玩家在线");

    return Plugin_Handled;
}

// ============================================================================
//  强化应用: 把某玩家的等级写入其 marine 实体
// ============================================================================
void ApplyPower(int client, bool refill)
{
    int marine = GetPlayerMarine(client);
    if (marine <= 0)
        return;

    int level = g_iLevel[client];

    // 首次放大前记录原生最大血量, 供等级0恢复
    if (g_iBaseMaxHealth[client] <= 0 && level > 0)
    {
        g_iBaseMaxHealth[client] = GetEntProp(marine, Prop_Data, "m_iMaxHealth");
        if (g_iBaseMaxHealth[client] <= 0)
            g_iBaseMaxHealth[client] = DEFAULT_BASE_HEALTH;
    }

    // 体型: 放大/缩小/默认 三态 (纯视觉, 不改变碰撞)
    float newScale = GetScaleForLevel(client);
    if (HasEntProp(marine, Prop_Send, "m_flModelScale"))
        SetEntPropFloat(marine, Prop_Send, "m_flModelScale", newScale);

    // 移速: 仅放大时变快 (AS:RD MaxSpeed 中的 m_fSpeedScale 乘数), 缩小/默认保持 1.0
    if (HasEntProp(marine, Prop_Send, "m_fSpeedScale"))
        SetEntPropFloat(marine, Prop_Send, "m_fSpeedScale", GetSpeedForLevel(client));

    // 血量: 缩小只缩模型不碰血量上限; 放大按等级缩放; 默认恢复
    if (level >= 0)
    {
        int newMax = GetHpForLevel(client);
        SetEntProp(marine, Prop_Data, "m_iMaxHealth", newMax);

        // 升级/降级时直接补齐到新上限; 定时重断言时仅当当前值超上限才回拉(不回血)
        int curHp = GetEntProp(marine, Prop_Data, "m_iHealth");
        if (refill || curHp > newMax)
            SetEntProp(marine, Prop_Data, "m_iHealth", newMax);
    }

    if (g_cvDebug.BoolValue)
        PrintToServer("[强化] %N L%d: 体型=x%.2f 移速=x%.2f", client, level, newScale, GetSpeedForLevel(client));
}

// 恢复某玩家 marine 的原始血量/体型/移速
void RestoreMarine(int client)
{
    int marine = GetPlayerMarine(client);
    if (marine <= 0)
        return;

    // 血量: 仅曾放大(记录过原生上限)才恢复; 缩小/未强化不碰血量
    if (g_iBaseMaxHealth[client] > 0)
    {
        int base = g_iBaseMaxHealth[client];
        SetEntProp(marine, Prop_Data, "m_iMaxHealth", base);
        if (GetEntProp(marine, Prop_Data, "m_iHealth") > base)
            SetEntProp(marine, Prop_Data, "m_iHealth", base);
    }

    if (HasEntProp(marine, Prop_Send, "m_flModelScale"))
        SetEntPropFloat(marine, Prop_Send, "m_flModelScale", 1.0);
    if (HasEntProp(marine, Prop_Send, "m_fSpeedScale"))
        SetEntPropFloat(marine, Prop_Send, "m_fSpeedScale", 1.0);
}

// ============================================================================
//  等级 → 数值换算
// ============================================================================
int GetHpForLevel(int client)
{
    int level = g_iLevel[client];
    if (level <= 0)
        return (g_iBaseMaxHealth[client] > 0) ? g_iBaseMaxHealth[client] : DEFAULT_BASE_HEALTH;
    if (level > LEVEL_COUNT)
        level = LEVEL_COUNT;
    return g_iHpForLevel[level];
}

float GetScaleForLevel(int client)
{
    int level = g_iLevel[client];
    if (level > 0)
        return 1.0 + g_cvScaleStep.FloatValue * level;
    if (level < 0)
    {
        float s = 1.0 - g_cvShrinkStep.FloatValue * (-level);
        return (s > 0.1) ? s : 0.1;
    }
    return 1.0;
}

// 移速倍率: 放大时随等级提高(与体型同比例), 缩小/默认保持 1.0
float GetSpeedForLevel(int client)
{
    int level = g_iLevel[client];
    if (level > 0 && g_cvSpeedEnabled.BoolValue)
        return 1.0 + g_cvSpeedStep.FloatValue * level;
    return 1.0;
}

// ============================================================================
//  近战(全局): 等比缩放 asw_skill_melee_dmg_base / _step (AS:RD 实际近战伤害)
//  伤害 = asw_skill_melee_dmg_base + asw_skill_melee_dmg_step * 技能点 (再乘攻击 DamageScale)
//  两者同乘倍数 => 近战伤害整体同乘倍数
// ============================================================================
void EnsureMeleeConvars()
{
    if (g_bMeleeConvarsReady)
        return;
    g_bMeleeConvarsReady = true;

    g_hMeleeDmgBase = FindConVar("asw_skill_melee_dmg_base");
    g_hMeleeDmgStep  = FindConVar("asw_skill_melee_dmg_step");
    if (g_hMeleeDmgBase != null)
        g_fMeleeDmgBaseDefault = GetConVarFloat(g_hMeleeDmgBase);
    if (g_hMeleeDmgStep != null)
        g_fMeleeDmgStepDefault = GetConVarFloat(g_hMeleeDmgStep);
}

// 当前近战倍率 = 所有玩家中的最高等级推算; 禁用/无人强化 => x1.0
float GetGlobalMeleeMult()
{
    if (!g_cvEnabled.BoolValue || !g_cvMeleeEnabled.BoolValue)
        return 1.0;

    int maxLevel = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && g_iLevel[i] > maxLevel)
            maxLevel = g_iLevel[i];
    }
    if (maxLevel <= 0)
        return 1.0;

    // 近战倍率查表: 放大等级 1~5 对应 x2 / x4 / x8 / x16 / x32
    static const float s_fMultTable[6] = { 0.0, 2.0, 4.0, 8.0, 16.0, 32.0 };
    if (maxLevel >= 1 && maxLevel <= 5)
        return s_fMultTable[maxLevel];
    return s_fMultTable[5];   // 超过 5 级按 x32 封顶
}

void ApplyMeleeConvars()
{
    EnsureMeleeConvars();
    if (g_hMeleeDmgBase == null || g_hMeleeDmgStep == null)
        return;

    float mult = GetGlobalMeleeMult();
    SetConVarFloat(g_hMeleeDmgBase, g_fMeleeDmgBaseDefault * mult);
    SetConVarFloat(g_hMeleeDmgStep,  g_fMeleeDmgStepDefault  * mult);

    if (g_cvDebug.BoolValue)
        PrintToServer("[强化] 近战全局倍率 x%.2f (base=%.1f step=%.1f)",
            mult, g_fMeleeDmgBaseDefault * mult, g_fMeleeDmgStepDefault * mult);
}

void RestoreMeleeDefaults()
{
    if (g_hMeleeDmgBase != null)
        SetConVarFloat(g_hMeleeDmgBase, g_fMeleeDmgBaseDefault);
    if (g_hMeleeDmgStep != null)
        SetConVarFloat(g_hMeleeDmgStep, g_fMeleeDmgStepDefault);
}

// ============================================================================
//  权限与状态校验
// ============================================================================
bool CanUsePower(int client)
{
    if (!g_cvEnabled.BoolValue)
    {
        if (client > 0)
            PrintToChat(client, "\x04[强化]\x01 功能已关闭");
        return false;
    }
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return false;
    if (!g_cvPublic.BoolValue && !CheckCommandAccess(client, "sm_power_admin", ADMFLAG_GENERIC))
    {
        PrintToChat(client, "\x04[强化]\x01 仅管理员可使用");
        return false;
    }
    return true;
}

void ShowStatus(int client)
{
    float scale = GetScaleForLevel(client);
    float melee = GetGlobalMeleeMult();
    float speed = GetSpeedForLevel(client);
    PrintHintText(client, "强化等级 %d (范围 %d~%d)\n血量上限: %d | 体型: x%.2f\n移速: x%.2f | 近战(全局): x%.2f",
        g_iLevel[client], -g_cvShrinkMax.IntValue, g_cvMaxLevel.IntValue,
        GetHpForLevel(client), scale, speed, melee);
    PrintToChat(client, "\x04[强化]\x01 等级 \x05%d\x01 | 血量 \x05%d\x01 | 体型 x\x05%.2f\x01 | 移速 x\x05%.2f\x01 | 近战 x\x05%.2f\x01",
        g_iLevel[client], GetHpForLevel(client), scale, speed, melee);
}

void ResetPlayer(int client)
{
    g_iLevel[client] = 0;
    g_iBaseMaxHealth[client] = 0;
}

// ============================================================================
//  周期定时器: 重新断言血量上限/体型/移速(换人/复活后仍生效, 不回血), 并重算近战倍率
// ============================================================================
public Action Timer_Reapply(Handle timer)
{
    if (g_cvEnabled.BoolValue)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i) || IsFakeClient(i) || g_iLevel[i] == 0)
                continue;
            ApplyPower(i, false);
        }
    }

    // 近战为全局倍率: 按当前最高等级重算(禁用/无人强化时自动恢复默认)
    ApplyMeleeConvars();
    return Plugin_Continue;
}

// ============================================================================
//  找某玩家当前控制的 marine 实体 (与 asrd_chainsaw_turbo 相同)
// ============================================================================
int GetPlayerMarine(int client)
{
    if (client <= 0 || !IsClientInGame(client))
        return -1;

    // 办法1: 玩家身上的 m_hInhabiting 网络属性 (最快)
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

    // 办法2: 玩家身上的 m_hInhabiting 数据属性
    if (FindDataMapInfo(client, "m_hInhabiting") > 0)
    {
        int marine = GetEntPropEnt(client, Prop_Data, "m_hInhabiting");
        if (marine > 0 && IsValidEntity(marine))
            return marine;
    }

    // 办法3: 遍历所有 marine, 找操控者是该玩家的那个
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